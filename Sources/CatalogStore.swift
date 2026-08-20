import CryptoKit
import Foundation
import SQLite3

struct CatalogImportRecord: Sendable {
    let sourceKey: String
    let variant: AssetVariant
    let destinationURL: URL
    let sha256: String
    let fileSize: Int64
    let sourceFilename: String?
    let sourceFilenameKey: String?
    let legacySourceKey: String?
    let sourceVolumeUUID: String?
    let sourceRelativePath: String?
    let photoID: String?

    init(
        sourceKey: String,
        variant: AssetVariant,
        destinationURL: URL,
        sha256: String,
        fileSize: Int64,
        sourceFilename: String? = nil,
        sourceFilenameKey: String? = nil,
        legacySourceKey: String? = nil,
        sourceVolumeUUID: String? = nil,
        sourceRelativePath: String? = nil,
        photoID: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.variant = variant
        self.destinationURL = destinationURL
        self.sha256 = sha256
        self.fileSize = fileSize
        self.sourceFilename = sourceFilename
        self.sourceFilenameKey = sourceFilenameKey ?? FilenameIdentity.key(for: sourceFilename)
        self.legacySourceKey = legacySourceKey
        self.sourceVolumeUUID = sourceVolumeUUID
        self.sourceRelativePath = sourceRelativePath
        self.photoID = photoID
    }
}

struct SourceIdentityMigrationResult: Sendable, Equatable {
    let migratedCount: Int
    let conflictCount: Int
    let backupURL: URL?
}

struct CatalogIssue: Identifiable, Hashable, Sendable {
    let id: Int64
    let sourceKey: String
    let variant: AssetVariant
    let issueType: String
    let lastKnownURL: URL
    let candidateURL: URL?
    let expectedSize: Int64
    let expectedSHA256: String
    let detectedAt: Date
}

struct CatalogSummary: Equatable, Sendable {
    let catalogURL: URL
    let catalogSize: Int64
    let lastInspectionAt: Date?
    let importedFileCount: Int
    let registeredAssetCount: Int
    let unregisteredPhotoCount: Int
    let missingCount: Int
    let candidateCount: Int
    let conflictCount: Int
}

struct CatalogInspectionResult: Sendable {
    let summary: CatalogSummary
    let issues: [CatalogIssue]
}

struct CatalogContentRecord: Sendable {
    let sha256: String
    let fileSize: Int64
}

struct CatalogMatchCandidate: Sendable, Equatable {
    let path: URL
    let variant: AssetVariant
    let fileSize: Int64
    let sha256: String
    let filenameKey: String?
}

final class CatalogStore: @unchecked Sendable {
    private struct ImportedRow {
        let sourceKey: String
        let variant: AssetVariant
        let sourceVolumeUUID: String?
        let sourceRelativePath: String?
        let destinationURL: URL
        let sha256: String
        let fileSize: Int64
    }

    private struct LibraryAssetRow {
        let assetKey: String
        let variant: AssetVariant
        let path: URL
        let sha256: String
        let fileSize: Int64
        let filenameKey: String
    }

    let catalogURL: URL
    let catalogDirectoryURL: URL
    private let libraryRoot: URL
    private var database: OpaquePointer?
    private let lock = NSLock()

    init(libraryRoot: URL) throws {
        self.libraryRoot = libraryRoot.standardizedFileURL
        let directory = self.libraryRoot.appendingPathComponent(".photokichin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        catalogDirectoryURL = directory
        catalogURL = directory.appendingPathComponent("catalog.sqlite")
        let catalogAlreadyExists = FileManager.default.fileExists(atPath: catalogURL.path)

        do {
            try open()
            if catalogAlreadyExists {
                try validateCurrentSchema()
            } else {
                try createSchema()
            }
        } catch AppError.catalogMigrationRequired {
            closeDatabase()
            throw AppError.catalogMigrationRequired(catalogURL)
        } catch {
            closeDatabase()
            let backupURL = catalogURL.deletingLastPathComponent()
                .appendingPathComponent("catalog.corrupt-\(Int(Date().timeIntervalSince1970)).sqlite")
            if FileManager.default.fileExists(atPath: catalogURL.path) {
                try? FileManager.default.moveItem(at: catalogURL, to: backupURL)
            }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: catalogURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: catalogURL.path + "-shm"))
            try open()
            try createSchema()
        }
    }

    deinit { closeDatabase() }

    func isImported(sourceKey: String, variant: AssetVariant, legacySourceKey: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let sql: String
        if legacySourceKey == nil || legacySourceKey == sourceKey {
            sql = "SELECT destination_path, sha256, file_state FROM imported_files WHERE source_key = ? AND variant = ? LIMIT 1;"
        } else {
            sql = "SELECT destination_path, sha256, file_state FROM imported_files WHERE variant = ? AND source_key IN (?, ?) LIMIT 1;"
        }
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        if legacySourceKey == nil || legacySourceKey == sourceKey {
            bind(sourceKey, to: statement, at: 1)
            bind(variant.rawValue, to: statement, at: 2)
        } else {
            bind(variant.rawValue, to: statement, at: 1)
            bind(sourceKey, to: statement, at: 2)
            bind(legacySourceKey!, to: statement, at: 3)
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let path = text(statement, column: 0),
              let sha = text(statement, column: 1),
              let state = text(statement, column: 2),
              !sha.isEmpty,
              ["present", "moved"].contains(state) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    func importedDestination(sourceKey: String, variant: AssetVariant, legacySourceKey: String? = nil) -> URL? {
        lock.lock(); defer { lock.unlock() }
        let sql: String
        if legacySourceKey == nil || legacySourceKey == sourceKey {
            sql = "SELECT destination_path FROM imported_files WHERE source_key = ? AND variant = ? LIMIT 1;"
        } else {
            sql = "SELECT destination_path FROM imported_files WHERE variant = ? AND source_key IN (?, ?) LIMIT 1;"
        }
        guard let statement = prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        if legacySourceKey == nil || legacySourceKey == sourceKey {
            bind(sourceKey, to: statement, at: 1)
            bind(variant.rawValue, to: statement, at: 2)
        } else {
            bind(variant.rawValue, to: statement, at: 1)
            bind(sourceKey, to: statement, at: 2)
            bind(legacySourceKey!, to: statement, at: 3)
        }
        guard sqlite3_step(statement) == SQLITE_ROW, let path = text(statement, column: 0) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func libraryAssetStatus(for url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let path = url.standardizedFileURL.path
        if exists(path: path, in: "imported_files", predicate: "file_state IN ('present', 'moved')") { return true }
        return exists(path: path, in: "library_assets", predicate: nil)
    }

    func contentRecord(for url: URL, variant: AssetVariant) -> CatalogContentRecord? {
        lock.lock(); defer { lock.unlock() }
        let path = url.standardizedFileURL.path
        let queries = [
            "SELECT sha256, file_size FROM imported_files WHERE destination_path = ? AND variant = ? LIMIT 1;",
            "SELECT sha256, file_size FROM library_assets WHERE path = ? AND variant = ? LIMIT 1;"
        ]
        for query in queries {
            guard let statement = prepare(query) else { continue }
            bind(path, to: statement, at: 1)
            bind(variant.rawValue, to: statement, at: 2)
            let found = sqlite3_step(statement) == SQLITE_ROW
            let result = found
                ? text(statement, column: 0).map { CatalogContentRecord(sha256: $0, fileSize: sqlite3_column_int64(statement, 1)) }
                : nil
            sqlite3_finalize(statement)
            if let result { return result }
        }
        return nil
    }

    /// Returns metadata-only candidates for a camera item. This never reads
    /// the photo bytes and does not establish identity; the downloaded camera
    /// file must still be verified by SHA-256.
    func matchCandidates(sourceFilenameKey: String?, fileSize: Int64, variant: AssetVariant) -> [CatalogMatchCandidate] {
        lock.lock(); defer { lock.unlock() }
        guard let sourceFilenameKey, !sourceFilenameKey.isEmpty else { return [] }
        var result: [CatalogMatchCandidate] = []
        let queries = [
            "SELECT destination_path, sha256, file_size, source_filename_key FROM imported_files WHERE file_size = ? AND source_filename_key = ? AND variant = ?;",
            "SELECT path, sha256, file_size, filename_key FROM library_assets WHERE file_size = ? AND filename_key = ? AND variant = ?;"
        ]
        for query in queries {
            guard let statement = prepare(query) else { continue }
            sqlite3_bind_int64(statement, 1, fileSize)
            bind(sourceFilenameKey, to: statement, at: 2)
            bind(variant.rawValue, to: statement, at: 3)
            while sqlite3_step(statement) == SQLITE_ROW,
                  let path = text(statement, column: 0),
                  let sha256 = text(statement, column: 1) {
                result.append(CatalogMatchCandidate(
                    path: URL(fileURLWithPath: path),
                    variant: variant,
                    fileSize: sqlite3_column_int64(statement, 2),
                    sha256: sha256,
                    filenameKey: text(statement, column: 3)
                ))
            }
            sqlite3_finalize(statement)
        }
        return result
    }

    /// Finds an existing library file whose current bytes match a verified
    /// camera download. Stored hashes narrow the candidates; the existing
    /// file is hashed again before reuse so a stale catalog row is not enough
    /// to establish identity.
    func existingContentDestination(sha256: String, variant: AssetVariant, fileSize: Int64) -> URL? {
        guard !sha256.isEmpty else { return nil }
        let paths: [URL] = {
            lock.lock(); defer { lock.unlock() }
            var result: [URL] = []
            let queries = [
                "SELECT destination_path FROM imported_files WHERE sha256 = ? AND variant = ? AND file_size = ?;",
                "SELECT path FROM library_assets WHERE sha256 = ? AND variant = ? AND file_size = ?;"
            ]
            for query in queries {
                guard let statement = prepare(query) else { continue }
                bind(sha256, to: statement, at: 1)
                bind(variant.rawValue, to: statement, at: 2)
                sqlite3_bind_int64(statement, 3, fileSize)
                while sqlite3_step(statement) == SQLITE_ROW,
                      let path = text(statement, column: 0) {
                    result.append(URL(fileURLWithPath: path).standardizedFileURL)
                }
                sqlite3_finalize(statement)
            }
            return Array(Set(result))
        }()

        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            guard (try? self.fileSize(path)) == fileSize else { continue }
            if (try? hashFile(path)) == sha256 { return path }
        }
        return nil
    }

    func recordLibraryAsset(
        url: URL,
        variant: AssetVariant,
        sha256: String,
        fileSize: Int64,
        preferredPhotoID: String? = nil
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            throw AppError.cannotOpenCatalog(catalogURL)
        }
        var committed = false
        defer { if !committed { sqlite3_exec(database, "ROLLBACK;", nil, nil, nil) } }

        let now = Date().timeIntervalSince1970
        let photoID = try resolvePhotoIDLocked(for: url, preferredPhotoID: preferredPhotoID)
        let filenameKey = FilenameIdentity.key(for: url.lastPathComponent) ?? ""
        let sql = """
        INSERT INTO library_assets(asset_key, variant, photo_id, path, filename_key, sha256, file_size, registered_at, last_verified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(asset_key) DO UPDATE SET
          photo_id = excluded.photo_id,
          path = excluded.path,
          filename_key = excluded.filename_key,
          sha256 = excluded.sha256,
          file_size = excluded.file_size,
          last_verified_at = excluded.last_verified_at;
        """
        guard let statement = prepare(sql) else { throw AppError.cannotOpenCatalog(catalogURL) }
        defer { sqlite3_finalize(statement) }
        bind(assetKey(path: url, variant: variant), to: statement, at: 1)
        bind(variant.rawValue, to: statement, at: 2)
        bind(photoID, to: statement, at: 3)
        bind(url.standardizedFileURL.path, to: statement, at: 4)
        bind(filenameKey, to: statement, at: 5)
        bind(sha256, to: statement, at: 6)
        sqlite3_bind_int64(statement, 7, fileSize)
        sqlite3_bind_double(statement, 8, now)
        if sha256.isEmpty { sqlite3_bind_null(statement, 9) } else { sqlite3_bind_double(statement, 9, now) }
        guard sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_exec(database, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            throw AppError.cannotOpenCatalog(catalogURL)
        }
        committed = true
    }

    func recordImport(sourceKey: String, variant: AssetVariant, destinationURL: URL, sha256: String, sourceFilename: String? = nil) throws {
        let size = try fileSize(destinationURL)
        try recordImports([CatalogImportRecord(sourceKey: sourceKey, variant: variant, destinationURL: destinationURL, sha256: sha256, fileSize: size, sourceFilename: sourceFilename)])
    }

    func recordImports(_ records: [CatalogImportRecord]) throws {
        guard !records.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            throw AppError.cannotOpenCatalog(catalogURL)
        }
        var committed = false
        defer { if !committed { sqlite3_exec(database, "ROLLBACK;", nil, nil, nil) } }

        let sql = """
        INSERT INTO imported_files(source_key, variant, photo_id, source_volume_uuid, source_relative_path, source_filename, source_filename_key, destination_path, sha256, file_size, imported_at, last_verified_at, file_state)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'present')
        ON CONFLICT(source_key, variant) DO UPDATE SET
          photo_id = excluded.photo_id,
          source_volume_uuid = excluded.source_volume_uuid,
          source_relative_path = excluded.source_relative_path,
          source_filename = COALESCE(excluded.source_filename, imported_files.source_filename),
          source_filename_key = COALESCE(excluded.source_filename_key, imported_files.source_filename_key),
          destination_path = excluded.destination_path,
          sha256 = excluded.sha256,
          file_size = excluded.file_size,
          imported_at = excluded.imported_at,
          last_verified_at = excluded.last_verified_at,
          file_state = 'present';
        """
        guard let statement = prepare(sql) else { throw AppError.cannotOpenCatalog(catalogURL) }
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        for record in records {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            let photoID = try resolvePhotoIDLocked(for: record.destinationURL, preferredPhotoID: record.photoID)
            bind(record.sourceKey, to: statement, at: 1)
            bind(record.variant.rawValue, to: statement, at: 2)
            bind(photoID, to: statement, at: 3)
            bindOptional(record.sourceVolumeUUID, to: statement, at: 4)
            bindOptional(record.sourceRelativePath, to: statement, at: 5)
            bindOptional(record.sourceFilename, to: statement, at: 6)
            bindOptional(record.sourceFilenameKey, to: statement, at: 7)
            bind(record.destinationURL.standardizedFileURL.path, to: statement, at: 8)
            bind(record.sha256, to: statement, at: 9)
            sqlite3_bind_int64(statement, 10, record.fileSize)
            sqlite3_bind_double(statement, 11, now)
            sqlite3_bind_double(statement, 12, now)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError.cannotOpenCatalog(catalogURL) }
            resolveIssues(sourceKey: record.sourceKey, variant: record.variant, legacySourceKey: record.legacySourceKey)
        }
        guard sqlite3_exec(database, "COMMIT;", nil, nil, nil) == SQLITE_OK else { throw AppError.cannotOpenCatalog(catalogURL) }
        committed = true
    }

    func registerLibraryAssets(_ groups: [PhotoGroup]) throws {
        let files = groups.flatMap { group in
            [(AssetVariant.jpeg, group.jpegURL), (AssetVariant.raw, group.rawURL)].compactMap { variant, url in url.map { (variant, $0, group.photoID) } }
        }
        guard !files.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else { throw AppError.cannotOpenCatalog(catalogURL) }
        var committed = false
        defer { if !committed { sqlite3_exec(database, "ROLLBACK;", nil, nil, nil) } }
        let sql = """
        INSERT INTO library_assets(asset_key, variant, photo_id, path, filename_key, sha256, file_size, registered_at, last_verified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(asset_key) DO UPDATE SET photo_id=excluded.photo_id, path=excluded.path, filename_key=excluded.filename_key, sha256=excluded.sha256, file_size=excluded.file_size, last_verified_at=excluded.last_verified_at;
        """
        guard let statement = prepare(sql) else { throw AppError.cannotOpenCatalog(catalogURL) }
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        for (variant, url, preferredPhotoID) in files {
            guard FileManager.default.fileExists(atPath: url.path), let hash = try? hashFile(url), let size = try? fileSize(url) else { continue }
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            let photoID = try resolvePhotoIDLocked(for: url, preferredPhotoID: preferredPhotoID)
            let filenameKey = FilenameIdentity.key(for: url.lastPathComponent) ?? ""
            bind(assetKey(path: url, variant: variant), to: statement, at: 1)
            bind(variant.rawValue, to: statement, at: 2)
            bind(photoID, to: statement, at: 3)
            bind(url.standardizedFileURL.path, to: statement, at: 4)
            bind(filenameKey, to: statement, at: 5)
            bind(hash, to: statement, at: 6)
            sqlite3_bind_int64(statement, 7, size)
            sqlite3_bind_double(statement, 8, now)
            sqlite3_bind_double(statement, 9, now)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError.cannotOpenCatalog(catalogURL) }
        }
        guard sqlite3_exec(database, "COMMIT;", nil, nil, nil) == SQLITE_OK else { throw AppError.cannotOpenCatalog(catalogURL) }
        committed = true
    }

    func inspectLibrary() throws -> CatalogInspectionResult {
        lock.lock(); defer { lock.unlock() }
        guard !Task.isCancelled else { throw CancellationError() }
        let files = photoFiles(in: libraryRoot)
        guard !Task.isCancelled else { throw CancellationError() }
        let byName = Dictionary(grouping: files) { "\($0.deletingPathExtension().lastPathComponent.lowercased()):\($0.pathExtension.lowercased())" }
        try exec("DELETE FROM catalog_issues WHERE status = 'open';")

        let records = importedRows()
        for record in records {
            guard !Task.isCancelled else { throw CancellationError() }
            let knownPath = record.destinationURL.standardizedFileURL
            if FileManager.default.fileExists(atPath: knownPath.path) {
                let currentSize = (try? fileSize(knownPath)) ?? -1
                // A normal library inspection is deliberately cheap. The
                // import path already verified the SHA-256, so an existing
                // file with the recorded size is considered unchanged. Full
                // hashing remains available through integrityReport() and is
                // still used for moved-file candidates below.
                if record.fileSize > 0, currentSize == record.fileSize {
                    updateImportedState(record, state: "present", verifiedAt: Date())
                    continue
                }

                // Records created by an older catalog may not have a stored
                // size. Hash those once, then populate the size so subsequent
                // inspections use the cheap path.
                if record.fileSize == 0,
                   let currentHash = try? hashFile(knownPath),
                   !record.sha256.isEmpty,
                   currentHash == record.sha256 {
                    updateImportedFileSize(record, size: currentSize)
                    updateImportedState(record, state: "present", verifiedAt: Date())
                    continue
                }

                updateImportedState(record, state: "conflict", verifiedAt: Date())
                addIssue(record: record, type: "conflict", candidate: nil)
                continue
            }

            let candidates = byName["\(knownPath.deletingPathExtension().lastPathComponent.lowercased()):\(knownPath.pathExtension.lowercased())", default: []]
                .filter { candidate in
                    candidate.standardizedFileURL != knownPath &&
                    (record.fileSize == 0 || (try? fileSize(candidate)) == record.fileSize)
                }
            var matched: URL?
            for candidate in candidates where (try? hashFile(candidate)) == record.sha256 { matched = candidate; break }
            updateImportedState(record, state: "missing", verifiedAt: Date())
            addIssue(record: record, type: matched == nil ? "missing" : "candidate", candidate: matched)
        }

        for asset in libraryAssetRows() {
            guard !Task.isCancelled else { throw CancellationError() }
            if FileManager.default.fileExists(atPath: asset.path.path),
               let currentSize = try? fileSize(asset.path),
               asset.fileSize > 0,
               currentSize == asset.fileSize {
                try? exec("UPDATE library_assets SET last_verified_at = ? WHERE asset_key = ?;", bindings: [.double(Date().timeIntervalSince1970), .text(asset.assetKey)])
            } else if FileManager.default.fileExists(atPath: asset.path.path),
                      asset.fileSize == 0,
                      let currentSize = try? fileSize(asset.path),
                      (try? hashFile(asset.path)) == asset.sha256 {
                updateLibraryAssetFileSize(asset, size: currentSize)
            } else {
                let exists = FileManager.default.fileExists(atPath: asset.path.path)
                addIssue(sourceKey: asset.assetKey, variant: asset.variant, lastKnownURL: asset.path, type: exists ? "conflict" : "missing", candidateURL: nil, expectedSize: asset.fileSize, expectedSHA256: asset.sha256)
            }
        }

        let registeredPaths = Set(records.flatMap { [$0.destinationURL.standardizedFileURL.path] })
            .union(libraryAssetPaths())
        let unregisteredCount = files.filter { !registeredPaths.contains($0.standardizedFileURL.path) }.count
        setMeta("last_inspection_at", String(Date().timeIntervalSince1970))
        setMeta("unregistered_count", String(unregisteredCount))
        return CatalogInspectionResult(summary: summaryLocked(), issues: issuesLocked())
    }

    func findCandidates(for issue: CatalogIssue, in root: URL) throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let expectedName = issue.lastKnownURL.deletingPathExtension().lastPathComponent.lowercased()
        let expectedExtension = issue.lastKnownURL.pathExtension.lowercased()
        let files = photoFiles(in: root).filter {
            $0.deletingPathExtension().lastPathComponent.lowercased() == expectedName &&
            $0.pathExtension.lowercased() == expectedExtension &&
            (issue.expectedSize == 0 || (try? fileSize($0)) == issue.expectedSize)
        }
        let matches = files.filter { (try? hashFile($0)) == issue.expectedSHA256 }
        for candidate in matches { addIssue(sourceKey: issue.sourceKey, variant: issue.variant, lastKnownURL: issue.lastKnownURL, type: "candidate", candidateURL: candidate, expectedSize: issue.expectedSize, expectedSHA256: issue.expectedSHA256) }
        return matches
    }

    func relink(issueID: Int64, to candidateURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard let issue = issueLocked(id: issueID) else { return }
        guard let hash = try? hashFile(candidateURL), hash == issue.expectedSHA256 else {
            throw AppError.transferFailed(candidateURL, NSError(domain: "Photokichin", code: 20, userInfo: [NSLocalizedDescriptionKey: "候補ファイルのSHA-256が一致しません"]))
        }
        let now = Date().timeIntervalSince1970
        let photoID: String?
        if issue.sourceKey.hasPrefix("library:") {
            photoID = singleText("SELECT photo_id FROM library_assets WHERE asset_key = ? LIMIT 1;", value: issue.sourceKey)
            let filenameKey = FilenameIdentity.key(for: candidateURL.lastPathComponent) ?? ""
            try exec("UPDATE library_assets SET path = ?, filename_key = ?, last_verified_at = ? WHERE asset_key = ?;", bindings: [.text(candidateURL.path), .text(filenameKey), .double(now), .text(issue.sourceKey)])
        } else {
            photoID = singleText("SELECT photo_id FROM imported_files WHERE source_key = ? AND variant = ? LIMIT 1;", values: [issue.sourceKey, issue.variant.rawValue])
            try exec("UPDATE imported_files SET destination_path = ?, file_state = 'moved', last_verified_at = ? WHERE source_key = ? AND variant = ?;", bindings: [.text(candidateURL.path), .double(now), .text(issue.sourceKey), .text(issue.variant.rawValue)])
        }
        if let photoID, let stem = relativeStem(for: candidateURL) {
            try exec("UPDATE library_photos SET relative_stem = ? WHERE photo_id = ?;", bindings: [.text(stem), .text(photoID)])
        }
        try exec("UPDATE catalog_issues SET status = 'resolved', resolved_at = ? WHERE issue_id = ?;", bindings: [.double(now), .int64(issueID)])
    }

    func forget(issueID: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        guard let issue = issueLocked(id: issueID) else { return }
        if issue.sourceKey.hasPrefix("library:") {
            try exec("DELETE FROM library_assets WHERE asset_key = ?;", bindings: [.text(issue.sourceKey)])
        } else {
            try exec("DELETE FROM imported_files WHERE source_key = ? AND variant = ?;", bindings: [.text(issue.sourceKey), .text(issue.variant.rawValue)])
        }
        try exec("DELETE FROM catalog_issues WHERE issue_id = ?;", bindings: [.int64(issueID)])
    }

    func issues() -> [CatalogIssue] { lock.lock(); defer { lock.unlock() }; return issuesLocked() }

    func summary() -> CatalogSummary { lock.lock(); defer { lock.unlock() }; return summaryLocked() }

    func integrityReport() -> String {
        lock.lock(); defer { lock.unlock() }
        guard let statement = prepare("PRAGMA integrity_check;") else { return "SQLiteの整合性検査を開始できませんでした。" }
        defer { sqlite3_finalize(statement) }
        var results: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { if let value = text(statement, column: 0) { results.append(value) } }
        guard !results.isEmpty else { return "SQLiteの整合性を確認できませんでした。" }
        guard results.allSatisfy({ $0 == "ok" }) else { return results.joined(separator: "\n") }

        let imported = importedRows()
        let missing = imported.filter { !FileManager.default.fileExists(atPath: $0.destinationURL.path) }.count
        let mismatched = imported.filter { row in
            guard FileManager.default.fileExists(atPath: row.destinationURL.path), let expected = try? hashFile(row.destinationURL), !row.sha256.isEmpty else { return false }
            return expected != row.sha256
        }.count
        let assets = libraryAssetRows()
        let missingAssets = assets.filter { !FileManager.default.fileExists(atPath: $0.path.path) }.count
        let mismatchedAssets = assets.filter { row in
            guard !row.sha256.isEmpty,
                  FileManager.default.fileExists(atPath: row.path.path),
                  let expected = try? hashFile(row.path) else { return false }
            return expected != row.sha256
        }.count
        let filesystemProblems = missing + mismatched + missingAssets + mismatchedAssets
        if filesystemProblems == 0 { return "ok" }
        return "SQLiteは正常ですが、写真ファイルの不整合が\(filesystemProblems)件あります（欠落 \(missing + missingAssets)件、内容不一致 \(mismatched + mismatchedAssets)件）。"
    }

    func backup(to destinationURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try backupUnlocked(to: destinationURL)
    }

    /// Rewrites only legacy source identities that are present in the
    /// currently scanned card. The caller supplies the scan result so a row
    /// from an older card mounted at the same path is not guessed from a
    /// filename alone. A SQLite backup is created before the transaction.
    func migrateSourceIdentities(
        groups: [PhotoGroup],
        sourceRoot: URL,
        volumeUUID: String
    ) throws -> SourceIdentityMigrationResult {
        var mappings: [String: (newKey: String, components: SourceIdentity.Components, variant: AssetVariant)] = [:]
        for group in groups {
            for (variant, url) in [(AssetVariant.jpeg, group.jpegURL), (AssetVariant.raw, group.rawURL), (AssetVariant.movie, group.movieURL)].compactMap({ variant, url in url.map { (variant, $0) } }) {
                let legacy = SourceIdentity.legacyKey(url: url, variant: variant)
                guard let components = SourceIdentity.components(url: url, sourceRoot: sourceRoot, volumeUUID: volumeUUID) else { continue }
                let newKey = SourceIdentity.key(url: url, variant: variant, sourceRoot: sourceRoot, volumeUUID: volumeUUID)
                guard newKey != legacy else { continue }
                mappings["\(legacy)\u{1F}\(variant.rawValue)"] = (newKey, components, variant)
            }
        }

        guard !mappings.isEmpty else {
            return SourceIdentityMigrationResult(migratedCount: 0, conflictCount: 0, backupURL: nil)
        }

        lock.lock(); defer { lock.unlock() }
        let rows = importedRows()
        let existingKeys = Set(rows.map { "\($0.sourceKey)\u{1F}\($0.variant.rawValue)" })
        var pending: [(oldKey: String, newKey: String, variant: AssetVariant, components: SourceIdentity.Components)] = []
        var conflictCount = 0
        for row in rows {
            let lookupKey = "\(row.sourceKey)\u{1F}\(row.variant.rawValue)"
            guard let mapping = mappings[lookupKey] else { continue }
            let targetLookupKey = "\(mapping.newKey)\u{1F}\(row.variant.rawValue)"
            if existingKeys.contains(targetLookupKey) {
                conflictCount += 1
            } else {
                pending.append((row.sourceKey, mapping.newKey, row.variant, mapping.components))
            }
        }

        guard !pending.isEmpty else {
            return SourceIdentityMigrationResult(migratedCount: 0, conflictCount: conflictCount, backupURL: nil)
        }

        let backupURL = catalogDirectoryURL.appendingPathComponent(
            "catalog.pre-volume-id-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).sqlite"
        )
        try backupUnlocked(to: backupURL)

        guard sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            throw AppError.cannotOpenCatalog(catalogURL)
        }
        var committed = false
        defer { if !committed { sqlite3_exec(database, "ROLLBACK;", nil, nil, nil) } }

        for item in pending {
            try exec(
                "UPDATE imported_files SET source_key = ?, source_volume_uuid = ?, source_relative_path = ? WHERE source_key = ? AND variant = ?;",
                bindings: [
                    .text(item.newKey),
                    .text(item.components.volumeUUID),
                    .text(item.components.relativePath),
                    .text(item.oldKey),
                    .text(item.variant.rawValue)
                ]
            )
            try exec(
                "UPDATE OR IGNORE catalog_issues SET source_key = ?, source_volume_uuid = ?, source_relative_path = ? WHERE source_key = ? AND variant = ?;",
                bindings: [
                    .text(item.newKey),
                    .text(item.components.volumeUUID),
                    .text(item.components.relativePath),
                    .text(item.oldKey),
                    .text(item.variant.rawValue)
                ]
            )
        }
        try exec(
            "INSERT INTO catalog_meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            bindings: [.text("source_identity_migration_v1"), .text("\(volumeUUID.lowercased())|\(sourceRoot.standardizedFileURL.path)|\(Int(Date().timeIntervalSince1970))")]
        )
        guard sqlite3_exec(database, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            throw AppError.cannotOpenCatalog(catalogURL)
        }
        committed = true
        return SourceIdentityMigrationResult(migratedCount: pending.count, conflictCount: conflictCount, backupURL: backupURL)
    }

    /// Explicit migration for a catalog whose legacy records are known to
    /// belong to the currently connected volume. Unlike the conservative
    /// scan-based migration above, this also migrates files that were already
    /// removed from the card after import.
    func migrateAllLegacySourceIdentities(
        sourceRoot: URL,
        volumeUUID: String
    ) throws -> SourceIdentityMigrationResult {
        let standardizedRoot = sourceRoot.standardizedFileURL.path
        let rootPrefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"

        lock.lock(); defer { lock.unlock() }
        let rows = importedRows()
        let existingKeys = Set(rows.map { "\($0.sourceKey)\u{1F}\($0.variant.rawValue)" })
        var pending: [(oldKey: String, newKey: String, variant: AssetVariant, relativePath: String)] = []
        var conflictCount = 0

        for row in rows {
            let suffix = ":\(row.variant.rawValue)"
            guard row.sourceKey.hasSuffix(suffix) else { continue }
            let legacyPath = String(row.sourceKey.dropLast(suffix.count))
            guard legacyPath.hasPrefix(rootPrefix) else { continue }
            let relativePath = String(legacyPath.dropFirst(rootPrefix.count))
                .replacingOccurrences(of: "\\", with: "/")
            guard !relativePath.isEmpty else { continue }
            let normalizedUUID = volumeUUID.lowercased()
            let newKey = "volume:\(normalizedUUID):\(relativePath):\(row.variant.rawValue)"
            let targetLookupKey = "\(newKey)\u{1F}\(row.variant.rawValue)"
            if existingKeys.contains(targetLookupKey) {
                conflictCount += 1
            } else {
                pending.append((row.sourceKey, newKey, row.variant, relativePath))
            }
        }

        guard !pending.isEmpty else {
            return SourceIdentityMigrationResult(migratedCount: 0, conflictCount: conflictCount, backupURL: nil)
        }

        let backupURL = catalogDirectoryURL.appendingPathComponent(
            "catalog.pre-volume-id-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).sqlite"
        )
        try backupUnlocked(to: backupURL)
        guard sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            throw AppError.cannotOpenCatalog(catalogURL)
        }
        var committed = false
        defer { if !committed { sqlite3_exec(database, "ROLLBACK;", nil, nil, nil) } }

        for item in pending {
            try exec(
                "UPDATE imported_files SET source_key = ?, source_volume_uuid = ?, source_relative_path = ? WHERE source_key = ? AND variant = ?;",
                bindings: [
                    .text(item.newKey),
                    .text(volumeUUID.lowercased()),
                    .text(item.relativePath),
                    .text(item.oldKey),
                    .text(item.variant.rawValue)
                ]
            )
            try exec(
                "UPDATE OR IGNORE catalog_issues SET source_key = ?, source_volume_uuid = ?, source_relative_path = ? WHERE source_key = ? AND variant = ?;",
                bindings: [
                    .text(item.newKey),
                    .text(volumeUUID.lowercased()),
                    .text(item.relativePath),
                    .text(item.oldKey),
                    .text(item.variant.rawValue)
                ]
            )
        }
        try exec(
            "INSERT INTO catalog_meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            bindings: [.text("source_identity_migration_v1"), .text("\(volumeUUID.lowercased())|\(standardizedRoot)|\(Int(Date().timeIntervalSince1970))")]
        )
        guard sqlite3_exec(database, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            throw AppError.cannotOpenCatalog(catalogURL)
        }
        committed = true
        return SourceIdentityMigrationResult(migratedCount: pending.count, conflictCount: conflictCount, backupURL: backupURL)
    }

    private func backupUnlocked(to destinationURL: URL) throws {
        var destination: OpaquePointer?
        guard sqlite3_open_v2(destinationURL.path, &destination, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let destination else {
            throw AppError.cannotOpenCatalog(destinationURL)
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", database, "main") else { throw AppError.cannotOpenCatalog(destinationURL) }
        let result = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else { throw AppError.cannotOpenCatalog(destinationURL) }
    }

    private func createSchema() throws {
        let sql = """
        PRAGMA foreign_keys = ON;
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS catalog_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS imported_files(
          source_key TEXT NOT NULL,
          variant TEXT NOT NULL,
          photo_id TEXT NOT NULL,
          source_volume_uuid TEXT,
          source_relative_path TEXT,
          source_filename TEXT,
          source_filename_key TEXT,
          destination_path TEXT NOT NULL,
          sha256 TEXT NOT NULL,
          file_size INTEGER NOT NULL DEFAULT 0,
          imported_at REAL NOT NULL,
          last_verified_at REAL,
          file_state TEXT NOT NULL DEFAULT 'present',
          PRIMARY KEY(source_key, variant)
        );
        CREATE TABLE IF NOT EXISTS library_assets(
          asset_key TEXT PRIMARY KEY,
          variant TEXT NOT NULL,
          photo_id TEXT NOT NULL,
          path TEXT NOT NULL,
          filename_key TEXT NOT NULL DEFAULT '',
          sha256 TEXT NOT NULL,
          file_size INTEGER NOT NULL DEFAULT 0,
          registered_at REAL NOT NULL,
          last_verified_at REAL
        );
        CREATE TABLE IF NOT EXISTS catalog_issues(
          issue_id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_key TEXT NOT NULL,
          variant TEXT NOT NULL,
          source_volume_uuid TEXT,
          source_relative_path TEXT,
          issue_type TEXT NOT NULL,
          last_known_path TEXT NOT NULL,
          candidate_path TEXT,
          expected_size INTEGER NOT NULL DEFAULT 0,
          expected_sha256 TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'open',
          detected_at REAL NOT NULL,
          resolved_at REAL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS catalog_issues_open_unique
          ON catalog_issues(source_key, variant, issue_type, last_known_path, IFNULL(candidate_path, ''))
          WHERE status = 'open';
        CREATE TABLE IF NOT EXISTS library_photos(
          photo_id TEXT PRIMARY KEY,
          relative_stem TEXT NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS labels(
          label_id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          normalized_name TEXT NOT NULL UNIQUE,
          color_hex TEXT NOT NULL,
          sort_order INTEGER NOT NULL DEFAULT 0,
          last_used_at REAL
        );
        CREATE TABLE IF NOT EXISTS photo_labels(
          photo_id TEXT NOT NULL REFERENCES library_photos(photo_id) ON DELETE CASCADE,
          label_id TEXT NOT NULL REFERENCES labels(label_id) ON DELETE CASCADE,
          PRIMARY KEY(photo_id, label_id)
        );
        CREATE TABLE IF NOT EXISTS saved_label_views(
          view_id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          sort_order INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS saved_label_view_labels(
          view_id TEXT NOT NULL REFERENCES saved_label_views(view_id) ON DELETE CASCADE,
          label_id TEXT NOT NULL REFERENCES labels(label_id) ON DELETE CASCADE,
          PRIMARY KEY(view_id, label_id)
        );
        CREATE INDEX IF NOT EXISTS photo_labels_label_photo_idx ON photo_labels(label_id, photo_id);
        CREATE INDEX IF NOT EXISTS photo_labels_photo_label_idx ON photo_labels(photo_id, label_id);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw AppError.cannotOpenCatalog(catalogURL) }
        try exec("CREATE INDEX IF NOT EXISTS imported_files_volume_relative_idx ON imported_files(source_volume_uuid, source_relative_path, variant);")
        try exec("CREATE INDEX IF NOT EXISTS imported_files_size_filename_idx ON imported_files(file_size, source_filename_key);")
        try exec("CREATE INDEX IF NOT EXISTS library_assets_size_filename_idx ON library_assets(file_size, filename_key);")
        try exec("CREATE INDEX IF NOT EXISTS imported_files_sha256_idx ON imported_files(sha256) WHERE sha256 <> '';")
        try exec("CREATE INDEX IF NOT EXISTS library_assets_sha256_idx ON library_assets(sha256) WHERE sha256 <> '';")
        try exec("INSERT INTO catalog_meta(key, value) VALUES ('schema_version', '3');")
    }

    private func validateCurrentSchema() throws {
        guard ["2", "3"].contains(meta("schema_version")),
              inspectSchema("imported_files").contains("photo_id"),
              inspectSchema("library_assets").contains("photo_id"),
              !inspectSchema("labels").isEmpty else {
            throw AppError.catalogMigrationRequired(catalogURL)
        }
        if meta("schema_version") == "2" {
            try migrateFilenameSchema()
        }
        guard inspectSchema("imported_files").contains("source_filename"),
              inspectSchema("imported_files").contains("source_filename_key"),
              inspectSchema("library_assets").contains("filename_key") else {
            throw AppError.catalogMigrationRequired(catalogURL)
        }
        guard count("SELECT COUNT(*) FROM imported_files WHERE photo_id IS NULL OR photo_id = '';") == 0,
              count("SELECT COUNT(*) FROM library_assets WHERE photo_id IS NULL OR photo_id = '';") == 0 else {
            throw AppError.catalogMigrationRequired(catalogURL)
        }
        try exec("PRAGMA foreign_keys = ON;")
    }

    private func migrateFilenameSchema() throws {
        try beginTransactionLocked()
        do {
            let importedColumns = inspectSchema("imported_files")
            let libraryColumns = inspectSchema("library_assets")
            if !importedColumns.contains("source_filename") {
                try exec("ALTER TABLE imported_files ADD COLUMN source_filename TEXT;")
            }
            if !importedColumns.contains("source_filename_key") {
                try exec("ALTER TABLE imported_files ADD COLUMN source_filename_key TEXT;")
            }
            if !libraryColumns.contains("filename_key") {
                try exec("ALTER TABLE library_assets ADD COLUMN filename_key TEXT NOT NULL DEFAULT '';")
            }

            guard let statement = prepare("SELECT asset_key, path FROM library_assets;") else {
                throw AppError.cannotOpenCatalog(catalogURL)
            }
            var assets: [(String, String)] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let assetKey = text(statement, column: 0),
                  let path = text(statement, column: 1) {
                assets.append((assetKey, path))
            }
            sqlite3_finalize(statement)
            for (assetKey, path) in assets {
                try exec(
                    "UPDATE library_assets SET filename_key = ? WHERE asset_key = ?;",
                    bindings: [.text(FilenameIdentity.key(for: URL(fileURLWithPath: path).lastPathComponent) ?? ""), .text(assetKey)]
                )
            }

            try exec("CREATE INDEX IF NOT EXISTS imported_files_size_filename_idx ON imported_files(file_size, source_filename_key);")
            try exec("CREATE INDEX IF NOT EXISTS library_assets_size_filename_idx ON library_assets(file_size, filename_key);")
            try exec("CREATE INDEX IF NOT EXISTS imported_files_sha256_idx ON imported_files(sha256) WHERE sha256 <> '';")
            try exec("CREATE INDEX IF NOT EXISTS library_assets_sha256_idx ON library_assets(sha256) WHERE sha256 <> '';")
            try exec("UPDATE catalog_meta SET value = '3' WHERE key = 'schema_version';")
            try commitTransactionLocked()
        } catch {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func inspectSchema(_ table: String) -> Set<String> {
        guard let statement = prepare("PRAGMA table_info(\(table));") else { return [] }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { if let name = text(statement, column: 1) { columns.insert(name) } }
        return columns
    }

    private func ensureColumn(table: String, column: String, definition: String) throws {
        guard !inspectSchema(table).contains(column) else { return }
        try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private func importedRows() -> [ImportedRow] {
        guard let statement = prepare("SELECT source_key, variant, source_volume_uuid, source_relative_path, destination_path, sha256, file_size FROM imported_files;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [ImportedRow] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let sourceKey = text(statement, column: 0),
              let variant = text(statement, column: 1).flatMap(AssetVariant.init(rawValue:)),
              let path = text(statement, column: 4),
              let sha = text(statement, column: 5) {
            rows.append(ImportedRow(
                sourceKey: sourceKey,
                variant: variant,
                sourceVolumeUUID: text(statement, column: 2),
                sourceRelativePath: text(statement, column: 3),
                destinationURL: URL(fileURLWithPath: path),
                sha256: sha,
                fileSize: sqlite3_column_int64(statement, 6)
            ))
        }
        return rows
    }

    private func libraryAssetRows() -> [LibraryAssetRow] {
        guard let statement = prepare("SELECT asset_key, variant, path, sha256, file_size, filename_key FROM library_assets;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [LibraryAssetRow] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let assetKey = text(statement, column: 0),
              let variant = text(statement, column: 1).flatMap(AssetVariant.init(rawValue:)),
              let path = text(statement, column: 2),
              let sha = text(statement, column: 3) {
            rows.append(LibraryAssetRow(assetKey: assetKey, variant: variant, path: URL(fileURLWithPath: path), sha256: sha, fileSize: sqlite3_column_int64(statement, 4), filenameKey: text(statement, column: 5) ?? ""))
        }
        return rows
    }

    private func issuesLocked() -> [CatalogIssue] {
        guard let statement = prepare("SELECT issue_id, source_key, variant, issue_type, last_known_path, candidate_path, expected_size, expected_sha256, detected_at FROM catalog_issues WHERE status = 'open' ORDER BY detected_at DESC, issue_id DESC;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [CatalogIssue] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let sourceKey = text(statement, column: 1),
              let variant = text(statement, column: 2).flatMap(AssetVariant.init(rawValue:)),
              let type = text(statement, column: 3),
              let path = text(statement, column: 4),
              let sha = text(statement, column: 7) {
            result.append(CatalogIssue(
                id: sqlite3_column_int64(statement, 0), sourceKey: sourceKey, variant: variant,
                issueType: type, lastKnownURL: URL(fileURLWithPath: path),
                candidateURL: text(statement, column: 5).map(URL.init(fileURLWithPath:)),
                expectedSize: sqlite3_column_int64(statement, 6), expectedSHA256: sha,
                detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))))
        }
        return result
    }

    private func issueLocked(id: Int64) -> CatalogIssue? { issuesLocked().first { $0.id == id } }

    private func summaryLocked() -> CatalogSummary {
        let attributes = try? FileManager.default.attributesOfItem(atPath: catalogURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let lastInspection = meta("last_inspection_at").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return CatalogSummary(
            catalogURL: catalogURL, catalogSize: size, lastInspectionAt: lastInspection,
            importedFileCount: count("SELECT COUNT(*) FROM imported_files WHERE sha256 <> ''"),
            registeredAssetCount: count("SELECT COUNT(*) FROM library_assets"),
            unregisteredPhotoCount: Int(meta("unregistered_count") ?? "0") ?? 0,
            missingCount: count("SELECT COUNT(*) FROM catalog_issues WHERE status = 'open' AND issue_type = 'missing'"),
            candidateCount: count("SELECT COUNT(*) FROM catalog_issues WHERE status = 'open' AND issue_type = 'candidate'"),
            conflictCount: count("SELECT COUNT(*) FROM catalog_issues WHERE status = 'open' AND issue_type = 'conflict'"))
    }

    private func addIssue(record: ImportedRow, type: String, candidate: URL?) {
        try? exec(
            "INSERT OR IGNORE INTO catalog_issues(source_key, variant, source_volume_uuid, source_relative_path, issue_type, last_known_path, candidate_path, expected_size, expected_sha256, status, detected_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?);",
            bindings: [
                .text(record.sourceKey),
                .text(record.variant.rawValue),
                record.sourceVolumeUUID.map { .text($0) } ?? .null,
                record.sourceRelativePath.map { .text($0) } ?? .null,
                .text(type),
                .text(record.destinationURL.path),
                candidate.map { .text($0.path) } ?? .null,
                .int64(record.fileSize),
                .text(record.sha256),
                .double(Date().timeIntervalSince1970)
            ]
        )
    }

    private func addIssue(sourceKey: String, variant: AssetVariant, lastKnownURL: URL, type: String, candidateURL: URL?, expectedSize: Int64, expectedSHA256: String) {
        try? exec("INSERT OR IGNORE INTO catalog_issues(source_key, variant, issue_type, last_known_path, candidate_path, expected_size, expected_sha256, status, detected_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?);", bindings: [.text(sourceKey), .text(variant.rawValue), .text(type), .text(lastKnownURL.path), candidateURL.map { .text($0.path) } ?? .null, .int64(expectedSize), .text(expectedSHA256), .double(Date().timeIntervalSince1970)])
    }

    private func resolveIssues(sourceKey: String, variant: AssetVariant, legacySourceKey: String? = nil) {
        if let legacySourceKey, legacySourceKey != sourceKey {
            try? exec(
                "UPDATE catalog_issues SET status = 'resolved', resolved_at = ? WHERE variant = ? AND source_key IN (?, ?) AND status = 'open';",
                bindings: [.double(Date().timeIntervalSince1970), .text(variant.rawValue), .text(sourceKey), .text(legacySourceKey)]
            )
        } else {
            try? exec("UPDATE catalog_issues SET status = 'resolved', resolved_at = ? WHERE source_key = ? AND variant = ? AND status = 'open';", bindings: [.double(Date().timeIntervalSince1970), .text(sourceKey), .text(variant.rawValue)])
        }
    }

    private func updateImportedState(_ row: ImportedRow, state: String, verifiedAt: Date) {
        try? exec("UPDATE imported_files SET file_state = ?, last_verified_at = ? WHERE source_key = ? AND variant = ?;", bindings: [.text(state), .double(verifiedAt.timeIntervalSince1970), .text(row.sourceKey), .text(row.variant.rawValue)])
    }

    private func updateImportedFileSize(_ row: ImportedRow, size: Int64) {
        try? exec("UPDATE imported_files SET file_size = ? WHERE source_key = ? AND variant = ?;", bindings: [.int64(size), .text(row.sourceKey), .text(row.variant.rawValue)])
    }

    private func updateLibraryAssetFileSize(_ row: LibraryAssetRow, size: Int64) {
        try? exec("UPDATE library_assets SET file_size = ?, last_verified_at = ? WHERE asset_key = ?;", bindings: [.int64(size), .double(Date().timeIntervalSince1970), .text(row.assetKey)])
    }

    private func libraryAssetPaths() -> Set<String> {
        guard let statement = prepare("SELECT path FROM library_assets;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var paths = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW, let path = text(statement, column: 0) { paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path) }
        return paths
    }

    private func photoFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return enumerator.compactMap { item in
            guard !Task.isCancelled else { return nil }
            guard let url = item as? URL, ["jpg", "jpeg", "cr3"].contains(url.pathExtension.lowercased()), let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey]), values.isRegularFile == true, values.isHidden != true else { return nil }
            return url.standardizedFileURL
        }
    }

    private func assetKey(path: URL, variant: AssetVariant) -> String { "library:\(path.standardizedFileURL.path):\(variant.rawValue)" }

    private func exists(path: String, in table: String, predicate: String?) -> Bool {
        let suffix = predicate.map { " AND \($0)" } ?? ""
        let pathColumn = table == "imported_files" ? "destination_path" : "path"
        guard let statement = prepare("SELECT 1 FROM \(table) WHERE \(pathColumn) = ?\(suffix) LIMIT 1;") else { return false }
        defer { sqlite3_finalize(statement) }
        bind(path, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func hashFile(_ url: URL) throws -> String {
        guard let stream = InputStream(url: url) else { throw AppError.transferFailed(url, NSError(domain: "Photokichin", code: 30)) }
        stream.open(); defer { stream.close() }
        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            if Task.isCancelled { throw CancellationError() }
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 { throw stream.streamError ?? AppError.transferFailed(url, NSError(domain: "Photokichin", code: 31)) }
            if read == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: read))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else { throw AppError.transferFailed(url, NSError(domain: "Photokichin", code: 32)) }
        return Int64(size)
    }

    // MARK: - Persistent photo identity and labels

    func labelSnapshot(for groups: [PhotoGroup]) -> LabelCatalogSnapshot {
        lock.lock(); defer { lock.unlock() }
        let allLabels = labelsLocked()
        let labelsByID = Dictionary(uniqueKeysWithValues: allLabels.map { ($0.id, $0) })
        var photoIDByGroupID: [String: String] = [:]
        var labelsByPhotoID: [String: [PhotoLabel]] = [:]

        let photoLookup = prepare("SELECT photo_id FROM library_photos WHERE relative_stem = ? LIMIT 1;")
        defer { if let photoLookup { sqlite3_finalize(photoLookup) } }
        let labelLookup = prepare("""
            SELECT l.label_id FROM photo_labels pl
            JOIN labels l ON l.label_id = pl.label_id
            WHERE pl.photo_id = ? ORDER BY l.sort_order, l.name;
            """)
        defer { if let labelLookup { sqlite3_finalize(labelLookup) } }

        for group in groups {
            guard let url = group.primaryURL,
                  let photoLookup,
                  let relativeStem = relativeStem(for: url) else { continue }
            sqlite3_reset(photoLookup); sqlite3_clear_bindings(photoLookup)
            bind(relativeStem, to: photoLookup, at: 1)
            guard sqlite3_step(photoLookup) == SQLITE_ROW,
                  let photoID = text(photoLookup, column: 0) else { continue }
            photoIDByGroupID[group.id] = photoID

            guard labelsByPhotoID[photoID] == nil, let labelLookup else { continue }
            sqlite3_reset(labelLookup); sqlite3_clear_bindings(labelLookup)
            bind(photoID, to: labelLookup, at: 1)
            var photoLabels: [PhotoLabel] = []
            while sqlite3_step(labelLookup) == SQLITE_ROW,
                  let labelID = text(labelLookup, column: 0),
                  let label = labelsByID[labelID] {
                photoLabels.append(label)
            }
            labelsByPhotoID[photoID] = photoLabels
        }
        return LabelCatalogSnapshot(
            labels: allLabels,
            savedViews: savedViewsLocked(),
            photoIDByGroupID: photoIDByGroupID,
            labelsByPhotoID: labelsByPhotoID
        )
    }

    func createLabel(name: String, colorHex: String) throws -> PhotoLabel {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedLabelName(trimmed)
        guard !trimmed.isEmpty, trimmed.count <= 64, !normalized.isEmpty else {
            throw AppError.invalidLabelName
        }
        lock.lock(); defer { lock.unlock() }
        if let existing = labelLocked(normalizedName: normalized) { return existing }
        let label = PhotoLabel(
            id: UUID().uuidString,
            name: trimmed,
            normalizedName: normalized,
            colorHex: normalizedColorHex(colorHex),
            sortOrder: count("SELECT COUNT(*) FROM labels;"),
            lastUsedAt: nil
        )
        try exec(
            "INSERT INTO labels(label_id, name, normalized_name, color_hex, sort_order) VALUES (?, ?, ?, ?, ?);",
            bindings: [.text(label.id), .text(label.name), .text(label.normalizedName), .text(label.colorHex), .int64(Int64(label.sortOrder))]
        )
        return label
    }

    func updateLabel(_ label: PhotoLabel) throws {
        let trimmed = label.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedLabelName(trimmed)
        guard !trimmed.isEmpty, trimmed.count <= 64, !normalized.isEmpty else { throw AppError.invalidLabelName }
        lock.lock(); defer { lock.unlock() }
        try exec(
            "UPDATE labels SET name = ?, normalized_name = ?, color_hex = ?, sort_order = ? WHERE label_id = ?;",
            bindings: [.text(trimmed), .text(normalized), .text(normalizedColorHex(label.colorHex)), .int64(Int64(label.sortOrder)), .text(label.id)]
        )
    }

    func deleteLabel(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("DELETE FROM labels WHERE label_id = ?;", bindings: [.text(id)])
        try exec("DELETE FROM saved_label_views WHERE view_id NOT IN (SELECT DISTINCT view_id FROM saved_label_view_labels);")
    }

    func mergeLabel(sourceID: String, destinationID: String) throws {
        guard sourceID != destinationID else { return }
        lock.lock(); defer { lock.unlock() }
        try beginTransactionLocked()
        do {
            try exec("INSERT OR IGNORE INTO photo_labels(photo_id, label_id) SELECT photo_id, ? FROM photo_labels WHERE label_id = ?;", bindings: [.text(destinationID), .text(sourceID)])
            try exec("INSERT OR IGNORE INTO saved_label_view_labels(view_id, label_id) SELECT view_id, ? FROM saved_label_view_labels WHERE label_id = ?;", bindings: [.text(destinationID), .text(sourceID)])
            try exec("DELETE FROM labels WHERE label_id = ?;", bindings: [.text(sourceID)])
            try commitTransactionLocked()
        } catch {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    func setLabel(_ labelID: String, on photoIDs: [String], assigned: Bool) throws {
        guard !photoIDs.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try beginTransactionLocked()
        do {
            let sql = assigned
                ? "INSERT OR IGNORE INTO photo_labels(photo_id, label_id) VALUES (?, ?);"
                : "DELETE FROM photo_labels WHERE photo_id = ? AND label_id = ?;"
            guard let statement = prepare(sql) else { throw AppError.cannotOpenCatalog(catalogURL) }
            defer { sqlite3_finalize(statement) }
            for photoID in Set(photoIDs) {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(photoID, to: statement, at: 1)
                bind(labelID, to: statement, at: 2)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError.cannotOpenCatalog(catalogURL) }
            }
            if assigned {
                try exec("UPDATE labels SET last_used_at = ? WHERE label_id = ?;", bindings: [.double(Date().timeIntervalSince1970), .text(labelID)])
            }
            try commitTransactionLocked()
        } catch {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    func saveLabelView(name: String, labelIDs: [String]) throws -> SavedLabelView {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !labelIDs.isEmpty else { throw AppError.invalidLabelName }
        lock.lock(); defer { lock.unlock() }
        let view = SavedLabelView(id: UUID().uuidString, name: trimmed, labelIDs: Array(Set(labelIDs)), sortOrder: count("SELECT COUNT(*) FROM saved_label_views;"))
        try beginTransactionLocked()
        do {
            try exec("INSERT INTO saved_label_views(view_id, name, sort_order) VALUES (?, ?, ?);", bindings: [.text(view.id), .text(view.name), .int64(Int64(view.sortOrder))])
            for labelID in view.labelIDs {
                try exec("INSERT INTO saved_label_view_labels(view_id, label_id) VALUES (?, ?);", bindings: [.text(view.id), .text(labelID)])
            }
            try commitTransactionLocked()
            return view
        } catch {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    func deleteSavedLabelView(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("DELETE FROM saved_label_views WHERE view_id = ?;", bindings: [.text(id)])
    }

    func transferredLabels(for photoID: String) -> [TransferredLabel] {
        lock.lock(); defer { lock.unlock() }
        guard let statement = prepare("""
            SELECT l.name, l.normalized_name, l.color_hex FROM labels l
            JOIN photo_labels pl ON pl.label_id = l.label_id
            WHERE pl.photo_id = ? ORDER BY l.sort_order, l.name;
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(photoID, to: statement, at: 1)
        var result: [TransferredLabel] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let name = text(statement, column: 0),
              let normalized = text(statement, column: 1),
              let color = text(statement, column: 2) {
            result.append(TransferredLabel(name: name, normalizedName: normalized, colorHex: color))
        }
        return result
    }

    /// Resolves by normalized name only and generates destination-local UUIDs.
    /// `TransferredLabel` cannot carry a source label UUID by construction.
    func applyTransferredLabels(_ transferred: [TransferredLabel], to photoID: String) throws {
        guard !transferred.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try beginTransactionLocked()
        do {
            for descriptor in transferred {
                let normalized = normalizedLabelName(descriptor.name)
                let destinationLabelID: String
                if let existing = labelLocked(normalizedName: normalized) {
                    destinationLabelID = existing.id
                } else {
                    destinationLabelID = UUID().uuidString
                    try exec(
                        "INSERT INTO labels(label_id, name, normalized_name, color_hex, sort_order, last_used_at) VALUES (?, ?, ?, ?, ?, ?);",
                        bindings: [.text(destinationLabelID), .text(descriptor.name), .text(normalized), .text(normalizedColorHex(descriptor.colorHex)), .int64(Int64(count("SELECT COUNT(*) FROM labels;"))), .double(Date().timeIntervalSince1970)]
                    )
                }
                try exec("INSERT OR IGNORE INTO photo_labels(photo_id, label_id) VALUES (?, ?);", bindings: [.text(photoID), .text(destinationLabelID)])
            }
            try commitTransactionLocked()
        } catch {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    func photoID(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let relativeStem = relativeStem(for: url),
              let statement = prepare("SELECT photo_id FROM library_photos WHERE relative_stem = ? LIMIT 1;") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(relativeStem, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, column: 0)
    }

    private func labelsLocked() -> [PhotoLabel] {
        guard let statement = prepare("SELECT label_id, name, normalized_name, color_hex, sort_order, last_used_at FROM labels ORDER BY sort_order, name;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [PhotoLabel] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let id = text(statement, column: 0),
              let name = text(statement, column: 1),
              let normalized = text(statement, column: 2),
              let color = text(statement, column: 3) {
            let lastUsed = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            result.append(PhotoLabel(id: id, name: name, normalizedName: normalized, colorHex: color, sortOrder: Int(sqlite3_column_int64(statement, 4)), lastUsedAt: lastUsed))
        }
        return result
    }

    private func labelLocked(normalizedName: String) -> PhotoLabel? {
        guard let statement = prepare("SELECT label_id, name, normalized_name, color_hex, sort_order, last_used_at FROM labels WHERE normalized_name = ? LIMIT 1;") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(normalizedName, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = text(statement, column: 0), let name = text(statement, column: 1),
              let normalized = text(statement, column: 2), let color = text(statement, column: 3) else { return nil }
        let lastUsed = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        return PhotoLabel(id: id, name: name, normalizedName: normalized, colorHex: color, sortOrder: Int(sqlite3_column_int64(statement, 4)), lastUsedAt: lastUsed)
    }

    private func savedViewsLocked() -> [SavedLabelView] {
        guard let statement = prepare("SELECT view_id, name, sort_order FROM saved_label_views ORDER BY sort_order, name;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [SavedLabelView] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let id = text(statement, column: 0), let name = text(statement, column: 1) {
            guard let labelsStatement = prepare("SELECT label_id FROM saved_label_view_labels WHERE view_id = ? ORDER BY label_id;") else { continue }
            bind(id, to: labelsStatement, at: 1)
            var labelIDs: [String] = []
            while sqlite3_step(labelsStatement) == SQLITE_ROW, let labelID = text(labelsStatement, column: 0) { labelIDs.append(labelID) }
            sqlite3_finalize(labelsStatement)
            result.append(SavedLabelView(id: id, name: name, labelIDs: labelIDs, sortOrder: Int(sqlite3_column_int64(statement, 2))))
        }
        return result
    }

    private func resolvePhotoIDLocked(for url: URL, preferredPhotoID: String?) throws -> String {
        guard let stem = relativeStem(for: url) else { throw AppError.cannotOpenCatalog(catalogURL) }
        if let statement = prepare("SELECT photo_id FROM library_photos WHERE relative_stem = ? LIMIT 1;") {
            defer { sqlite3_finalize(statement) }
            bind(stem, to: statement, at: 1)
            if sqlite3_step(statement) == SQLITE_ROW, let value = text(statement, column: 0) { return value }
        }
        var photoID = preferredPhotoID ?? UUID().uuidString
        if let preferredPhotoID,
           exists(value: preferredPhotoID, column: "photo_id", table: "library_photos") {
            // One catalog cannot bind the same photo identity to two paths.
            photoID = UUID().uuidString
        }
        try exec("INSERT INTO library_photos(photo_id, relative_stem) VALUES (?, ?);", bindings: [.text(photoID), .text(stem)])
        return photoID
    }

    private func relativeStem(for url: URL) -> String? {
        let path = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        let root = libraryRoot.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return (relative as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping
    }

    private func exists(value: String, column: String, table: String) -> Bool {
        guard let statement = prepare("SELECT 1 FROM \(table) WHERE \(column) = ? LIMIT 1;") else { return false }
        defer { sqlite3_finalize(statement) }
        bind(value, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func singleText(_ sql: String, value: String) -> String? {
        singleText(sql, values: [value])
    }

    private func singleText(_ sql: String, values: [String]) -> String? {
        guard let statement = prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { bind(value, to: statement, at: Int32(offset + 1)) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, column: 0)
    }

    private func normalizedColorHex(_ value: String) -> String {
        let upper = value.uppercased()
        guard upper.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil else { return LabelPalette.colors[0] }
        return upper
    }

    private func beginTransactionLocked() throws {
        guard sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else { throw AppError.cannotOpenCatalog(catalogURL) }
    }

    private func commitTransactionLocked() throws {
        guard sqlite3_exec(database, "COMMIT;", nil, nil, nil) == SQLITE_OK else { throw AppError.cannotOpenCatalog(catalogURL) }
    }

    private enum Binding { case text(String), int64(Int64), double(Double), null }

    private func exec(_ sql: String, bindings: [Binding] = []) throws {
        guard let statement = prepare(sql) else { throw AppError.cannotOpenCatalog(catalogURL) }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() { bind(binding, to: statement, at: Int32(offset + 1)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError.cannotOpenCatalog(catalogURL) }
    }

    private func count(_ sql: String) -> Int {
        guard let statement = prepare(sql) else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func meta(_ key: String) -> String? {
        guard let statement = prepare("SELECT value FROM catalog_meta WHERE key = ? LIMIT 1;") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, column: 0)
    }

    private func setMeta(_ key: String, _ value: String) {
        try? exec("INSERT INTO catalog_meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;", bindings: [.text(key), .text(value)])
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    private func bind(_ binding: Binding, to statement: OpaquePointer, at index: Int32) {
        switch binding {
        case .text(let value): bind(value, to: statement, at: index)
        case .int64(let value): sqlite3_bind_int64(statement, index, value)
        case .double(let value): sqlite3_bind_double(statement, index, value)
        case .null: sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptional(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        if let value { bind(value, to: statement, at: index) } else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func open() throws {
        if sqlite3_open_v2(catalogURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            if let database { sqlite3_close(database) }
            database = nil
            throw AppError.cannotOpenCatalog(catalogURL)
        }
    }

    private func closeDatabase() {
        if let database { sqlite3_close(database); self.database = nil }
    }
}
