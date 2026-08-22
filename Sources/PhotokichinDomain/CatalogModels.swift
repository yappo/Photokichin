import Foundation

package struct CatalogImportRecord: Sendable {
    package let sourceKey: String
    package let variant: AssetVariant
    package let destinationURL: URL
    package let sha256: String
    package let fileSize: Int64
    package let sourceFilename: String?
    package let sourceFilenameKey: String?
    package let legacySourceKey: String?
    package let sourceVolumeUUID: String?
    package let sourceRelativePath: String?
    package let photoID: String?

    package init(
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

package struct SourceIdentityMigrationResult: Sendable, Equatable {
    package let migratedCount: Int
    package let conflictCount: Int
    package let backupURL: URL?

    package init(migratedCount: Int, conflictCount: Int, backupURL: URL?) {
        self.migratedCount = migratedCount
        self.conflictCount = conflictCount
        self.backupURL = backupURL
    }
}

package struct CatalogIssue: Identifiable, Hashable, Sendable {
    package let id: Int64
    package let sourceKey: String
    package let variant: AssetVariant
    package let issueType: String
    package let lastKnownURL: URL
    package let candidateURL: URL?
    package let expectedSize: Int64
    package let expectedSHA256: String
    package let detectedAt: Date

    package init(
        id: Int64,
        sourceKey: String,
        variant: AssetVariant,
        issueType: String,
        lastKnownURL: URL,
        candidateURL: URL?,
        expectedSize: Int64,
        expectedSHA256: String,
        detectedAt: Date
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.variant = variant
        self.issueType = issueType
        self.lastKnownURL = lastKnownURL
        self.candidateURL = candidateURL
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
        self.detectedAt = detectedAt
    }
}

package struct CatalogSummary: Equatable, Sendable {
    package let catalogURL: URL
    package let catalogSize: Int64
    package let lastInspectionAt: Date?
    package let importedFileCount: Int
    package let registeredAssetCount: Int
    package let unregisteredPhotoCount: Int
    package let missingCount: Int
    package let candidateCount: Int
    package let conflictCount: Int

    package init(
        catalogURL: URL,
        catalogSize: Int64,
        lastInspectionAt: Date?,
        importedFileCount: Int,
        registeredAssetCount: Int,
        unregisteredPhotoCount: Int,
        missingCount: Int,
        candidateCount: Int,
        conflictCount: Int
    ) {
        self.catalogURL = catalogURL
        self.catalogSize = catalogSize
        self.lastInspectionAt = lastInspectionAt
        self.importedFileCount = importedFileCount
        self.registeredAssetCount = registeredAssetCount
        self.unregisteredPhotoCount = unregisteredPhotoCount
        self.missingCount = missingCount
        self.candidateCount = candidateCount
        self.conflictCount = conflictCount
    }
}

package struct CatalogInspectionResult: Sendable {
    package let summary: CatalogSummary
    package let issues: [CatalogIssue]

    package init(summary: CatalogSummary, issues: [CatalogIssue]) {
        self.summary = summary
        self.issues = issues
    }
}

package struct CatalogContentRecord: Sendable {
    package let sha256: String
    package let fileSize: Int64

    package init(sha256: String, fileSize: Int64) {
        self.sha256 = sha256
        self.fileSize = fileSize
    }
}

package struct CatalogMatchCandidate: Sendable, Equatable {
    package let path: URL
    package let variant: AssetVariant
    package let fileSize: Int64
    package let sha256: String
    package let filenameKey: String?

    package init(path: URL, variant: AssetVariant, fileSize: Int64, sha256: String, filenameKey: String?) {
        self.path = path
        self.variant = variant
        self.fileSize = fileSize
        self.sha256 = sha256
        self.filenameKey = filenameKey
    }
}
