import Foundation
import CryptoKit
import Testing
@testable import PhotokichinDomain
@testable import PhotokichinApplication
@testable import PhotokichinInfrastructure

@Suite("Infrastructure behaviors")
struct InfrastructureBehaviorTests {

    @Test("ImageIO metadata parser reads camera properties")
    func metadataParser() throws {
        let cameraMetadata = ImageIOReader.readMetadata(properties: [
            "{Exif}": [
                "LensModel": "RF24-70mm F2.8 L IS USM",
                "FocalLength": 50.0,
                "FNumber": 2.8,
                "ExposureTime": 0.008,
                "ISOSpeedRatings": 800,
                "ExposureBiasValue": 0.0
            ],
            "{TIFF}": [
                "Make": "Canon",
                "Model": "Canon EOS R5m2"
            ]
        ])
        #expect(cameraMetadata?.lensModel == "RF24-70mm F2.8 L IS USM", "camera metadata parser must expose the lens")
        #expect(cameraMetadata?.aperture != nil, "camera metadata parser must expose the aperture")
        #expect(cameraMetadata?.shutterSpeed != nil, "camera metadata parser must expose the shutter speed")
        #expect(cameraMetadata?.iso != nil, "camera metadata parser must expose ISO")

    }

    @Test("Library AirDrop returns readable selected assets")
    func libraryAirDrop() throws {
        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-library-airdrop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        let jpegURL = libraryRoot.appendingPathComponent("IMG_0001.JPG")
        let rawURL = libraryRoot.appendingPathComponent("IMG_0001.CR3")
        try Data("library-jpeg".utf8).write(to: jpegURL)
        try Data("library-raw".utf8).write(to: rawURL)

        let groups = PhotoScanner.scan(root: libraryRoot)
        guard let group = groups.first else {
            throw NSError(domain: "PhotokichinTests", code: 20, userInfo: [NSLocalizedDescriptionKey: "temporary library photo was not scanned"])
        }
        let transfer = FileTransferService()
        let both = transfer.urlsForAirDrop([group], mode: .jpegAndRaw)
        let expectedPaths = Set([jpegURL, rawURL].map(\.standardizedFileURL.path))
        #expect(Set(both.map(\.standardizedFileURL.path)) == expectedPaths, "library JPG＋CR3 AirDrop must use the library file URLs")
        #expect(transfer.urlsForAirDrop([group], mode: .jpegOnly).map(\.standardizedFileURL.path) == [jpegURL.standardizedFileURL.path], "library JPG-only AirDrop must use the library JPG URL")
        #expect(transfer.urlsForAirDrop([group], mode: .rawOnly).map(\.standardizedFileURL.path) == [rawURL.standardizedFileURL.path], "library CR3-only AirDrop must use the library CR3 URL")
        #expect(both.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) }, "library AirDrop URLs must be readable files")
    }

    @Test("Catalog registration detects missing files and relinks candidates")
    func catalogRegistration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let importedFolder = root.appendingPathComponent("imported", isDirectory: true)
        let movedFolder = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: movedFolder, withIntermediateDirectories: true)

        let source = root.deletingLastPathComponent().appendingPathComponent("source-\(UUID().uuidString).jpg")
        let contents = Data("photokichin-catalog-test".utf8)
        try contents.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = importedFolder.appendingPathComponent("IMG_0001.JPG")
        try FileManager.default.copyItem(at: source, to: destination)

        let store = try CatalogStore(libraryRoot: root)
        let sourceKey = "/Volumes/EOS_DIGITAL/DCIM/100EOS_R/IMG_0001:JPG"
        try store.recordImport(sourceKey: sourceKey, variant: .jpeg, destinationURL: destination, sha256: hash(source))
        let unregistered = root.appendingPathComponent("IMG_0002.JPG")
        try Data("unregistered".utf8).write(to: unregistered)

        var inspection = try store.inspectLibrary()
        #expect(inspection.summary.unregisteredPhotoCount == 1, "unregistered library file was not detected")

        let candidate = movedFolder.appendingPathComponent("IMG_0001.JPG")
        try FileManager.default.moveItem(at: destination, to: candidate)
        inspection = try store.inspectLibrary()
        guard let issue = inspection.issues.first(where: { $0.sourceKey == sourceKey && $0.issueType == "candidate" }) else {
            throw NSError(domain: "PhotokichinTests", code: 21, userInfo: [NSLocalizedDescriptionKey: "moved file candidate was not detected"])
        }
        try store.relink(issueID: issue.id, to: candidate)
        #expect(store.importedDestination(sourceKey: sourceKey, variant: .jpeg)?.standardizedFileURL == candidate.standardizedFileURL, "relink did not update destination")

        let backup = root.deletingLastPathComponent().appendingPathComponent("Photokichin-catalog-backup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: backup) }
        try store.backup(to: backup)
        #expect(FileManager.default.fileExists(atPath: backup.path), "catalog backup was not created")
        #expect(store.integrityReport() == "ok", "catalog integrity check failed")

        print("PASS: catalog migration, unregistered detection, candidate relink, backup, and integrity check")
    }

    @Test("Library copy registers JPG and CR3 in the destination catalog")
    func libraryCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-library-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let targetRoot = root.appendingPathComponent("target", isDirectory: true)
        let sourceFolder = sourceRoot.appendingPathComponent("2026-08-12_EOS R", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let jpeg = sourceFolder.appendingPathComponent("IMG_0001.JPG")
        let raw = sourceFolder.appendingPathComponent("IMG_0001.CR3")
        try Data("jpg".utf8).write(to: jpeg)
        try Data("cr3".utf8).write(to: raw)

        let group = PhotoGroup(
            id: sourceFolder.appendingPathComponent("IMG_0001").path,
            basename: "IMG_0001",
            directory: sourceFolder,
            jpegURL: jpeg,
            rawURL: raw,
            movieURL: nil,
            captureDate: Date(timeIntervalSince1970: 0),
            metadata: .empty,
            importedJPEG: true,
            importedRAW: true,
            isMetadataLoaded: true
        )
        let sourceCatalog = try CatalogStore(libraryRoot: sourceRoot)
        let targetCatalog = try CatalogStore(libraryRoot: targetRoot)
        let result = try FileTransferService().copyLibraryGroup(
            group,
            from: sourceRoot,
            to: targetRoot,
            sourceCatalog: sourceCatalog,
            destinationCatalog: targetCatalog
        )
        #expect(result.copiedCount == 2, "library copy should copy JPG and CR3")
        #expect(result.failedCount == 0, "library copy failed: \(result.message)")

        let copiedJPG = targetRoot.appendingPathComponent("2026-08-12_EOS R/IMG_0001.JPG")
        let copiedCR3 = targetRoot.appendingPathComponent("2026-08-12_EOS R/IMG_0001.CR3")
        #expect(FileManager.default.fileExists(atPath: copiedJPG.path), "library JPG copy is missing")
        #expect(FileManager.default.fileExists(atPath: copiedCR3.path), "library CR3 copy is missing")
        #expect(targetCatalog.libraryAssetStatus(for: copiedJPG), "copied JPG was not registered in target catalog")
        #expect(targetCatalog.libraryAssetStatus(for: copiedCR3), "copied CR3 was not registered in target catalog")
        print("PASS: library-to-library JPG/CR3 copy and target catalog registration")
    }

    @Test("Labels and saved views stay local to the destination library")
    func labels() throws {
        #expect(LabelPalette.colors.count == 32, "the default label palette must contain 32 colors")
        #expect(Set(LabelPalette.colors).count == 32, "the default label palette colors must be unique")
        #expect(
            LabelPalette.colors.allSatisfy { $0.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil },
            "every default label color must use #RRGGBB"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-labels-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        let noLabelsRoot = root.appendingPathComponent("no-labels", isDirectory: true)
        let sourceFolder = sourceRoot.appendingPathComponent("2026-08-13_Canon EOS R", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: noLabelsRoot, withIntermediateDirectories: true)
        let jpeg = sourceFolder.appendingPathComponent("IMG_0100.JPG")
        let raw = sourceFolder.appendingPathComponent("IMG_0100.CR3")
        try Data("label-jpg".utf8).write(to: jpeg)
        try Data("label-raw".utf8).write(to: raw)
        let sourcePhotoID = UUID().uuidString
        var group = PhotoGroup(
            id: jpeg.deletingPathExtension().path, basename: "IMG_0100", directory: sourceFolder,
            jpegURL: jpeg, rawURL: raw, movieURL: nil, captureDate: Date(), metadata: .empty,
            importedJPEG: true, importedRAW: true, isMetadataLoaded: true, libraryAssetStatus: .registered,
            photoID: sourcePhotoID
        )
        let sourceCatalog = try CatalogStore(libraryRoot: sourceRoot)
        try sourceCatalog.recordLibraryAsset(url: jpeg, variant: .jpeg, sha256: hash(jpeg), fileSize: Int64(Data("label-jpg".utf8).count), preferredPhotoID: sourcePhotoID)
        try sourceCatalog.recordLibraryAsset(url: raw, variant: .raw, sha256: hash(raw), fileSize: Int64(Data("label-raw".utf8).count), preferredPhotoID: sourcePhotoID)
        let travel = try sourceCatalog.createLabel(name: "旅行", colorHex: "#0091FF")
        let existingSource = try sourceCatalog.createLabel(name: "家族", colorHex: "#E5484D")
        try sourceCatalog.setLabel(travel.id, on: [sourcePhotoID], assigned: true)
        try sourceCatalog.setLabel(existingSource.id, on: [sourcePhotoID], assigned: true)
        _ = try sourceCatalog.saveLabelView(name: "旅行と家族", labelIDs: [travel.id, existingSource.id])
        group.labels = [travel, existingSource]

        let destinationCatalog = try CatalogStore(libraryRoot: destinationRoot)
        let existingDestination = try destinationCatalog.createLabel(name: "家族", colorHex: "#46A758")
        let copied = try FileTransferService().copyLibraryGroup(
            group, from: sourceRoot, to: destinationRoot,
            sourceCatalog: sourceCatalog, destinationCatalog: destinationCatalog, copyLabels: true
        )
        #expect(copied.failedCount == 0, "label copy failed: \(copied.message)")
        let copiedJPG = destinationRoot.appendingPathComponent("2026-08-13_Canon EOS R/IMG_0100.JPG")
        let destinationPhotoID = try requireValue(destinationCatalog.photoID(for: copiedJPG), "destination photo UUID is missing")
        #expect(destinationPhotoID == sourcePhotoID, "a new library copy must preserve the photo UUID")
        let destinationSnapshot = destinationCatalog.labelSnapshot(for: [PhotoGroup(
            id: copiedJPG.deletingPathExtension().path, basename: "IMG_0100", directory: copiedJPG.deletingLastPathComponent(),
            jpegURL: copiedJPG, rawURL: destinationRoot.appendingPathComponent("2026-08-13_Canon EOS R/IMG_0100.CR3"), movieURL: nil,
            captureDate: nil, metadata: .empty, importedJPEG: true, importedRAW: true, isMetadataLoaded: true
        )])
        let destinationTravel = try requireValue(destinationSnapshot.labels.first(where: { $0.normalizedName == normalizedLabelName("旅行") }), "copied label is missing")
        #expect(destinationTravel.id != travel.id, "a source label UUID must never be written to the destination")
        let destinationFamily = try requireValue(destinationSnapshot.labels.first(where: { $0.normalizedName == normalizedLabelName("家族") }), "existing destination label is missing")
        #expect(destinationFamily.id == existingDestination.id, "the destination label UUID must be reused by normalized name")
        #expect(destinationFamily.colorHex == "#46A758", "the destination label color must be preserved")
        #expect(destinationSnapshot.savedViews.isEmpty, "saved label views must not be copied")

        let noLabelsCatalog = try CatalogStore(libraryRoot: noLabelsRoot)
        let noLabelsResult = try FileTransferService().copyLibraryGroup(
            group, from: sourceRoot, to: noLabelsRoot,
            sourceCatalog: sourceCatalog, destinationCatalog: noLabelsCatalog, copyLabels: false
        )
        #expect(noLabelsResult.failedCount == 0, "copy with labels disabled failed")
        let noLabelsJPG = noLabelsRoot.appendingPathComponent("2026-08-13_Canon EOS R/IMG_0100.JPG")
        let noLabelsSnapshot = noLabelsCatalog.labelSnapshot(for: [PhotoGroup(
            id: noLabelsJPG.deletingPathExtension().path, basename: "IMG_0100", directory: noLabelsJPG.deletingLastPathComponent(),
            jpegURL: noLabelsJPG, rawURL: nil, movieURL: nil, captureDate: nil, metadata: .empty,
            importedJPEG: true, importedRAW: false, isMetadataLoaded: true
        )])
        #expect(noLabelsSnapshot.labels.isEmpty, "label tables must remain unchanged when label copy is disabled")
        print("PASS: labels, saved views, destination-local label UUIDs, and label-copy boundary")
    }

    private func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        try #require(value, Comment(rawValue: message))
    }

    private func hash(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func findFile(named name: String, under root: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "PhotokichinTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot enumerate test directory"])
        }
        for case let url as URL in enumerator where url.lastPathComponent == name { return url }
        throw NSError(domain: "PhotokichinTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing \(name)"])
    }

    private func requireMatchingTimestamp(
        _ source: URL,
        _ destination: URL,
        attribute: FileAttributeKey,
        label: String
    ) throws {
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let destinationAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard let sourceDate = sourceAttributes[attribute] as? Date,
              let destinationDate = destinationAttributes[attribute] as? Date else {
            return
        }
        #expect(abs(sourceDate.timeIntervalSince(destinationDate)) < 1, "\(label) was not preserved")
    }
}
