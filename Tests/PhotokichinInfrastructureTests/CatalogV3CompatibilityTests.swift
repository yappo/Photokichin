import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import PhotokichinDomain
@testable import PhotokichinInfrastructure

@Suite("Catalog v3 compatibility")
struct CatalogV3CompatibilityTests {
    @Test("Baseline schema v3 records open without migration")
    func opensBaselineSchemaWithoutMigration() throws {
        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-catalog-v3-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let importedDirectory = libraryRoot.appendingPathComponent("Imported", isDirectory: true)
        let libraryDirectory = libraryRoot.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: importedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)

        let importedRendered = importedDirectory.appendingPathComponent("IMG_0001.JPG")
        let importedRaw = importedDirectory.appendingPathComponent("IMG_0001.CR3")
        let libraryRendered = libraryDirectory.appendingPathComponent("IMG_0002.JPG")
        let libraryRaw = libraryDirectory.appendingPathComponent("IMG_0002.CR3")
        try Data("baseline-rendered".utf8).write(to: importedRendered)
        try Data("baseline-raw".utf8).write(to: importedRaw)
        try Data("library-rendered".utf8).write(to: libraryRendered)
        try Data("library-raw".utf8).write(to: libraryRaw)

        let importedRenderedHash = try hash(importedRendered)
        let importedRawHash = try hash(importedRaw)
        let libraryRenderedHash = try hash(libraryRendered)
        let libraryRawHash = try hash(libraryRaw)
        let catalogDirectory = libraryRoot.appendingPathComponent(".photokichin", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        let catalogURL = catalogDirectory.appendingPathComponent("catalog.sqlite")
        try createBaselineV3Fixture(
            at: catalogURL,
            importedRendered: importedRendered,
            importedRaw: importedRaw,
            importedRenderedHash: importedRenderedHash,
            importedRawHash: importedRawHash,
            libraryRendered: libraryRendered,
            libraryRaw: libraryRaw,
            libraryRenderedHash: libraryRenderedHash,
            libraryRawHash: libraryRawHash
        )

        #expect(try queryText("SELECT value FROM catalog_meta WHERE key = 'schema_version';", at: catalogURL) == "3")
        let store = try CatalogStore(libraryRoot: libraryRoot, classifier: InfrastructureTestSupport.classifier)
        #expect(try queryText("SELECT value FROM catalog_meta WHERE key = 'schema_version';", at: catalogURL) == "3")

        let renderedSourceKey = "volume:fixture-volume:DCIM/100/IMG_0001:JPG"
        let rawSourceKey = "volume:fixture-volume:DCIM/100/IMG_0001:CR3"
        #expect(store.isImported(sourceKey: renderedSourceKey, variant: .renderedImage))
        #expect(store.isImported(sourceKey: rawSourceKey, variant: .raw))
        #expect(store.importedDestination(sourceKey: renderedSourceKey, variant: .renderedImage)?.standardizedFileURL == importedRendered.standardizedFileURL)
        #expect(store.importedDestination(sourceKey: rawSourceKey, variant: .raw)?.standardizedFileURL == importedRaw.standardizedFileURL)
        #expect(store.photoID(for: importedRendered) == "photo-imported")
        #expect(store.photoID(for: importedRaw) == "photo-imported")
        let importedRenderedRecord = try #require(store.contentRecord(for: importedRendered, variant: .renderedImage))
        #expect(importedRenderedRecord.sha256 == importedRenderedHash)
        #expect(importedRenderedRecord.fileSize == Int64(Data("baseline-rendered".utf8).count))
        let importedRawRecord = try #require(store.contentRecord(for: importedRaw, variant: .raw))
        #expect(importedRawRecord.sha256 == importedRawHash)
        #expect(importedRawRecord.fileSize == Int64(Data("baseline-raw".utf8).count))
        #expect(store.existingContentDestination(sha256: importedRenderedHash, variant: .renderedImage, fileSize: Int64(Data("baseline-rendered".utf8).count))?.standardizedFileURL == importedRendered.standardizedFileURL)
        #expect(store.existingContentDestination(sha256: importedRawHash, variant: .raw, fileSize: Int64(Data("baseline-raw".utf8).count))?.standardizedFileURL == importedRaw.standardizedFileURL)
        #expect(store.matchCandidates(sourceFilenameKey: "img_0001.jpg", fileSize: Int64(Data("baseline-rendered".utf8).count), variant: .renderedImage).map { $0.path.path } == [importedRendered.path])

        let importedGroup = PhotoGroup(
            id: "imported-group",
            basename: "IMG_0001",
            directory: importedDirectory,
            renderedImageURL: importedRendered,
            rawURL: importedRaw,
            movieURL: nil,
            captureDate: nil,
            metadata: .empty,
            importedRenderedImage: true,
            importedRAW: true,
            isMetadataLoaded: false
        )
        let labels = store.labelSnapshot(for: [importedGroup])
        #expect(labels.photoIDByGroupID[importedGroup.id] == "photo-imported")
        #expect(labels.labels.map(\.id) == ["label-baseline"])
        #expect(labels.labelsByPhotoID["photo-imported"]?.map(\.id) == ["label-baseline"])

        #expect(store.libraryAssetStatus(for: libraryRendered))
        let libraryRenderedRecord = try #require(store.contentRecord(for: libraryRendered, variant: .renderedImage))
        #expect(libraryRenderedRecord.sha256 == libraryRenderedHash)
        #expect(libraryRenderedRecord.fileSize == Int64(Data("library-rendered".utf8).count))
        let libraryRawRecord = try #require(store.contentRecord(for: libraryRaw, variant: .raw))
        #expect(libraryRawRecord.sha256 == libraryRawHash)
        #expect(libraryRawRecord.fileSize == Int64(Data("library-raw".utf8).count))
        let inspection = try store.inspectLibrary()
        #expect(inspection.summary.unregisteredPhotoCount == 0)
    }

    private func createBaselineV3Fixture(
        at catalogURL: URL,
        importedRendered: URL,
        importedRaw: URL,
        importedRenderedHash: String,
        importedRawHash: String,
        libraryRendered: URL,
        libraryRaw: URL,
        libraryRenderedHash: String,
        libraryRawHash: String
    ) throws {
        let schema = """
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
        let renderedSourceKey = "volume:fixture-volume:DCIM/100/IMG_0001:JPG"
        let rawSourceKey = "volume:fixture-volume:DCIM/100/IMG_0001:CR3"
        let now = "1700000000.0"
        let sql = schema + """
        CREATE INDEX IF NOT EXISTS imported_files_volume_relative_idx ON imported_files(source_volume_uuid, source_relative_path, variant);
        CREATE INDEX IF NOT EXISTS imported_files_size_filename_idx ON imported_files(file_size, source_filename_key);
        CREATE INDEX IF NOT EXISTS library_assets_size_filename_idx ON library_assets(file_size, filename_key);
        CREATE INDEX IF NOT EXISTS imported_files_sha256_idx ON imported_files(sha256) WHERE sha256 <> '';
        CREATE INDEX IF NOT EXISTS library_assets_sha256_idx ON library_assets(sha256) WHERE sha256 <> '';
        INSERT INTO catalog_meta(key, value) VALUES ('schema_version', '3');
        INSERT INTO library_photos(photo_id, relative_stem) VALUES
          ('photo-imported', 'Imported/IMG_0001'),
          ('photo-library', 'Library/IMG_0002');
        INSERT INTO labels(label_id, name, normalized_name, color_hex, sort_order, last_used_at)
          VALUES ('label-baseline', 'Baseline', 'baseline', '#123456', 0, NULL);
        INSERT INTO photo_labels(photo_id, label_id) VALUES ('photo-imported', 'label-baseline');
        INSERT INTO imported_files(
          source_key, variant, photo_id, source_volume_uuid, source_relative_path,
          source_filename, source_filename_key, destination_path, sha256, file_size,
          imported_at, last_verified_at, file_state
        ) VALUES
          (\(sqlLiteral(renderedSourceKey)), 'JPG', 'photo-imported', 'fixture-volume', 'DCIM/100/IMG_0001',
           'IMG_0001.JPG', 'img_0001.jpg', \(sqlLiteral(importedRendered.standardizedFileURL.path)), '\(importedRenderedHash)', \(Data("baseline-rendered".utf8).count), \(now), \(now), 'present'),
          (\(sqlLiteral(rawSourceKey)), 'CR3', 'photo-imported', 'fixture-volume', 'DCIM/100/IMG_0001',
           'IMG_0001.CR3', 'img_0001.cr3', \(sqlLiteral(importedRaw.standardizedFileURL.path)), '\(importedRawHash)', \(Data("baseline-raw".utf8).count), \(now), \(now), 'present');
        INSERT INTO library_assets(
          asset_key, variant, photo_id, path, filename_key, sha256, file_size, registered_at, last_verified_at
        ) VALUES
          (\(sqlLiteral("library:\(libraryRendered.standardizedFileURL.path):JPG")), 'JPG', 'photo-library', \(sqlLiteral(libraryRendered.standardizedFileURL.path)), 'img_0002.jpg', '\(libraryRenderedHash)', \(Data("library-rendered".utf8).count), \(now), \(now)),
          (\(sqlLiteral("library:\(libraryRaw.standardizedFileURL.path):CR3")), 'CR3', 'photo-library', \(sqlLiteral(libraryRaw.standardizedFileURL.path)), 'img_0002.cr3', '\(libraryRawHash)', \(Data("library-raw".utf8).count), \(now), \(now));
        """
        try execute(sql, at: catalogURL)
    }

    private func hash(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sqlLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "PhotokichinCatalogFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "PhotokichinCatalogFixture", code: 2)
        }
    }

    private func queryText(_ sql: String, at url: URL) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "PhotokichinCatalogFixture", code: 3)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "PhotokichinCatalogFixture", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }
}
