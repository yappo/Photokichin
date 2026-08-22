import CryptoKit
import Foundation
import Testing
@testable import PhotokichinDomain
@testable import PhotokichinApplication
@testable import PhotokichinInfrastructure

@Suite("File transfer imports")
struct FileTransferImportTests {
    private struct Fixture {
        let root: URL
        let source: URL
        let library: URL
        let catalog: CatalogStore
        let transfer: FileTransferService
    }

    @Test("JPG and CR3 import succeeds at the exact template destination")
    func jpgAndCR3ImportSucceedsAtExactDestination() throws {
        let fixture = try makeFixture(prefix: "pair-success")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        let group = try makeImportGroup(sourceRoot: fixture.source.appendingPathComponent("pair"), basename: "IMG_0001", jpegData: Data("pair-jpeg".utf8), rawData: Data("pair-raw".utf8), captureDate: captureDate)
        let result = try fixture.transfer.importGroup(group, to: fixture.library, template: "{date}_{camera}", catalog: fixture.catalog)
        let destination = libraryDirectory(for: group, under: fixture.library, transfer: fixture.transfer)
        let jpeg = destination.appendingPathComponent("IMG_0001.JPG")
        let raw = destination.appendingPathComponent("IMG_0001.CR3")
        #expect(result.copiedCount == 2)
        #expect(result.skippedCount == 0)
        #expect(result.failedCount == 0)
        #expect(FileManager.default.fileExists(atPath: jpeg.path))
        #expect(FileManager.default.fileExists(atPath: raw.path))
        try requireMatchingTimestamp(group.renderedImageURL!, jpeg, attribute: .creationDate, label: "JPG creation date")
        try requireMatchingTimestamp(group.renderedImageURL!, jpeg, attribute: .modificationDate, label: "JPG modification date")
        try requireMatchingTimestamp(group.rawURL!, raw, attribute: .creationDate, label: "CR3 creation date")
        try requireMatchingTimestamp(group.rawURL!, raw, attribute: .modificationDate, label: "CR3 modification date")
        try requireNoPartialFiles(under: destination)
    }

    @Test("Import uses Camera as the fallback folder and preserves a reported camera model")
    func importFolderFallbackUsesGenericCameraName() throws {
        let fixture = try makeFixture(prefix: "camera-folder-fallback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let captureDate = Date(timeIntervalSince1970: 1_700_000_000)

        let fallbackGroup = try makeImportGroup(
            sourceRoot: fixture.source.appendingPathComponent("fallback"),
            basename: "IMG_FALLBACK",
            jpegData: Data("fallback".utf8),
            rawData: nil,
            captureDate: captureDate
        )
        _ = try fixture.transfer.importGroup(
            fallbackGroup,
            to: fixture.library,
            template: "{date}_{camera}",
            catalog: fixture.catalog
        )
        let fallbackDirectory = fixture.library.appendingPathComponent(
            fixture.transfer.makeFolderName(template: "{date}_{camera}", date: captureDate, camera: "Camera"),
            isDirectory: true
        )
        #expect(FileManager.default.fileExists(atPath: fallbackDirectory.appendingPathComponent("IMG_FALLBACK.JPG").path))

        var namedGroup = try makeImportGroup(
            sourceRoot: fixture.source.appendingPathComponent("named"),
            basename: "IMG_NAMED",
            jpegData: Data("named".utf8),
            rawData: nil,
            captureDate: captureDate
        )
        namedGroup.metadata.cameraModel = "Nikon Z"
        _ = try fixture.transfer.importGroup(
            namedGroup,
            to: fixture.library,
            template: "{date}_{camera}",
            catalog: fixture.catalog
        )
        let namedDirectory = fixture.library.appendingPathComponent(
            fixture.transfer.makeFolderName(template: "{date}_{camera}", date: captureDate, camera: "Nikon Z"),
            isDirectory: true
        )
        #expect(FileManager.default.fileExists(atPath: namedDirectory.appendingPathComponent("IMG_NAMED.JPG").path))
    }

    @Test("Successful JPG and CR3 import registers both source identities")
    func successfulImportRegistersBothCatalogRecords() throws {
        let fixture = try makeFixture(prefix: "catalog-records")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let group = try makeImportGroup(sourceRoot: fixture.source.appendingPathComponent("pair"), basename: "IMG_0002", jpegData: Data("jpg".utf8), rawData: Data("raw".utf8), captureDate: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try fixture.transfer.importGroup(group, to: fixture.library, template: "{date}_{camera}", catalog: fixture.catalog)
        let destination = libraryDirectory(for: group, under: fixture.library, transfer: fixture.transfer)
        try requireCatalogRecord(fixture.catalog, transfer: fixture.transfer, group: group, variant: .renderedImage, destination: destination.appendingPathComponent("IMG_0002.JPG"), source: group.renderedImageURL!)
        try requireCatalogRecord(fixture.catalog, transfer: fixture.transfer, group: group, variant: .raw, destination: destination.appendingPathComponent("IMG_0002.CR3"), source: group.rawURL!)
    }

    @Test("Re-importing identical JPG and CR3 skips both files without rewriting them")
    func identicalReimportSkipsBothVariants() throws {
        let fixture = try makeFixture(prefix: "pair-reimport")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let group = try makeImportGroup(sourceRoot: fixture.source.appendingPathComponent("pair"), basename: "IMG_0003", jpegData: Data("jpg".utf8), rawData: Data("raw".utf8), captureDate: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try fixture.transfer.importGroup(group, to: fixture.library, template: "{date}_{camera}", catalog: fixture.catalog)
        let destination = libraryDirectory(for: group, under: fixture.library, transfer: fixture.transfer)
        let jpeg = destination.appendingPathComponent("IMG_0003.JPG")
        let raw = destination.appendingPathComponent("IMG_0003.CR3")
        let jpegBefore = try Data(contentsOf: jpeg)
        let rawBefore = try Data(contentsOf: raw)
        let result = try fixture.transfer.importGroup(group, to: fixture.library, template: "{date}_{camera}", catalog: fixture.catalog)
        #expect(result.copiedCount == 0)
        #expect(result.skippedCount == 2)
        #expect(result.failedCount == 0)
        #expect(try Data(contentsOf: jpeg) == jpegBefore)
        #expect(try Data(contentsOf: raw) == rawBefore)
    }

    @Test("Different content at the same destination preserves the existing file")
    func conflictingContentIsNotOverwritten() throws {
        let fixture = try makeFixture(prefix: "pair-conflict")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try makeImportGroup(sourceRoot: fixture.source.appendingPathComponent("first"), basename: "IMG_0004", jpegData: Data("original".utf8), rawData: nil, captureDate: captureDate)
        _ = try fixture.transfer.importGroup(first, to: fixture.library, template: "{date}_{camera}", catalog: fixture.catalog)
        let destination = libraryDirectory(for: first, under: fixture.library, transfer: fixture.transfer).appendingPathComponent("IMG_0004.JPG")
        let conflict = try makeImportGroup(sourceRoot: fixture.source.appendingPathComponent("conflict"), basename: "IMG_0004", jpegData: Data("different".utf8), rawData: nil, captureDate: captureDate)
        let result = try fixture.transfer.importGroup(conflict, to: fixture.library, template: "{date}_{camera}", catalog: fixture.catalog)
        #expect(result.copiedCount == 0)
        #expect(result.skippedCount == 0)
        #expect(result.failedCount == 1)
        #expect(try Data(contentsOf: destination) == Data("original".utf8))
        try requireNoPartialFiles(under: destination.deletingLastPathComponent())
        #expect(fixture.catalog.importedDestination(sourceKey: fixture.transfer.sourceKey(for: conflict, variant: .renderedImage), variant: .renderedImage) == nil)
    }

    @Test("JPG-only import copies one file and leaves no partial file")
    func jpgOnlyImport() throws {
        let fixture = try makeFixture(prefix: "jpg-only")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let group = try makeImportGroup(sourceRoot: fixture.source.appendingPathComponent("jpg"), basename: "IMG_0005", jpegData: Data("jpg-only".utf8), rawData: nil, captureDate: Date(timeIntervalSince1970: 1_700_086_400))
        let result = try fixture.transfer.importGroup(group, to: fixture.library, template: "{date}_{camera}", catalog: fixture.catalog)
        let destination = libraryDirectory(for: group, under: fixture.library, transfer: fixture.transfer)
        #expect(result.copiedCount == 1)
        #expect(result.failedCount == 0)
        let destinationURL = destination.appendingPathComponent("IMG_0005.JPG")
        try requireCatalogRecord(
            fixture.catalog,
            transfer: fixture.transfer,
            group: group,
            variant: .renderedImage,
            destination: destinationURL,
            source: group.renderedImageURL!
        )
        try requireNoPartialFiles(under: destination)
    }

    @Test("CR3-only import copies one file and leaves no partial file")
    func cr3OnlyImport() throws {
        let fixture = try makeFixture(prefix: "raw-only")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let group = try makeImportGroup(sourceRoot: fixture.source.appendingPathComponent("raw"), basename: "IMG_0006", jpegData: nil, rawData: Data("raw-only".utf8), captureDate: Date(timeIntervalSince1970: 1_700_172_800))
        let result = try fixture.transfer.importGroup(group, to: fixture.library, template: "{date}_{camera}", catalog: fixture.catalog)
        let destination = libraryDirectory(for: group, under: fixture.library, transfer: fixture.transfer)
        #expect(result.copiedCount == 1)
        #expect(result.failedCount == 0)
        let destinationURL = destination.appendingPathComponent("IMG_0006.CR3")
        try requireCatalogRecord(
            fixture.catalog,
            transfer: fixture.transfer,
            group: group,
            variant: .raw,
            destination: destinationURL,
            source: group.rawURL!
        )
        try requireNoPartialFiles(under: destination)
    }

    @Test("Missing JPG and CR3 sources report two failures and no catalog records")
    func missingSourcesFailWithoutRecords() throws {
        let fixture = try makeFixture(prefix: "missing-source")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceRoot = fixture.source.appendingPathComponent("missing")
        let group = PhotoGroup(id: sourceRoot.appendingPathComponent("IMG_0007").path, basename: "IMG_0007", directory: sourceRoot, renderedImageURL: sourceRoot.appendingPathComponent("IMG_0007.JPG"), rawURL: sourceRoot.appendingPathComponent("IMG_0007.CR3"), movieURL: nil, captureDate: Date(timeIntervalSince1970: 1_700_259_200), metadata: .empty, importedRenderedImage: false, importedRAW: false, isMetadataLoaded: true)
        let result = try fixture.transfer.importGroup(group, to: fixture.library, template: "{date}_{camera}", catalog: fixture.catalog)
        #expect(result.copiedCount == 0)
        #expect(result.failedCount == 2)
        try requireNoPartialFiles(under: fixture.library)
        #expect(fixture.catalog.importedDestination(sourceKey: fixture.transfer.sourceKey(for: group, variant: .renderedImage), variant: .renderedImage) == nil)
        #expect(fixture.catalog.importedDestination(sourceKey: fixture.transfer.sourceKey(for: group, variant: .raw), variant: .raw) == nil)
    }

    @Test("Pre-cancelled import creates no directory, files, or records")
    func preCancelledImport() throws {
        let fixture = try makeFixture(prefix: "cancelled")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let group = try makeImportGroup(sourceRoot: fixture.source.appendingPathComponent("cancelled"), basename: "IMG_0008", jpegData: Data("cancelled-jpeg".utf8), rawData: Data("cancelled-raw".utf8), captureDate: Date(timeIntervalSince1970: 1_700_345_600))
        let token = ImportCancellationToken()
        token.cancel()
        #expect(throws: CancellationError.self) { try fixture.transfer.importGroup(group, to: fixture.library, template: "{date}_{camera}", catalog: fixture.catalog, cancellation: token) }
        let destination = libraryDirectory(for: group, under: fixture.library, transfer: fixture.transfer)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try requireNoPartialFiles(under: fixture.library)
        #expect(fixture.catalog.importedDestination(sourceKey: fixture.transfer.sourceKey(for: group, variant: .renderedImage), variant: .renderedImage) == nil)
    }

    @Test("Interrupted copy removes the completed destination and both catalog records")
    func interruptedCopyRollsBack() throws {
        let fixture = try makeFixture(prefix: "interrupted")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let group = try makeImportGroup(sourceRoot: fixture.source.appendingPathComponent("interrupted"), basename: "IMG_0009", jpegData: Data("interrupted-jpeg-content".utf8), rawData: Data("interrupted-raw-content".utf8), captureDate: Date(timeIntervalSince1970: 1_700_432_000))
        let token = ImportCancellationToken()
        let transfer = FileTransferService { sourceURL, partialURL, cancellation, _ in
            let sourceData = try Data(contentsOf: sourceURL)
            try Data(sourceData.prefix(max(1, sourceData.count / 2))).write(to: partialURL)
            cancellation?.cancel()
            throw CancellationError()
        }
        #expect(throws: CancellationError.self) { try transfer.importGroup(group, to: fixture.library, template: "{date}_{camera}", catalog: fixture.catalog, cancellation: token) }
        let destination = libraryDirectory(for: group, under: fixture.library, transfer: transfer)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("IMG_0009.JPG").path))
        try requireNoPartialFiles(under: destination)
        #expect(fixture.catalog.importedDestination(sourceKey: transfer.sourceKey(for: group, variant: .renderedImage), variant: .renderedImage) == nil)
        #expect(fixture.catalog.importedDestination(sourceKey: transfer.sourceKey(for: group, variant: .raw), variant: .raw) == nil)
    }

    @Test("Scanner excludes CANONMSC management files")
    func canonManagementFilesAreExcluded() throws {
        let fixture = try makeFixture(prefix: "canon-management")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let management = fixture.source.appendingPathComponent("CANONMSC", isDirectory: true)
        try FileManager.default.createDirectory(at: management, withIntermediateDirectories: true)
        try Data("canon-management-file".utf8).write(to: management.appendingPathComponent("IMG_9999.JPG"))
        let groups = InfrastructureTestSupport.scan(root: fixture.source)
        #expect(groups.allSatisfy { !$0.id.contains("CANONMSC") })
    }

    private func makeFixture(prefix: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return Fixture(root: root, source: source, library: library, catalog: try InfrastructureTestSupport.catalogStore(libraryRoot: library), transfer: FileTransferService())
    }

    private func makeImportGroup(sourceRoot: URL, basename: String, jpegData: Data?, rawData: Data?, captureDate: Date) throws -> PhotoGroup {
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let renderedImageURL = jpegData.map { _ in sourceRoot.appendingPathComponent("\(basename).JPG") }
        let rawURL = rawData.map { _ in sourceRoot.appendingPathComponent("\(basename).CR3") }
        if let jpegData, let renderedImageURL {
            try jpegData.write(to: renderedImageURL)
            try setTestTimestamps(renderedImageURL, creationDate: captureDate, modificationDate: captureDate.addingTimeInterval(7))
        }
        if let rawData, let rawURL {
            try rawData.write(to: rawURL)
            try setTestTimestamps(rawURL, creationDate: captureDate, modificationDate: captureDate.addingTimeInterval(11))
        }
        return PhotoGroup(id: sourceRoot.appendingPathComponent(basename).path, basename: basename, directory: sourceRoot, renderedImageURL: renderedImageURL, rawURL: rawURL, movieURL: nil, captureDate: captureDate, metadata: .empty, importedRenderedImage: false, importedRAW: false, isMetadataLoaded: true)
    }

    private func libraryDirectory(for group: PhotoGroup, under libraryRoot: URL, transfer: FileTransferService) -> URL {
        let date = group.metadata.captureDate ?? group.captureDate ?? Date()
        let camera = group.metadata.cameraModel ?? "Camera"
        return libraryRoot.appendingPathComponent(transfer.makeFolderName(template: "{date}_{camera}", date: date, camera: camera), isDirectory: true)
    }

    private func requireCatalogRecord(_ catalog: CatalogStore, transfer: FileTransferService, group: PhotoGroup, variant: AssetVariant, destination: URL, source: URL) throws {
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let sourceData = try Data(contentsOf: source)
        guard let record = catalog.contentRecord(for: destination, variant: variant) else { throw NSError(domain: "PhotokichinTests", code: 71) }
        let sourceHash = try hash(source)
        #expect(record.sha256 == sourceHash)
        #expect(record.fileSize == Int64(sourceData.count))
        #expect(catalog.importedDestination(sourceKey: transfer.sourceKey(for: group, variant: variant), variant: variant)?.standardizedFileURL.path == destination.standardizedFileURL.path)
    }

    private func requireNoPartialFiles(under root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw NSError(domain: "PhotokichinTests", code: 72) }
        let partials = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasPrefix(".photokichin-partial-") }
        #expect(partials.isEmpty, "incomplete temporary files remain: \(partials.map(\.path).joined(separator: ", "))")
    }

    private func setTestTimestamps(_ url: URL, creationDate: Date, modificationDate: Date) throws {
        try FileManager.default.setAttributes([.creationDate: creationDate, .modificationDate: modificationDate], ofItemAtPath: url.path)
    }

    private func requireMatchingTimestamp(_ source: URL, _ destination: URL, attribute: FileAttributeKey, label: String) throws {
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let destinationAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard let sourceDate = sourceAttributes[attribute] as? Date, let destinationDate = destinationAttributes[attribute] as? Date else { return }
        #expect(abs(sourceDate.timeIntervalSince(destinationDate)) < 1, "\(label) was not preserved")
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
