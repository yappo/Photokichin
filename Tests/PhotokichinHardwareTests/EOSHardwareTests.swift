import Foundation
import Testing
@testable import PhotokichinApplication
@testable import PhotokichinDomain
@testable import PhotokichinInfrastructure

private let hardwareTestsEnabled = ProcessInfo.processInfo.environment["PHOTOKICHIN_RUN_HARDWARE_TESTS"] == "1"

@Suite("EOS hardware", .serialized)
struct EOSHardwareTests {
    @Test(
        "Mounted EOS card can be scanned",
        .enabled(if: hardwareTestsEnabled, "PHOTOKICHIN_RUN_HARDWARE_TESTS=1 のときだけ実行します")
    )
    func mountedCard() throws {
        let card = URL(fileURLWithPath: "/Volumes/EOS_DIGITAL")
        try #require(
            FileManager.default.fileExists(atPath: card.path),
            "PHOTOKICHIN_RUN_HARDWARE_TESTS=1ですが、/Volumes/EOS_DIGITALがマウントされていません"
        )
        let groups = PhotoScanner().scan(
            root: card,
            initialPresentationBatchSize: .max,
            initialPresentationGroupTarget: .max,
            progress: nil
        )
        if let expected = ProcessInfo.processInfo.environment["PHOTOKICHIN_EXPECTED_GROUPS"].flatMap(Int.init) {
            #expect(groups.count == expected)
        } else {
            #expect(!groups.isEmpty)
        }
        #expect(groups.contains { $0.jpegURL != nil && $0.rawURL != nil })
        #expect(groups.allSatisfy { !$0.id.contains("CANONMSC") })

        let first = try #require(groups.first { $0.jpegURL != nil && $0.rawURL != nil })
        let jpeg = try #require(first.jpegURL)
        let raw = try #require(first.rawURL)
        let metadata = try #require(ImageIOMediaReader().readMetadata(url: jpeg))
        #expect(metadata.cameraModel?.contains("EOS R") == true)
        #expect(metadata.captureDate != nil)
        #expect(metadata.iso != nil)

        let transfer = FileTransferService()
        #expect(transfer.urlsForAirDrop([first], mode: .jpegAndRaw).count == 2)
        #expect(transfer.urlsForAirDrop([first], mode: .jpegOnly).count == 1)
        #expect(transfer.urlsForAirDrop([first], mode: .rawOnly).count == 1)

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-hardware-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let catalog = try CatalogStore(libraryRoot: temporaryRoot)
        let result = try transfer.importGroup(
            first,
            to: temporaryRoot,
            template: "{date}_{camera}",
            catalog: catalog,
            cancellation: ImportCancellationToken()
        )
        #expect(result.copiedCount == 2)
        #expect(result.failedCount == 0)

        let copiedJPEG = try findFile(named: jpeg.lastPathComponent, under: temporaryRoot)
        let copiedRAW = try findFile(named: raw.lastPathComponent, under: temporaryRoot)
        #expect(FileManager.default.fileExists(atPath: copiedJPEG.path))
        #expect(FileManager.default.fileExists(atPath: copiedRAW.path))
        try expectMatchingTimestamp(jpeg, copiedJPEG, attribute: .creationDate)
        try expectMatchingTimestamp(jpeg, copiedJPEG, attribute: .modificationDate)
        try expectMatchingTimestamp(raw, copiedRAW, attribute: .creationDate)
        try expectMatchingTimestamp(raw, copiedRAW, attribute: .modificationDate)
    }

    private func findFile(named name: String, under root: URL) throws -> URL {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        Issue.record("取り込み先に\(name)がありません")
        throw CancellationError()
    }

    private func expectMatchingTimestamp(
        _ source: URL,
        _ destination: URL,
        attribute: FileAttributeKey
    ) throws {
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let destinationAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard let sourceDate = sourceAttributes[attribute] as? Date,
              let destinationDate = destinationAttributes[attribute] as? Date else { return }
        #expect(abs(sourceDate.timeIntervalSince(destinationDate)) < 1)
    }
}
