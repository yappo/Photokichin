import Foundation
import CryptoKit
@testable import PhotokichinCore

@main
struct PhotokichinTestRunner {
    static func main() async throws {
        for module in PhotokichinTestModules.all {
            try await module.run()
        }
        guard ProcessInfo.processInfo.environment["PHOTOKICHIN_RUN_HARDWARE_TESTS"] == "1" else {
            print("SKIP: EOS hardware test not requested (set PHOTOKICHIN_RUN_HARDWARE_TESTS=1)")
            return
        }
        try runHardwareCameraTests()
    }

    /// Runs only when explicitly requested. Hardware availability is an
    /// external condition and must not change the result of deterministic
    /// tests or make an unconnected camera look like a passing test run.
    static func runHardwareCameraTests() throws {
        let card = URL(fileURLWithPath: "/Volumes/EOS_DIGITAL")
        guard FileManager.default.fileExists(atPath: card.path) else {
            throw NSError(
                domain: "PhotokichinTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "PHOTOKICHIN_RUN_HARDWARE_TESTS=1 was set, but /Volumes/EOS_DIGITAL is not mounted"]
            )
        }

        let groups = PhotoScanner.scan(root: card)
        if let expected = ProcessInfo.processInfo.environment["PHOTOKICHIN_EXPECTED_GROUPS"].flatMap(Int.init) {
            try require(groups.count == expected, "expected \(expected) groups, got \(groups.count)")
        } else {
            try require(!groups.isEmpty, "no EOS R groups were found")
        }
        try require(groups.contains { $0.jpegURL != nil && $0.rawURL != nil }, "no JPG＋CR3 pair was found")
        try require(groups.allSatisfy { !$0.id.contains("CANONMSC") }, "Canon CTG directory must be ignored")

        guard let first = groups.first,
              let jpeg = first.jpegURL,
              let raw = first.rawURL,
              let metadata = ImageIOReader.readMetadata(url: jpeg) else {
            throw NSError(domain: "PhotokichinTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "could not read the first EOS R group"])
        }
        try require(metadata.cameraModel?.contains("EOS R") == true, "unexpected camera model: \(metadata.cameraModel ?? "nil")")
        try require(metadata.captureDate != nil, "EXIF capture date is missing")
        try require(metadata.iso != nil, "ISO is missing")
        let transfer = FileTransferService.shared
        try require(transfer.urlsForAirDrop([first], mode: .jpegAndRaw).count == 2, "JPG＋CR3 AirDrop mode should send two files")
        try require(transfer.urlsForAirDrop([first], mode: .jpegOnly).count == 1, "JPG-only AirDrop mode should send one file")
        try require(transfer.urlsForAirDrop([first], mode: .rawOnly).count == 1, "CR3-only AirDrop mode should send one file")

        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let store = try CatalogStore(libraryRoot: temporaryRoot)
        // Exercise the COPYFILE_ALL cancellation callback path as well as the
        // ordinary import path. A bad callback pointer can crash inside
        // libcopyfile instead of returning an import error.
        let cancellation = ImportCancellationToken()
        let result = try transfer.importGroup(first, to: temporaryRoot, template: "{date}_{camera}", catalog: store, cancellation: cancellation)
        try require(result.copiedCount == 2, "expected two copied files, got \(result.copiedCount)")
        try require(result.failedCount == 0, "copy failed: \(result.message)")

        let copiedJPG = try findFile(named: jpeg.lastPathComponent, under: temporaryRoot)
        let copiedCR3 = try findFile(named: raw.lastPathComponent, under: temporaryRoot)
        try require(FileManager.default.fileExists(atPath: copiedJPG.path), "JPG was not copied")
        try require(FileManager.default.fileExists(atPath: copiedCR3.path), "CR3 was not copied")
        try requireMatchingTimestamp(jpeg, copiedJPG, attribute: .creationDate, label: "JPG creation date")
        try requireMatchingTimestamp(jpeg, copiedJPG, attribute: .modificationDate, label: "JPG modification date")
        try requireMatchingTimestamp(raw, copiedCR3, attribute: .creationDate, label: "CR3 creation date")
        try requireMatchingTimestamp(raw, copiedCR3, attribute: .modificationDate, label: "CR3 modification date")

        print("PASS: \(groups.count) EOS R groups, ImageIO metadata, CTG exclusion, verified timestamps, and verified JPG+CR3 import")
    }

    static func runImportStateTests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let none = makeGroup(root: root, jpeg: false, raw: false, importedJPEG: false, importedRAW: false)
        try require(none.cardImportState == .notApplicable, "a group without JPG/CR3 must be対象外")

        let pending = makeGroup(root: root, jpeg: true, raw: true, importedJPEG: false, importedRAW: false)
        try require(pending.cardImportState == .notImported, "an unimported JPG＋CR3 pair must be未取り込み")

        var possible = makeGroup(root: root, jpeg: true, raw: true, importedJPEG: false, importedRAW: false)
        possible.possibleImportedJPEG = true
        try require(possible.displayImportState == .possible, "a metadata-only camera match must be取り込み済みかもしれない")
        try require(
            possible.matches(importFilter: .possible, operationFilter: .all, selected: false, deleteCandidate: false),
            "the possible import filter must include metadata-only matches"
        )
        try require(
            !possible.matches(importFilter: .notImported, operationFilter: .all, selected: false, deleteCandidate: false),
            "a possible import must not be shown as未取り込み"
        )

        let rawOnlyImported = makeGroup(root: root, jpeg: true, raw: true, importedJPEG: false, importedRAW: true)
        try require(rawOnlyImported.cardImportState == .partial, "CR3 imported and JPG unimported must be一部")

        let jpegOnlyImported = makeGroup(root: root, jpeg: true, raw: true, importedJPEG: true, importedRAW: false)
        try require(jpegOnlyImported.cardImportState == .partial, "JPG imported and CR3 unimported must be一部")

        let complete = makeGroup(root: root, jpeg: true, raw: true, importedJPEG: true, importedRAW: true)
        try require(complete.cardImportState == .imported, "an imported JPG＋CR3 pair must be取り込み済み")
        try require(complete.matches(importFilter: .all, operationFilter: .all, selected: false, deleteCandidate: false), "すべての取り込み状態フィルター must include imported photos")

        let cr3Only = makeGroup(root: root, jpeg: false, raw: true, importedJPEG: false, importedRAW: true)
        try require(cr3Only.cardImportState == .imported, "a CR3-only imported group must be取り込み済み")

        try require(
            rawOnlyImported.matches(importFilter: .partial, operationFilter: .selected, selected: true, deleteCandidate: false),
            "the import and operation filters must be combined with AND"
        )
        try require(
            !rawOnlyImported.matches(importFilter: .notImported, operationFilter: .selected, selected: true, deleteCandidate: false),
            "a partial group must not match the未取り込み filter"
        )
        try require(
            !rawOnlyImported.matches(importFilter: .partial, operationFilter: .deleteCandidates, selected: true, deleteCandidate: false),
            "a selected group must not match the削除候補 filter"
        )

        let chronological = [
            makeGroup(root: root, jpeg: true, raw: true, importedJPEG: false, importedRAW: false),
            makeGroup(root: root, jpeg: true, raw: true, importedJPEG: true, importedRAW: true),
            makeGroup(root: root, jpeg: true, raw: true, importedJPEG: false, importedRAW: false)
        ]
        let clustered = PhotoImportCluster.preservingOrder(dateKey: "2026年08月13日", photos: chronological)
        try require(
            clustered.flatMap(\.photos).map(\.id) == chronological.map(\.id),
            "import-state headers must not reorder chronological photos"
        )

        var earlierPresentation = chronological[0]
        var laterPresentation = chronological[1]
        earlierPresentation.presentationOrder = 10
        laterPresentation.presentationOrder = 11
        earlierPresentation.captureDate = Date(timeIntervalSince1970: 2)
        laterPresentation.captureDate = Date(timeIntervalSince1970: 1)
        try require(
            [laterPresentation, earlierPresentation].sorted(by: PhotoGroup.presentationPrecedes).map(\.id)
                == [earlierPresentation.id, laterPresentation.id],
            "metadata publication must not move a photo from its initial presentation order"
        )
        try require(
            PhotoGridNavigation.previousSectionIndex(currentColumn: 2, previousCount: 800, columns: 5) == 797,
            "up across a date boundary must target the preceding section's final row"
        )
        try require(
            PhotoGridNavigation.previousSectionIndex(currentColumn: 4, previousCount: 802, columns: 5) == 801,
            "up across a date boundary must clamp an incomplete final row"
        )
        try require(
            PhotoGridNavigation.pageTargetIndex(current: 803, count: 804, itemOffset: -15) == 788,
            "page up from the library end must move one page, not jump to the beginning"
        )

        print("PASS: stable ordering, date-boundary navigation, page navigation, and filters")
    }

    static func runCameraModelTests() throws {
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
        try require(cameraMetadata?.lensModel == "RF24-70mm F2.8 L IS USM", "camera metadata parser must expose the lens")
        try require(cameraMetadata?.aperture != nil, "camera metadata parser must expose the aperture")
        try require(cameraMetadata?.shutterSpeed != nil, "camera metadata parser must expose the shutter speed")
        try require(cameraMetadata?.iso != nil, "camera metadata parser must expose ISO")

        let reference = CameraPhotoReference(
            cameraID: "camera-test",
            groupKey: "DCIM/100EOS_R/IMG_0001",
            assets: [
                CameraAssetReference(
                    identifier: "handle:1",
                    filename: "IMG_0001.JPG",
                    variant: .jpeg,
                    fileSize: 10,
                    captureDate: Date(timeIntervalSince1970: 0)
                ),
                CameraAssetReference(
                    identifier: "handle:2",
                    filename: "IMG_0001.CR3",
                    variant: .raw,
                    fileSize: 20,
                    captureDate: Date(timeIntervalSince1970: 0)
                )
            ]
        )
        let group = PhotoGroup(
            id: "camera:camera-test:DCIM/100EOS_R/IMG_0001",
            basename: "IMG_0001",
            directory: URL(fileURLWithPath: "/__photokichin_camera__"),
            jpegURL: nil,
            rawURL: nil,
            movieURL: nil,
            captureDate: Date(timeIntervalSince1970: 0),
            metadata: .empty,
            importedJPEG: false,
            importedRAW: false,
            isMetadataLoaded: true,
            cameraReference: reference
        )
        try require(group.isCameraBacked, "camera groups must retain a remote source reference")
        try require(group.variants == [.jpeg, .raw], "camera groups must expose their remote JPG/CR3 variants")
        try require(group.importableVariants == [.jpeg, .raw], "camera JPG/CR3 variants must be importable")
        try require(group.cardImportState == .notImported, "an unimported camera JPG+CR3 pair must be未取り込み")

        let jpegOnly = PhotoGroup(
            id: "camera:camera-test:DCIM/100EOS_R/IMG_0002",
            basename: "IMG_0002",
            directory: URL(fileURLWithPath: "/__photokichin_camera__"),
            jpegURL: nil,
            rawURL: nil,
            movieURL: nil,
            captureDate: Date(timeIntervalSince1970: 0),
            metadata: .empty,
            importedJPEG: false,
            importedRAW: false,
            isMetadataLoaded: true,
            cameraReference: CameraPhotoReference(
                cameraID: "camera-test",
                groupKey: "DCIM/100EOS_R/IMG_0002",
                assets: [CameraAssetReference(
                    identifier: "handle:3",
                    filename: "IMG_0002.JPG",
                    variant: .jpeg,
                    fileSize: 30,
                    captureDate: Date(timeIntervalSince1970: 0)
                )]
            )
        )
        try require(jpegOnly.variants == [.jpeg], "a camera JPG-only photo must not gain a synthetic CR3")
        try require(jpegOnly.importableVariants == [.jpeg], "a camera JPG-only photo must import only its JPG")

        let rawOnly = PhotoGroup(
            id: "camera:camera-test:DCIM/100EOS_R/IMG_0003",
            basename: "IMG_0003",
            directory: URL(fileURLWithPath: "/__photokichin_camera__"),
            jpegURL: nil,
            rawURL: nil,
            movieURL: nil,
            captureDate: Date(timeIntervalSince1970: 0),
            metadata: .empty,
            importedJPEG: false,
            importedRAW: false,
            isMetadataLoaded: true,
            cameraReference: CameraPhotoReference(
                cameraID: "camera-test",
                groupKey: "DCIM/100EOS_R/IMG_0003",
                assets: [CameraAssetReference(
                    identifier: "handle:4",
                    filename: "IMG_0003.CR3",
                    variant: .raw,
                    fileSize: 40,
                    captureDate: Date(timeIntervalSince1970: 0)
                )]
            )
        )
        try require(rawOnly.variants == [.raw], "a camera RAW-only photo must not gain a synthetic JPG")
        try require(rawOnly.importableVariants == [.raw], "a camera RAW-only photo must import only its CR3")
    }

    static func runLibraryAirDropTests() throws {
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
        let transfer = FileTransferService.shared
        let both = transfer.urlsForAirDrop([group], mode: .jpegAndRaw)
        let expectedPaths = Set([jpegURL, rawURL].map(\.standardizedFileURL.path))
        try require(Set(both.map(\.standardizedFileURL.path)) == expectedPaths, "library JPG＋CR3 AirDrop must use the library file URLs")
        try require(transfer.urlsForAirDrop([group], mode: .jpegOnly).map(\.standardizedFileURL.path) == [jpegURL.standardizedFileURL.path], "library JPG-only AirDrop must use the library JPG URL")
        try require(transfer.urlsForAirDrop([group], mode: .rawOnly).map(\.standardizedFileURL.path) == [rawURL.standardizedFileURL.path], "library CR3-only AirDrop must use the library CR3 URL")
        try require(both.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) }, "library AirDrop URLs must be readable files")
    }

    static func makeGroup(
        root: URL,
        jpeg: Bool,
        raw: Bool,
        importedJPEG: Bool,
        importedRAW: Bool,
        possibleImportedJPEG: Bool = false,
        possibleImportedRAW: Bool = false
    ) -> PhotoGroup {
        PhotoGroup(
            id: UUID().uuidString,
            basename: "IMG_0001",
            directory: root,
            jpegURL: jpeg ? root.appendingPathComponent("IMG_0001.JPG") : nil,
            rawURL: raw ? root.appendingPathComponent("IMG_0001.CR3") : nil,
            movieURL: nil,
            captureDate: Date(timeIntervalSince1970: 0),
            metadata: .empty,
            importedJPEG: importedJPEG,
            importedRAW: importedRAW,
            isMetadataLoaded: true,
            possibleImportedJPEG: possibleImportedJPEG,
            possibleImportedRAW: possibleImportedRAW
        )
    }

    static func runCatalogTests() throws {
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
        try require(inspection.summary.unregisteredPhotoCount == 1, "unregistered library file was not detected")

        let candidate = movedFolder.appendingPathComponent("IMG_0001.JPG")
        try FileManager.default.moveItem(at: destination, to: candidate)
        inspection = try store.inspectLibrary()
        guard let issue = inspection.issues.first(where: { $0.sourceKey == sourceKey && $0.issueType == "candidate" }) else {
            throw NSError(domain: "PhotokichinTests", code: 21, userInfo: [NSLocalizedDescriptionKey: "moved file candidate was not detected"])
        }
        try store.relink(issueID: issue.id, to: candidate)
        try require(store.importedDestination(sourceKey: sourceKey, variant: .jpeg)?.standardizedFileURL == candidate.standardizedFileURL, "relink did not update destination")

        let backup = root.deletingLastPathComponent().appendingPathComponent("Photokichin-catalog-backup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: backup) }
        try store.backup(to: backup)
        try require(FileManager.default.fileExists(atPath: backup.path), "catalog backup was not created")
        try require(store.integrityReport() == "ok", "catalog integrity check failed")

        print("PASS: catalog migration, unregistered detection, candidate relink, backup, and integrity check")
    }

    static func runFilenameIdentityTests() throws {
        try require(FilenameIdentity.key(for: "IMG_0001.JPG") == "img_0001.jpg", "filename key should be case-insensitive while retaining the extension")
        try require(FilenameIdentity.key(for: "フォルダ/写真.JPG") == "写真.jpg", "filename key should use only the basename")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-filename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let imported = root.appendingPathComponent("imported/IMG_0001.JPG")
        let library = root.appendingPathComponent("library/IMG_0001.JPG")
        try FileManager.default.createDirectory(at: imported.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = Data("same-camera-content".utf8)
        try contents.write(to: imported)
        try contents.write(to: library)

        let store = try CatalogStore(libraryRoot: root)
        let digest = try hash(imported)
        try store.recordImport(
            sourceKey: "camera:test:IMG_0001:JPG",
            variant: .jpeg,
            destinationURL: imported,
            sha256: digest,
            sourceFilename: "IMG_0001.JPG"
        )
        try store.recordLibraryAsset(
            url: library,
            variant: .jpeg,
            sha256: digest,
            fileSize: Int64(contents.count)
        )

        let candidates = store.matchCandidates(sourceFilenameKey: "img_0001.jpg", fileSize: Int64(contents.count), variant: .jpeg)
        try require(candidates.count == 2, "metadata-only candidate lookup should include imported and library records")
        try require(candidates.allSatisfy { $0.filenameKey == "img_0001.jpg" }, "candidate lookup should retain normalized filename keys")
        try require(
            store.matchCandidates(sourceFilenameKey: "other.jpg", fileSize: Int64(contents.count), variant: .jpeg).isEmpty,
            "candidate lookup must use the normalized filename key as well as size and variant"
        )
        try require(
            store.existingContentDestination(sha256: digest, variant: .jpeg, fileSize: Int64(contents.count)) != nil,
            "a verified camera hash should find an existing library destination"
        )
        try require(
            store.existingContentDestination(sha256: digest, variant: .raw, fileSize: Int64(contents.count)) == nil,
            "a matching hash with another variant must not be reused"
        )
        let partial = root.appendingPathComponent("camera/.photokichin-partial-test")
        let cameraDestination = root.appendingPathComponent("camera/IMG_0001.JPG")
        try FileManager.default.createDirectory(at: cameraDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: partial)
        let installed = try FileTransferService.shared.installCameraDownloadedFile(
            partialURL: partial,
            destinationURL: cameraDestination,
            variant: .jpeg,
            sourceKey: "camera:test:IMG_0001:JPG",
            sourceFilename: "IMG_0001.JPG",
            catalog: store,
            expectedFileSize: Int64(contents.count),
            cancellation: nil
        )
        try require(!installed, "camera import should reuse the verified existing file")
        try require(!FileManager.default.fileExists(atPath: cameraDestination.path), "camera reuse must not create a duplicate destination file")
        print("PASS: source filename keys, metadata-only candidates, and verified cross-source reuse")
    }

    static func runSourceIdentityTests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-source-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceRoot = URL(fileURLWithPath: "/Volumes/EOS_DIGITAL")
        let sourceURL = sourceRoot.appendingPathComponent("DCIM/101EOS_R/IMG_0001.JPG")
        let destination = root.appendingPathComponent("IMG_0001.JPG")
        try Data("source-identity-test".utf8).write(to: destination)
        let store = try CatalogStore(libraryRoot: root)
        let legacyKey = SourceIdentity.legacyKey(url: sourceURL, variant: .jpeg)
        try store.recordImport(sourceKey: legacyKey, variant: .jpeg, destinationURL: destination, sha256: hash(destination))

        let result = try store.migrateAllLegacySourceIdentities(
            sourceRoot: sourceRoot,
            volumeUUID: "919108f7-52d1-4320-9bac-f847db4148a8"
        )
        try require(result.migratedCount == 1, "legacy source identity was not migrated")
        let newKey = SourceIdentity.key(
            url: sourceURL,
            variant: .jpeg,
            sourceRoot: sourceRoot,
            volumeUUID: "919108f7-52d1-4320-9bac-f847db4148a8"
        )
        try require(newKey == "volume:919108f7-52d1-4320-9bac-f847db4148a8:DCIM/101EOS_R/IMG_0001:JPG", "unexpected source identity key: \(newKey)")
        try require(store.isImported(sourceKey: newKey, variant: .jpeg), "migrated source identity is not readable")

        print("PASS: Volume UUID source identity and legacy catalog migration")
    }

    static func runLibraryCopyTests() throws {
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
        let result = try FileTransferService.shared.copyLibraryGroup(
            group,
            from: sourceRoot,
            to: targetRoot,
            sourceCatalog: sourceCatalog,
            destinationCatalog: targetCatalog
        )
        try require(result.copiedCount == 2, "library copy should copy JPG and CR3")
        try require(result.failedCount == 0, "library copy failed: \(result.message)")

        let copiedJPG = targetRoot.appendingPathComponent("2026-08-12_EOS R/IMG_0001.JPG")
        let copiedCR3 = targetRoot.appendingPathComponent("2026-08-12_EOS R/IMG_0001.CR3")
        try require(FileManager.default.fileExists(atPath: copiedJPG.path), "library JPG copy is missing")
        try require(FileManager.default.fileExists(atPath: copiedCR3.path), "library CR3 copy is missing")
        try require(targetCatalog.libraryAssetStatus(for: copiedJPG), "copied JPG was not registered in target catalog")
        try require(targetCatalog.libraryAssetStatus(for: copiedCR3), "copied CR3 was not registered in target catalog")
        print("PASS: library-to-library JPG/CR3 copy and target catalog registration")
    }

    static func runLabelTests() throws {
        try require(LabelPalette.colors.count == 32, "the default label palette must contain 32 colors")
        try require(Set(LabelPalette.colors).count == 32, "the default label palette colors must be unique")
        try require(
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
        let copied = try FileTransferService.shared.copyLibraryGroup(
            group, from: sourceRoot, to: destinationRoot,
            sourceCatalog: sourceCatalog, destinationCatalog: destinationCatalog, copyLabels: true
        )
        try require(copied.failedCount == 0, "label copy failed: \(copied.message)")
        let copiedJPG = destinationRoot.appendingPathComponent("2026-08-13_Canon EOS R/IMG_0100.JPG")
        let destinationPhotoID = try requireValue(destinationCatalog.photoID(for: copiedJPG), "destination photo UUID is missing")
        try require(destinationPhotoID == sourcePhotoID, "a new library copy must preserve the photo UUID")
        let destinationSnapshot = destinationCatalog.labelSnapshot(for: [PhotoGroup(
            id: copiedJPG.deletingPathExtension().path, basename: "IMG_0100", directory: copiedJPG.deletingLastPathComponent(),
            jpegURL: copiedJPG, rawURL: destinationRoot.appendingPathComponent("2026-08-13_Canon EOS R/IMG_0100.CR3"), movieURL: nil,
            captureDate: nil, metadata: .empty, importedJPEG: true, importedRAW: true, isMetadataLoaded: true
        )])
        let destinationTravel = try requireValue(destinationSnapshot.labels.first(where: { $0.normalizedName == normalizedLabelName("旅行") }), "copied label is missing")
        try require(destinationTravel.id != travel.id, "a source label UUID must never be written to the destination")
        let destinationFamily = try requireValue(destinationSnapshot.labels.first(where: { $0.normalizedName == normalizedLabelName("家族") }), "existing destination label is missing")
        try require(destinationFamily.id == existingDestination.id, "the destination label UUID must be reused by normalized name")
        try require(destinationFamily.colorHex == "#46A758", "the destination label color must be preserved")
        try require(destinationSnapshot.savedViews.isEmpty, "saved label views must not be copied")

        let noLabelsCatalog = try CatalogStore(libraryRoot: noLabelsRoot)
        let noLabelsResult = try FileTransferService.shared.copyLibraryGroup(
            group, from: sourceRoot, to: noLabelsRoot,
            sourceCatalog: sourceCatalog, destinationCatalog: noLabelsCatalog, copyLabels: false
        )
        try require(noLabelsResult.failedCount == 0, "copy with labels disabled failed")
        let noLabelsJPG = noLabelsRoot.appendingPathComponent("2026-08-13_Canon EOS R/IMG_0100.JPG")
        let noLabelsSnapshot = noLabelsCatalog.labelSnapshot(for: [PhotoGroup(
            id: noLabelsJPG.deletingPathExtension().path, basename: "IMG_0100", directory: noLabelsJPG.deletingLastPathComponent(),
            jpegURL: noLabelsJPG, rawURL: nil, movieURL: nil, captureDate: nil, metadata: .empty,
            importedJPEG: true, importedRAW: false, isMetadataLoaded: true
        )])
        try require(noLabelsSnapshot.labels.isEmpty, "label tables must remain unchanged when label copy is disabled")
        print("PASS: labels, saved views, destination-local label UUIDs, and label-copy boundary")
    }

    static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: "PhotokichinTests", code: 40, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }

    static func hash(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func findFile(named name: String, under root: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "PhotokichinTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot enumerate test directory"])
        }
        for case let url as URL in enumerator where url.lastPathComponent == name { return url }
        throw NSError(domain: "PhotokichinTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing \(name)"])
    }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "PhotokichinTests", code: 10, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func requireMatchingTimestamp(
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
        try require(abs(sourceDate.timeIntervalSince(destinationDate)) < 1, "\(label) was not preserved")
    }
}
