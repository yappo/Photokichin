import Foundation
import Synchronization
import Testing
@testable import PhotokichinDomain
@testable import PhotokichinInfrastructure

private struct ScannerProgressEvent: Sendable {
    let groupCount: Int
    let supportedFileCount: Int
    let presentationOrder: [Int]
}

private struct SelfCancellingJPGCR3Classifier: MediaFormatClassifying, Sendable {
    func variant(forFilename filename: String) -> AssetVariant? {
        let variant: AssetVariant?
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "jpg": variant = .renderedImage
        case "cr3": variant = .raw
        default: variant = nil
        }
        guard let variant else { return nil }
        withUnsafeCurrentTask { $0?.cancel() }
        return variant
    }
}

@Suite("Photo scanner")
struct PhotoScannerTests {
    @Test("Pairs JPG and CR3 while excluding Canon management files")
    func pairingAndExclusion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-scanner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dcim = root.appendingPathComponent("DCIM/100EOS_R", isDirectory: true)
        let management = root.appendingPathComponent("CANONMSC", isDirectory: true)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: management, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: dcim.appendingPathComponent("IMG_0001.JPG"))
        try Data("raw".utf8).write(to: dcim.appendingPathComponent("IMG_0001.CR3"))
        try Data("ignored".utf8).write(to: management.appendingPathComponent("IMG_9999.JPG"))

        let groups = InfrastructureTestSupport.scanner().scan(
            root: root,
            initialPresentationBatchSize: .max,
            initialPresentationGroupTarget: .max,
            progress: nil
        )

        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.variants == [.renderedImage, .raw])
        #expect(!group.id.contains("CANONMSC"))
    }

    @Test("JPG and CR3 scanner batches preserve progress and presentation order")
    func batchesAndProgressRemainStable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-scanner-progress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("DCIM/100EOS_R", isDirectory: true)
        var timestamp = Date(timeIntervalSince1970: 1_700_100_000)
        for index in 1...3 {
            try writeFixture(directory.appendingPathComponent("IMG_000\(index).JPG"), timestamp: timestamp)
            try writeFixture(directory.appendingPathComponent("IMG_000\(index).CR3"), timestamp: timestamp)
            timestamp = timestamp.addingTimeInterval(1)
        }

        let events = Mutex<[ScannerProgressEvent]>([])
        let groups = InfrastructureTestSupport.scanner().scan(
            root: root,
            initialPresentationBatchSize: 1,
            initialPresentationGroupTarget: 2,
            progress: { visibleGroups, supportedFileCount in
                events.withLock {
                    $0.append(ScannerProgressEvent(
                        groupCount: visibleGroups.count,
                        supportedFileCount: supportedFileCount,
                        presentationOrder: visibleGroups.map(\.presentationOrder)
                    ))
                }
            }
        )

        let snapshots = events.withLock { $0 }
        #expect(snapshots.map(\.groupCount) == [1, 2, 3])
        let supportedCounts = snapshots.map(\.supportedFileCount)
        #expect(supportedCounts.allSatisfy { (1...6).contains($0) })
        #expect(zip(supportedCounts, supportedCounts.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        #expect(supportedCounts.last == 6)
        #expect(snapshots.allSatisfy { $0.presentationOrder == Array(0..<$0.groupCount) })
        #expect(groups.count == 3)
        #expect(groups.map(\.presentationOrder) == Array(0..<3))
        #expect(groups.allSatisfy { $0.renderedImageURL != nil && $0.rawURL != nil })
    }

    @Test("Scanner cancellation stops a JPG and CR3 scan without publishing a partial result")
    func cancellationStopsBeforePartialResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-scanner-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("DCIM/100EOS_R", isDirectory: true)
        let timestamp = Date(timeIntervalSince1970: 1_700_200_000)
        try writeFixture(directory.appendingPathComponent("IMG_0001.JPG"), timestamp: timestamp)
        try writeFixture(directory.appendingPathComponent("IMG_0001.CR3"), timestamp: timestamp)

        let scanner = PhotoScanner(
            classifier: SelfCancellingJPGCR3Classifier(),
            traversalPolicy: FilesystemTraversalPolicy()
        )
        let scanTask = Task.detached {
            scanner.scan(
                root: root,
                initialPresentationBatchSize: 1,
                initialPresentationGroupTarget: 1,
                progress: nil
            )
        }
        let groups = await scanTask.value
        #expect(groups.isEmpty)
    }

    @Test("Scans every contributed pair and single-variant format across vendor folders")
    func scansProductionFormatMatrix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-scanner-matrix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pairs: [(directory: String, basename: String, rendered: String, raw: String)] = [
            ("Canon/DCIM/100CANON", "IMG_0001", "JPG", "CR3"),
            ("Canon/DCIM/100CANON", "IMG_0002", "hif", "cr3"),
            ("Canon/DCIM/100CANON", "IMG_0003", "JPG", "CR2"),
            ("Sony/DCIM/100MSDCF", "DSC01234", "JPG", "ARW"),
            ("Sony/DCIM/100MSDCF", "DSC01235", "HIF", "arw"),
            ("Nikon/DCIM/100NIKON", "DSC_0001", "JPG", "NEF"),
            ("Nikon/DCIM/100NIKON", "DSC_0002", "hif", "nef"),
            ("Fujifilm/DCIM/100_FUJI", "DSCF0001", "JPG", "RAF"),
            ("Fujifilm/DCIM/100_FUJI", "DSCF0002", "HEIF", "raf"),
            ("Panasonic/DCIM/100XXXXX", "P1000001", "JPG", "RW2"),
            ("OMSystem/DCIM/100XXXXX", "P8230001", "JPG", "ORF"),
            ("Pentax/DCIM/100XXXXX", "IMGP0001", "JPG", "PEF"),
            ("Pentax/DCIM/100XXXXX", "IMGP0002", "JPG", "DNG"),
            ("Ricoh/DCIM/100XXXXX", "R0000001", "JPG", "dng"),
            ("Sigma/DCIM/100SIGMA", "SDIM0001", "JPG", "DNG")
        ]
        let rawOnly = ["CR3", "CR2", "ARW", "NEF", "RAF", "RW2", "ORF", "PEF", "DNG"]
        let renderedOnly = ["JPG", "jpeg", "HIF", "heif", "HEIC"]

        var timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for pair in pairs {
            let directory = root.appendingPathComponent(pair.directory, isDirectory: true)
            try writeFixture(directory.appendingPathComponent("\(pair.basename).\(pair.rendered)"), timestamp: timestamp)
            try writeFixture(directory.appendingPathComponent("\(pair.basename).\(pair.raw)"), timestamp: timestamp)
            timestamp = timestamp.addingTimeInterval(1)
        }
        for (index, extensionName) in rawOnly.enumerated() {
            let directory = root.appendingPathComponent("RawOnly", isDirectory: true)
            let basename = "RAW_\(index)"
            let file = directory.appendingPathComponent("\(basename).\(extensionName)")
            try writeFixture(file, timestamp: timestamp)
            timestamp = timestamp.addingTimeInterval(1)
        }
        for (index, extensionName) in renderedOnly.enumerated() {
            let directory = root.appendingPathComponent("RenderedOnly", isDirectory: true)
            let basename = "RENDERED_\(index)"
            let file = directory.appendingPathComponent("\(basename).\(extensionName)")
            try writeFixture(file, timestamp: timestamp)
            timestamp = timestamp.addingTimeInterval(1)
        }

        // The same basename in separate directories within each vendor tree
        // must remain separate groups, not just Canon versus Nikon groups.
        let separatedFiles = [
            root.appendingPathComponent("Canon/A/IMG_0001.JPG"),
            root.appendingPathComponent("Canon/A/IMG_0001.CR3"),
            root.appendingPathComponent("Canon/B/IMG_0001.JPG"),
            root.appendingPathComponent("Canon/B/IMG_0001.CR3"),
            root.appendingPathComponent("Nikon/A/DSC_0001.JPG"),
            root.appendingPathComponent("Nikon/A/DSC_0001.NEF"),
            root.appendingPathComponent("Nikon/B/DSC_0001.JPG"),
            root.appendingPathComponent("Nikon/B/DSC_0001.NEF")
        ]
        try writeFixture(separatedFiles[0], timestamp: timestamp)
        try writeFixture(separatedFiles[1], timestamp: timestamp)
        timestamp = timestamp.addingTimeInterval(1)
        try writeFixture(separatedFiles[2], timestamp: timestamp)
        try writeFixture(separatedFiles[3], timestamp: timestamp)
        timestamp = timestamp.addingTimeInterval(1)
        try writeFixture(separatedFiles[4], timestamp: timestamp)
        try writeFixture(separatedFiles[5], timestamp: timestamp)
        timestamp = timestamp.addingTimeInterval(1)
        try writeFixture(separatedFiles[6], timestamp: timestamp)
        try writeFixture(separatedFiles[7], timestamp: timestamp)
        timestamp = timestamp.addingTimeInterval(1)

        let management = root.appendingPathComponent("Canon/CANONMSC", isDirectory: true)
        try writeFixture(management.appendingPathComponent("MANAGEMENT.JPG"), timestamp: timestamp)
        try writeFixture(root.appendingPathComponent("unsupported/README.TXT"), timestamp: timestamp)
        try writeFixture(root.appendingPathComponent("unsupported/VIDEO.NEV"), timestamp: timestamp)
        try writeFixture(root.appendingPathComponent("unsupported/PHOTO.X3F"), timestamp: timestamp)
        try writeFixture(root.appendingPathComponent("unsupported/OTHER.BIN"), timestamp: timestamp)

        let scanner = InfrastructureTestSupport.scanner()
        let groups = scanner.scan(
            root: root,
            initialPresentationBatchSize: .max,
            initialPresentationGroupTarget: .max,
            progress: nil
        )

        for pair in pairs {
            let groupSuffix = "\(pair.directory)/\(pair.basename)"
            let group = try #require(groups.first { $0.id.hasSuffix(groupSuffix) }, "missing pair group: \(groupSuffix)")
            #expect(group.variants == [.renderedImage, .raw])
        }
        for (index, extensionName) in rawOnly.enumerated() {
            let basename = "RAW_\(index)"
            let groupSuffix = "RawOnly/\(basename)"
            let group = try #require(groups.first { $0.id.hasSuffix(groupSuffix) }, "missing RAW-only group: \(basename)")
            #expect(group.variants == [.raw], "\(extensionName) must classify as RAW")
        }
        for (index, extensionName) in renderedOnly.enumerated() {
            let basename = "RENDERED_\(index)"
            let groupSuffix = "RenderedOnly/\(basename)"
            let group = try #require(groups.first { $0.id.hasSuffix(groupSuffix) }, "missing rendered-only group: \(basename)")
            #expect(group.variants == [.renderedImage], "\(extensionName) must classify as rendered image")
        }

        #expect(groups.contains { $0.id.hasSuffix("Canon/A/IMG_0001") })
        #expect(groups.contains { $0.id.hasSuffix("Canon/B/IMG_0001") })
        #expect(groups.contains { $0.id.hasSuffix("Nikon/A/DSC_0001") })
        #expect(groups.contains { $0.id.hasSuffix("Nikon/B/DSC_0001") })
        #expect(groups.count == 15 + rawOnly.count + renderedOnly.count + 4)
        #expect(groups.allSatisfy { !$0.id.contains("CANONMSC") })
        #expect(groups.allSatisfy { !$0.id.contains("unsupported") })
        #expect(groups.map(\.presentationOrder) == Array(0..<groups.count))

        let repeated = scanner.scan(
            root: root,
            initialPresentationBatchSize: .max,
            initialPresentationGroupTarget: .max,
            progress: nil
        )
        #expect(groups.map(\.id) == repeated.map(\.id))
    }

    private func writeFixture(_ url: URL, timestamp: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic fixture; classification only".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.creationDate: timestamp, .modificationDate: timestamp],
            ofItemAtPath: url.path
        )
    }
}
