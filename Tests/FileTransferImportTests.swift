import Foundation
@testable import PhotokichinCore

extension PhotokichinTestRunner {
    /// Exercises the removable-volume import path using only temporary files.
    /// The EOS hardware test remains separate because it is not deterministic
    /// and must never turn an absent camera into a passing result.
    static func runFileTransferImportTests() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-file-transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let catalog = try CatalogStore(libraryRoot: libraryRoot)
        let transfer = FileTransferService()

        let pairDate = Date(timeIntervalSince1970: 1_700_000_000)
        let pairSource = sourceRoot.appendingPathComponent("pair", isDirectory: true)
        let pair = try makeImportGroup(
            sourceRoot: pairSource,
            basename: "IMG_0001",
            jpegData: Data("pair-jpeg".utf8),
            rawData: Data("pair-raw".utf8),
            captureDate: pairDate
        )
        let pairResult = try transfer.importGroup(
            pair,
            to: libraryRoot,
            template: "{date}_{camera}",
            catalog: catalog
        )
        try require(pairResult.copiedCount == 2, "JPG＋CR3 import must copy two files")
        try require(pairResult.skippedCount == 0, "the first JPG＋CR3 import must not skip files")
        try require(pairResult.failedCount == 0, "JPG＋CR3 import failed: \(pairResult.message)")
        let pairDirectory = libraryDirectory(for: pair, under: libraryRoot, transfer: transfer)
        let pairJPEG = pairDirectory.appendingPathComponent("IMG_0001.JPG")
        let pairRAW = pairDirectory.appendingPathComponent("IMG_0001.CR3")
        try require(FileManager.default.fileExists(atPath: pairJPEG.path), "imported JPG is missing")
        try require(FileManager.default.fileExists(atPath: pairRAW.path), "imported CR3 is missing")
        try requireCatalogRecord(catalog, transfer: transfer, group: pair, variant: .jpeg, destination: pairJPEG, source: pair.jpegURL!)
        try requireCatalogRecord(catalog, transfer: transfer, group: pair, variant: .raw, destination: pairRAW, source: pair.rawURL!)
        try requireMatchingTimestamp(pair.jpegURL!, pairJPEG, attribute: .creationDate, label: "JPG creation date")
        try requireMatchingTimestamp(pair.jpegURL!, pairJPEG, attribute: .modificationDate, label: "JPG modification date")
        try requireMatchingTimestamp(pair.rawURL!, pairRAW, attribute: .creationDate, label: "CR3 creation date")
        try requireMatchingTimestamp(pair.rawURL!, pairRAW, attribute: .modificationDate, label: "CR3 modification date")

        let pairAgain = try transfer.importGroup(
            pair,
            to: libraryRoot,
            template: "{date}_{camera}",
            catalog: catalog
        )
        try require(pairAgain.copiedCount == 0, "an identical re-import must not rewrite files")
        try require(pairAgain.skippedCount == 2, "an identical JPG＋CR3 re-import must skip two files")
        try require(pairAgain.failedCount == 0, "an identical JPG＋CR3 re-import must not fail")

        let conflictSource = sourceRoot.appendingPathComponent("conflict", isDirectory: true)
        let conflict = try makeImportGroup(
            sourceRoot: conflictSource,
            basename: "IMG_0001",
            jpegData: Data("different-jpeg-content".utf8),
            rawData: nil,
            captureDate: pairDate
        )
        let conflictResult = try transfer.importGroup(
            conflict,
            to: libraryRoot,
            template: "{date}_{camera}",
            catalog: catalog
        )
        try require(conflictResult.copiedCount == 0, "a same-name different-content file must not overwrite")
        try require(conflictResult.skippedCount == 0, "a same-name different-content file must not be skipped")
        try require(conflictResult.failedCount == 1, "a same-name different-content file must report one failure")
        try require(Data(contentsOf: pairJPEG) == Data("pair-jpeg".utf8), "a copy conflict must preserve the existing JPG")
        try requireNoPartialFiles(under: pairDirectory)
        try require(
            catalog.importedDestination(
                sourceKey: transfer.sourceKey(for: conflict, variant: .jpeg),
                variant: .jpeg
            ) == nil,
            "a copy conflict must not register the conflicting source"
        )

        let jpegOnlyDate = Date(timeIntervalSince1970: 1_700_086_400)
        let jpegOnly = try makeImportGroup(
            sourceRoot: sourceRoot.appendingPathComponent("jpeg-only", isDirectory: true),
            basename: "IMG_0002",
            jpegData: Data("jpeg-only".utf8),
            rawData: nil,
            captureDate: jpegOnlyDate
        )
        let jpegOnlyResult = try transfer.importGroup(
            jpegOnly,
            to: libraryRoot,
            template: "{date}_{camera}",
            catalog: catalog
        )
        try require(jpegOnlyResult.copiedCount == 1, "JPG-only import must copy one file")
        try require(jpegOnlyResult.failedCount == 0, "JPG-only import failed: \(jpegOnlyResult.message)")
        let jpegOnlyDestination = libraryDirectory(for: jpegOnly, under: libraryRoot, transfer: transfer)
            .appendingPathComponent("IMG_0002.JPG")
        try requireCatalogRecord(catalog, transfer: transfer, group: jpegOnly, variant: .jpeg, destination: jpegOnlyDestination, source: jpegOnly.jpegURL!)
        try requireNoPartialFiles(under: jpegOnlyDestination.deletingLastPathComponent())

        let rawOnlyDate = Date(timeIntervalSince1970: 1_700_172_800)
        let rawOnly = try makeImportGroup(
            sourceRoot: sourceRoot.appendingPathComponent("raw-only", isDirectory: true),
            basename: "IMG_0003",
            jpegData: nil,
            rawData: Data("raw-only".utf8),
            captureDate: rawOnlyDate
        )
        let rawOnlyResult = try transfer.importGroup(
            rawOnly,
            to: libraryRoot,
            template: "{date}_{camera}",
            catalog: catalog
        )
        try require(rawOnlyResult.copiedCount == 1, "CR3-only import must copy one file")
        try require(rawOnlyResult.failedCount == 0, "CR3-only import failed: \(rawOnlyResult.message)")
        let rawOnlyDestination = libraryDirectory(for: rawOnly, under: libraryRoot, transfer: transfer)
            .appendingPathComponent("IMG_0003.CR3")
        try requireCatalogRecord(catalog, transfer: transfer, group: rawOnly, variant: .raw, destination: rawOnlyDestination, source: rawOnly.rawURL!)
        try requireNoPartialFiles(under: rawOnlyDestination.deletingLastPathComponent())

        let missingSource = PhotoGroup(
            id: "missing-source",
            basename: "IMG_0004",
            directory: sourceRoot,
            jpegURL: sourceRoot.appendingPathComponent("missing/IMG_0004.JPG"),
            rawURL: sourceRoot.appendingPathComponent("missing/IMG_0004.CR3"),
            movieURL: nil,
            captureDate: Date(timeIntervalSince1970: 1_700_259_200),
            metadata: .empty,
            importedJPEG: false,
            importedRAW: false,
            isMetadataLoaded: true
        )
        let missingResult = try transfer.importGroup(
            missingSource,
            to: libraryRoot,
            template: "{date}_{camera}",
            catalog: catalog
        )
        try require(missingResult.copiedCount == 0, "missing source files must not be reported as copied")
        try require(missingResult.failedCount == 2, "both missing source files must be reported as failures")
        try requireNoPartialFiles(under: libraryDirectory(for: missingSource, under: libraryRoot, transfer: transfer))
        try require(
            catalog.importedDestination(
                sourceKey: transfer.sourceKey(for: missingSource, variant: .jpeg),
                variant: .jpeg
            ) == nil,
            "missing source files must not be registered in the catalog"
        )

        let cancelled = ImportCancellationToken()
        cancelled.cancel()
        let cancelledGroup = try makeImportGroup(
            sourceRoot: sourceRoot.appendingPathComponent("cancelled", isDirectory: true),
            basename: "IMG_0005",
            jpegData: Data("cancelled-jpeg".utf8),
            rawData: Data("cancelled-raw".utf8),
            captureDate: Date(timeIntervalSince1970: 1_700_345_600)
        )
        do {
            _ = try transfer.importGroup(
                cancelledGroup,
                to: libraryRoot,
                template: "{date}_{camera}",
                catalog: catalog,
                cancellation: cancelled
            )
            throw NSError(domain: "PhotokichinTests", code: 70, userInfo: [NSLocalizedDescriptionKey: "a pre-cancelled import unexpectedly succeeded"])
        } catch is CancellationError {
            // Expected: the cancellation check happens before the destination
            // directory is created or any catalog transaction is started.
        }
        let cancelledDirectory = libraryDirectory(for: cancelledGroup, under: libraryRoot, transfer: transfer)
        try require(!FileManager.default.fileExists(atPath: cancelledDirectory.path), "a pre-cancelled import must not create a destination directory")
        try requireNoPartialFiles(under: libraryRoot)
        try require(
            catalog.importedDestination(
                sourceKey: transfer.sourceKey(for: cancelledGroup, variant: .jpeg),
                variant: .jpeg
            ) == nil,
            "a pre-cancelled import must not write catalog records"
        )

        let interruptedToken = ImportCancellationToken()
        let interruptedGroup = try makeImportGroup(
            sourceRoot: sourceRoot.appendingPathComponent("interrupted", isDirectory: true),
            basename: "IMG_0006",
            jpegData: Data("interrupted-jpeg-content".utf8),
            rawData: Data("interrupted-raw-content".utf8),
            captureDate: Date(timeIntervalSince1970: 1_700_432_000)
        )
        let interruptedTransfer = FileTransferService { sourceURL, partialURL, cancellation, _ in
            let sourceData = try Data(contentsOf: sourceURL)
            let partialByteCount = max(1, sourceData.count / 2)
            try Data(sourceData.prefix(partialByteCount)).write(to: partialURL)
            cancellation?.cancel()
            throw CancellationError()
        }
        do {
            _ = try interruptedTransfer.importGroup(
                interruptedGroup,
                to: libraryRoot,
                template: "{date}_{camera}",
                catalog: catalog,
                cancellation: interruptedToken
            )
            throw NSError(domain: "PhotokichinTests", code: 73, userInfo: [NSLocalizedDescriptionKey: "a copy interrupted after a partial write unexpectedly succeeded"])
        } catch is CancellationError {
            // Expected: the test copy seam writes a fixed prefix and then
            // cancels before importGroup can move it to its final filename.
        }
        let interruptedDirectory = libraryDirectory(for: interruptedGroup, under: libraryRoot, transfer: interruptedTransfer)
        try require(
            !FileManager.default.fileExists(atPath: interruptedDirectory.appendingPathComponent("IMG_0006.JPG").path),
            "an interrupted copy must not leave a completed destination"
        )
        try requireNoPartialFiles(under: interruptedDirectory)
        try require(
            catalog.importedDestination(
                sourceKey: interruptedTransfer.sourceKey(for: interruptedGroup, variant: .jpeg),
                variant: .jpeg
            ) == nil,
            "an interrupted copy must not write a JPG catalog record"
        )
        try require(
            catalog.importedDestination(
                sourceKey: interruptedTransfer.sourceKey(for: interruptedGroup, variant: .raw),
                variant: .raw
            ) == nil,
            "an interrupted copy must not write a CR3 catalog record"
        )

        let canonManagement = sourceRoot.appendingPathComponent("CANONMSC", isDirectory: true)
        try FileManager.default.createDirectory(at: canonManagement, withIntermediateDirectories: true)
        try Data("canon-management-file".utf8).write(to: canonManagement.appendingPathComponent("IMG_9999.JPG"))
        let scannedSourceGroups = PhotoScanner.scan(root: sourceRoot)
        try require(
            scannedSourceGroups.allSatisfy { !$0.id.contains("CANONMSC") },
            "the deterministic source scan must continue to exclude CANONMSC"
        )

        print("PASS: deterministic JPG＋CR3/JPG-only/CR3-only import, conflict handling, timestamps, cleanup, catalog registration, and pre-cancel cancellation")
    }

    private static func makeImportGroup(
        sourceRoot: URL,
        basename: String,
        jpegData: Data?,
        rawData: Data?,
        captureDate: Date
    ) throws -> PhotoGroup {
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let jpegURL = jpegData.map { _ in sourceRoot.appendingPathComponent("\(basename).JPG") }
        let rawURL = rawData.map { _ in sourceRoot.appendingPathComponent("\(basename).CR3") }
        if let jpegData, let jpegURL {
            try jpegData.write(to: jpegURL)
            try setTestTimestamps(jpegURL, creationDate: captureDate, modificationDate: captureDate.addingTimeInterval(7))
        }
        if let rawData, let rawURL {
            try rawData.write(to: rawURL)
            try setTestTimestamps(rawURL, creationDate: captureDate, modificationDate: captureDate.addingTimeInterval(11))
        }
        return PhotoGroup(
            id: sourceRoot.appendingPathComponent(basename).path,
            basename: basename,
            directory: sourceRoot,
            jpegURL: jpegURL,
            rawURL: rawURL,
            movieURL: nil,
            captureDate: captureDate,
            metadata: .empty,
            importedJPEG: false,
            importedRAW: false,
            isMetadataLoaded: true
        )
    }

    private static func libraryDirectory(for group: PhotoGroup, under libraryRoot: URL, transfer: FileTransferService) -> URL {
        let date = group.metadata.captureDate ?? group.captureDate ?? Date()
        let camera = group.metadata.cameraModel ?? "EOS R"
        return libraryRoot.appendingPathComponent(
            transfer.makeFolderName(template: "{date}_{camera}", date: date, camera: camera),
            isDirectory: true
        )
    }

    private static func requireCatalogRecord(
        _ catalog: CatalogStore,
        transfer: FileTransferService,
        group: PhotoGroup,
        variant: AssetVariant,
        destination: URL,
        source: URL
    ) throws {
        try require(FileManager.default.fileExists(atPath: destination.path), "catalog destination file is missing: \(destination.lastPathComponent)")
        let sourceData = try Data(contentsOf: source)
        guard let record = catalog.contentRecord(for: destination, variant: variant) else {
            throw NSError(domain: "PhotokichinTests", code: 71, userInfo: [NSLocalizedDescriptionKey: "catalog record is missing for \(destination.lastPathComponent)"])
        }
        try require(record.sha256 == hash(source), "catalog SHA-256 does not match \(destination.lastPathComponent)")
        try require(record.fileSize == Int64(sourceData.count), "catalog file size does not match \(destination.lastPathComponent)")
        let sourceKey = transfer.sourceKey(for: group, variant: variant)
        try require(
            catalog.importedDestination(sourceKey: sourceKey, variant: variant)?.standardizedFileURL.path == destination.standardizedFileURL.path,
            "catalog source identity does not point to \(destination.lastPathComponent)"
        )
    }

    private static func requireNoPartialFiles(under root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "PhotokichinTests", code: 72, userInfo: [NSLocalizedDescriptionKey: "cannot enumerate import destination"])
        }
        let partials = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasPrefix(".photokichin-partial-") }
        try require(partials.isEmpty, "incomplete temporary files remain: \(partials.map(\.path).joined(separator: ", "))")
    }

    private static func setTestTimestamps(_ url: URL, creationDate: Date, modificationDate: Date) throws {
        try FileManager.default.setAttributes(
            [.creationDate: creationDate, .modificationDate: modificationDate],
            ofItemAtPath: url.path
        )
    }
}
