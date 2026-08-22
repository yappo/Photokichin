import CryptoKit
import Foundation
@testable import PhotokichinCore

extension PhotokichinTestRunner {
    /// Exercises CatalogStore's state boundaries through its public API.
    ///
    /// These tests deliberately use temporary libraries and ordinary files.
    /// They do not inspect SQLite tables or private CatalogStore state, so a
    /// catalog refactor must preserve the same observable results.
    static func runCatalogBoundaryTests() throws {
        try runRecordImportBoundaryTests()
        try runInspectionBoundaryTests()
        try runRelinkAndForgetBoundaryTests()
        try runSourceIdentityMigrationBoundaryTests()
        try runBackupFailureBoundaryTests()
        print("PASS: catalog duplicate, rollback, inspection, relink, forget, migration, and backup boundaries")
    }

    private static func runRecordImportBoundaryTests() throws {
        let root = temporaryRoot(named: "catalog-record-boundaries")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CatalogStore(libraryRoot: root)

        let first = root.appendingPathComponent("first/IMG_0001.JPG")
        let second = root.appendingPathComponent("second/IMG_0001.JPG")
        try write(Data("first-content".utf8), to: first)
        try write(Data("second-content".utf8), to: second)
        let sourceKey = "volume:camera-boundary:DCIM/100EOS_R/IMG_0001:JPG"

        try store.recordImport(
            sourceKey: sourceKey,
            variant: .jpeg,
            destinationURL: first,
            sha256: boundaryHash(first),
            sourceFilename: "IMG_0001.JPG"
        )
        try store.recordImport(
            sourceKey: sourceKey,
            variant: .jpeg,
            destinationURL: second,
            sha256: boundaryHash(second),
            sourceFilename: "IMG_0001.JPG"
        )
        try require(store.summary().importedFileCount == 1, "re-registering one source and variant must not create a duplicate")
        try require(
            store.importedDestination(sourceKey: sourceKey, variant: .jpeg)?.standardizedFileURL == second.standardizedFileURL,
            "re-registering one source and variant must update its destination"
        )
        try require(store.isImported(sourceKey: sourceKey, variant: .jpeg), "updated import must remain imported")

        let rollbackRoot = root.appendingPathComponent("rollback")
        try FileManager.default.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
        let valid = rollbackRoot.appendingPathComponent("IMG_VALID.JPG")
        try write(Data("valid-record".utf8), to: valid)
        let outside = root.deletingLastPathComponent().appendingPathComponent("Photokichin-outside-\(UUID().uuidString).JPG")
        defer { try? FileManager.default.removeItem(at: outside) }

        let before = store.summary().importedFileCount
        do {
            try store.recordImports([
                CatalogImportRecord(
                    sourceKey: "volume:camera-boundary:DCIM/100EOS_R/IMG_VALID:JPG",
                    variant: .jpeg,
                    destinationURL: valid,
                    sha256: boundaryHash(valid),
                    fileSize: Int64(Data("valid-record".utf8).count)
                ),
                // This URL is outside the library. CatalogStore must reject it
                // after the first row has been prepared and roll back both.
                CatalogImportRecord(
                    sourceKey: "volume:camera-boundary:DCIM/100EOS_R/IMG_INVALID:JPG",
                    variant: .jpeg,
                    destinationURL: outside,
                    sha256: String(repeating: "0", count: 64),
                    fileSize: 1
                )
            ])
            try require(false, "recordImports must fail when a row is outside the library")
        } catch {
            // Expected failure. The observable assertions below verify the
            // transaction was rolled back rather than partially committed.
        }
        try require(store.summary().importedFileCount == before, "recordImports must roll back every row after a later row fails")
        try require(
            store.importedDestination(sourceKey: "volume:camera-boundary:DCIM/100EOS_R/IMG_VALID:JPG", variant: .jpeg) == nil,
            "a record before a failed recordImports row must not remain"
        )
        try require(
            store.importedDestination(sourceKey: "volume:camera-boundary:DCIM/100EOS_R/IMG_INVALID:JPG", variant: .jpeg) == nil,
            "a failed recordImports row must not be registered"
        )
    }

    private static func runInspectionBoundaryTests() throws {
        let root = temporaryRoot(named: "catalog-inspection-boundaries")
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = root.appendingPathComponent("imported", isDirectory: true)
        let recovered = root.appendingPathComponent("recovered", isDirectory: true)
        let extra = root.appendingPathComponent("extra", isDirectory: true)
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        let store = try CatalogStore(libraryRoot: root)

        let missing = imported.appendingPathComponent("IMG_MISSING.JPG")
        let missingData = Data("missing-data".utf8)
        let missingKey = "volume:inspection:DCIM/100EOS_R/IMG_MISSING:JPG"
        try record(store, sourceKey: missingKey, destination: missing, data: missingData)
        try FileManager.default.removeItem(at: missing)

        let candidate = imported.appendingPathComponent("IMG_CANDIDATE.JPG")
        let candidateFile = recovered.appendingPathComponent("IMG_CANDIDATE.JPG")
        let candidateData = Data("candidate-data".utf8)
        let candidateKey = "volume:inspection:DCIM/100EOS_R/IMG_CANDIDATE:JPG"
        try record(store, sourceKey: candidateKey, destination: candidate, data: candidateData)
        try FileManager.default.removeItem(at: candidate)
        try write(candidateData, to: candidateFile)

        let conflict = imported.appendingPathComponent("IMG_CONFLICT.JPG")
        let originalConflictData = Data("original-conflict-content".utf8)
        let changedConflictData = Data("changed".utf8)
        let conflictKey = "volume:inspection:DCIM/100EOS_R/IMG_CONFLICT:JPG"
        try write(originalConflictData, to: conflict)
        try record(store, sourceKey: conflictKey, destination: conflict, data: originalConflictData)
        // The same known path now contains different bytes and a different
        // size, which is the catalog's explicit conflict condition.
        try write(changedConflictData, to: conflict)

        let unregistered = extra.appendingPathComponent("IMG_UNREGISTERED.JPG")
        try write(Data("unregistered-data".utf8), to: unregistered)

        let inspection = try store.inspectLibrary()
        let issues = inspection.issues
        try require(inspection.summary.unregisteredPhotoCount == 2, "inspectLibrary must report the recovered candidate and the unregistered photo")
        try require(
            issues.contains { $0.sourceKey == missingKey && $0.issueType == "missing" && $0.candidateURL == nil },
            "inspectLibrary must report a known file with no candidate as missing"
        )
        try require(
            issues.contains {
                $0.sourceKey == candidateKey &&
                $0.issueType == "candidate" &&
                $0.candidateURL?.standardizedFileURL == candidateFile.standardizedFileURL
            },
            "inspectLibrary must report a same-name, same-content candidate"
        )
        try require(
            issues.contains { $0.sourceKey == conflictKey && $0.issueType == "conflict" && $0.candidateURL == nil },
            "inspectLibrary must report a same-name file with different content as a conflict"
        )
    }

    private static func runRelinkAndForgetBoundaryTests() throws {
        let root = temporaryRoot(named: "catalog-relink-boundaries")
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = root.appendingPathComponent("imported", isDirectory: true)
        let recovered = root.appendingPathComponent("recovered", isDirectory: true)
        let wrong = root.appendingPathComponent("wrong", isDirectory: true)
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
        let store = try CatalogStore(libraryRoot: root)

        let relinkPath = imported.appendingPathComponent("IMG_RELINK.JPG")
        let relinkKey = "volume:relink:DCIM/100EOS_R/IMG_RELINK:JPG"
        let expected = Data("the-correct-candidate".utf8)
        try record(store, sourceKey: relinkKey, destination: relinkPath, data: expected)
        try FileManager.default.removeItem(at: relinkPath)
        let correctCandidate = recovered.appendingPathComponent("IMG_RELINK.JPG")
        let wrongCandidate = wrong.appendingPathComponent("IMG_RELINK.JPG")
        try write(expected, to: correctCandidate)
        try write(Data("a-wrong-candidate!!".utf8), to: wrongCandidate)

        let forgetPath = imported.appendingPathComponent("IMG_FORGET.JPG")
        let forgetKey = "volume:relink:DCIM/100EOS_R/IMG_FORGET:JPG"
        try record(store, sourceKey: forgetKey, destination: forgetPath, data: Data("forget-me".utf8))
        try FileManager.default.removeItem(at: forgetPath)
        let inspection = try store.inspectLibrary()
        guard let relinkIssue = inspection.issues.first(where: { $0.sourceKey == relinkKey }),
              let forgetIssue = inspection.issues.first(where: { $0.sourceKey == forgetKey }) else {
            throw NSError(domain: "PhotokichinTests", code: 61, userInfo: [NSLocalizedDescriptionKey: "relink and forget issues were not created"])
        }
        try require(relinkIssue.issueType == "candidate", "the correct same-name candidate must be offered for relink")

        do {
            try store.relink(issueID: relinkIssue.id, to: wrongCandidate)
            try require(false, "relink must reject a candidate with the wrong SHA-256")
        } catch {
            // Expected failure. The issue and destination remain unchanged.
        }
        try require(
            store.issues().contains { $0.id == relinkIssue.id },
            "a rejected relink candidate must leave the issue open"
        )
        try require(
            store.importedDestination(sourceKey: relinkKey, variant: .jpeg)?.standardizedFileURL == relinkPath.standardizedFileURL,
            "a rejected relink candidate must not change the recorded destination"
        )

        try store.relink(issueID: relinkIssue.id, to: correctCandidate)
        try require(
            store.importedDestination(sourceKey: relinkKey, variant: .jpeg)?.standardizedFileURL == correctCandidate.standardizedFileURL,
            "relink must accept the candidate whose SHA-256 matches the record"
        )
        try require(!store.issues().contains { $0.id == relinkIssue.id }, "a successful relink must resolve its issue")

        try store.forget(issueID: forgetIssue.id)
        try require(!store.issues().contains { $0.id == forgetIssue.id }, "forget must remove the issue")
        try require(store.importedDestination(sourceKey: forgetKey, variant: .jpeg) == nil, "forget must remove the imported record")
        try require(!store.isImported(sourceKey: forgetKey, variant: .jpeg), "a forgotten record must not remain imported")
    }

    private static func runSourceIdentityMigrationBoundaryTests() throws {
        let root = temporaryRoot(named: "catalog-source-migration-boundaries")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceRoot = URL(fileURLWithPath: "/Volumes/EOS_DIGITAL")
        let volumeUUID = "ABCDEF01-2345-6789-ABCD-EF0123456789"
        let successSource = sourceRoot.appendingPathComponent("DCIM/100EOS_R/IMG_SUCCESS.JPG")
        let conflictSource = sourceRoot.appendingPathComponent("DCIM/100EOS_R/IMG_CONFLICT.JPG")
        let otherCardSource = sourceRoot.appendingPathComponent("DCIM/100EOS_R/IMG_OTHER_CARD.JPG")
        let successLegacy = SourceIdentity.legacyKey(url: successSource, variant: .jpeg)
        let conflictLegacy = SourceIdentity.legacyKey(url: conflictSource, variant: .jpeg)
        let otherCardLegacy = SourceIdentity.legacyKey(url: otherCardSource, variant: .jpeg)
        let successNew = SourceIdentity.key(url: successSource, variant: .jpeg, sourceRoot: sourceRoot, volumeUUID: volumeUUID)
        let conflictNew = SourceIdentity.key(url: conflictSource, variant: .jpeg, sourceRoot: sourceRoot, volumeUUID: volumeUUID)

        let store = try CatalogStore(libraryRoot: root)
        let successDestination = root.appendingPathComponent("success/IMG_SUCCESS.JPG")
        let conflictLegacyDestination = root.appendingPathComponent("conflict-legacy/IMG_CONFLICT.JPG")
        let conflictNewDestination = root.appendingPathComponent("conflict-new/IMG_CONFLICT.JPG")
        let otherDestination = root.appendingPathComponent("other/IMG_OTHER_CARD.JPG")
        try write(Data("success".utf8), to: successDestination)
        try write(Data("conflict-legacy".utf8), to: conflictLegacyDestination)
        try write(Data("conflict-new".utf8), to: conflictNewDestination)
        try write(Data("other-card".utf8), to: otherDestination)
        try record(store, sourceKey: successLegacy, destination: successDestination, data: Data("success".utf8))
        try record(store, sourceKey: conflictLegacy, destination: conflictLegacyDestination, data: Data("conflict-legacy".utf8))
        try record(store, sourceKey: conflictNew, destination: conflictNewDestination, data: Data("conflict-new".utf8))
        try record(store, sourceKey: otherCardLegacy, destination: otherDestination, data: Data("other-card".utf8))

        let successGroup = migrationGroup(url: successSource)
        let conflictGroup = migrationGroup(url: conflictSource)
        let result = try store.migrateSourceIdentities(
            groups: [successGroup, conflictGroup],
            sourceRoot: sourceRoot,
            volumeUUID: volumeUUID
        )
        try require(result.migratedCount == 1, "source identity migration must migrate only the non-conflicting scanned row")
        try require(result.conflictCount == 1, "source identity migration must report a target-key conflict")
        guard let backupURL = result.backupURL else {
            throw NSError(domain: "PhotokichinTests", code: 62, userInfo: [NSLocalizedDescriptionKey: "source identity migration did not return a backup URL"])
        }
        try require(FileManager.default.fileExists(atPath: backupURL.path), "source identity migration must create a pre-migration backup")

        try require(store.isImported(sourceKey: successNew, variant: .jpeg), "the scanned legacy row must be readable by its new source identity")
        try require(!store.isImported(sourceKey: successLegacy, variant: .jpeg), "the migrated row must no longer be readable by its legacy source identity")
        try require(store.isImported(sourceKey: conflictLegacy, variant: .jpeg), "a conflicting legacy row must remain unchanged")
        try require(store.isImported(sourceKey: otherCardLegacy, variant: .jpeg), "a legacy row absent from the current scan must remain unchanged")
        try require(!store.isImported(sourceKey: SourceIdentity.key(url: otherCardSource, variant: .jpeg, sourceRoot: sourceRoot, volumeUUID: volumeUUID), variant: .jpeg), "migration must not guess another card's row from its filename")

        // Open the returned backup through CatalogStore's public API after
        // copying it into the normal catalog location. It must still contain
        // the legacy key, proving the backup preceded the migration.
        let backupRoot = root.appendingPathComponent("backup-copy")
        let backupCatalogDirectory = backupRoot.appendingPathComponent(".photokichin", isDirectory: true)
        try FileManager.default.createDirectory(at: backupCatalogDirectory, withIntermediateDirectories: true)
        let backupCatalog = backupCatalogDirectory.appendingPathComponent("catalog.sqlite")
        try FileManager.default.copyItem(at: backupURL, to: backupCatalog)
        let backupStore = try CatalogStore(libraryRoot: backupRoot)
        try require(backupStore.isImported(sourceKey: successLegacy, variant: .jpeg), "the pre-migration backup must contain the legacy row")
        try require(!backupStore.isImported(sourceKey: successNew, variant: .jpeg), "the pre-migration backup must not contain the new source identity")
    }

    private static func runBackupFailureBoundaryTests() throws {
        let root = temporaryRoot(named: "catalog-backup-failure-boundaries")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CatalogStore(libraryRoot: root)
        let missingParent = root.appendingPathComponent("does-not-exist/subdirectory/catalog.sqlite")
        do {
            try store.backup(to: missingParent)
            try require(false, "backup must fail when its destination parent does not exist")
        } catch {
            // Expected deterministic failure.
        }
        try require(!FileManager.default.fileExists(atPath: missingParent.path), "a failed backup must not leave a catalog file")
        try require(store.integrityReport() == "ok", "a failed backup must not damage the source catalog")
    }

    private static func record(_ store: CatalogStore, sourceKey: String, destination: URL, data: Data) throws {
        try write(data, to: destination)
        try store.recordImport(
            sourceKey: sourceKey,
            variant: .jpeg,
            destinationURL: destination,
            sha256: boundaryHash(destination),
            sourceFilename: destination.lastPathComponent
        )
    }

    private static func migrationGroup(url: URL) -> PhotoGroup {
        PhotoGroup(
            id: url.deletingPathExtension().path,
            basename: url.deletingPathExtension().lastPathComponent,
            directory: url.deletingLastPathComponent(),
            jpegURL: url,
            rawURL: nil,
            movieURL: nil,
            captureDate: nil,
            metadata: .empty,
            importedJPEG: false,
            importedRAW: false,
            isMetadataLoaded: false
        )
    }

    private static func temporaryRoot(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static func boundaryHash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
