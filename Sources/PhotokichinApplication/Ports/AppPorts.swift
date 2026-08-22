import Foundation
import Synchronization
import PhotokichinDomain

package final class ImportCancellationToken: Sendable {
    private let cancelled = Mutex(false)

    package init() {}

    package var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    package func cancel() {
        cancelled.withLock { $0 = true }
    }

    package func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

package struct TrashBatchResult: Sendable {
    package let completedGroupIDs: Set<String>
    package let movedFileCount: Int
    package let failedFileCount: Int
    package let errorMessage: String?

    package init(completedGroupIDs: Set<String>, movedFileCount: Int, failedFileCount: Int, errorMessage: String?) {
        self.completedGroupIDs = completedGroupIDs
        self.movedFileCount = movedFileCount
        self.failedFileCount = failedFileCount
        self.errorMessage = errorMessage
    }
}

package protocol AirDropSessionHandling: AnyObject {}

package protocol CatalogRepository: Sendable {
    var catalogURL: URL { get }
    var catalogDirectoryURL: URL { get }

    func isImported(sourceKey: String, variant: AssetVariant, legacySourceKey: String?) -> Bool
    func importedDestination(sourceKey: String, variant: AssetVariant, legacySourceKey: String?) -> URL?
    func libraryAssetStatus(for url: URL) -> Bool
    func contentRecord(for url: URL, variant: AssetVariant) -> CatalogContentRecord?
    func matchCandidates(sourceFilenameKey: String?, fileSize: Int64, variant: AssetVariant) -> [CatalogMatchCandidate]
    func existingContentDestination(sha256: String, variant: AssetVariant, fileSize: Int64) -> URL?
    func recordLibraryAsset(url: URL, variant: AssetVariant, sha256: String, fileSize: Int64, preferredPhotoID: String?) throws
    func recordImports(_ records: [CatalogImportRecord]) throws
    func registerLibraryAssets(_ groups: [PhotoGroup]) throws
    func inspectLibrary() throws -> CatalogInspectionResult
    func findCandidates(for issue: CatalogIssue, in root: URL) throws -> [URL]
    func relink(issueID: Int64, to candidateURL: URL) throws
    func forget(issueID: Int64) throws
    func issues() -> [CatalogIssue]
    func summary() -> CatalogSummary
    func integrityReport() -> String
    func backup(to destinationURL: URL) throws
    func migrateSourceIdentities(groups: [PhotoGroup], sourceRoot: URL, volumeUUID: String) throws -> SourceIdentityMigrationResult
    func labelSnapshot(for groups: [PhotoGroup]) -> LabelCatalogSnapshot
    func createLabel(name: String, colorHex: String) throws -> PhotoLabel
    func updateLabel(_ label: PhotoLabel) throws
    func deleteLabel(id: String) throws
    func mergeLabel(sourceID: String, destinationID: String) throws
    func setLabel(_ labelID: String, on photoIDs: [String], assigned: Bool) throws
    func saveLabelView(name: String, labelIDs: [String]) throws -> SavedLabelView
    func deleteSavedLabelView(id: String) throws
    func transferredLabels(for photoID: String) -> [TransferredLabel]
    func applyTransferredLabels(_ transferred: [TransferredLabel], to photoID: String) throws
    func photoID(for url: URL) -> String?
}

package protocol CatalogRepositoryFactory: Sendable {
    func open(libraryRoot: URL) throws -> any CatalogRepository
}

package protocol PhotoScanning: Sendable {
    func scan(
        root: URL,
        initialPresentationBatchSize: Int,
        initialPresentationGroupTarget: Int,
        progress: (@Sendable ([PhotoGroup], Int) -> Void)?
    ) -> [PhotoGroup]
}

package protocol MediaReading: Sendable {
    func readMetadata(url: URL) -> PhotoMetadata?
    func thumbnailData(url: URL, maxPixel: Int) -> Data?
}

package protocol FileTransferring: Sendable {
    func importGroup(
        _ group: PhotoGroup,
        to libraryRoot: URL,
        template: String,
        catalog: any CatalogRepository,
        cancellation: ImportCancellationToken?,
        sourceRoot: URL?,
        volumeUUID: String?
    ) throws -> ImportResult

    func installCameraDownloadedFile(
        partialURL: URL,
        destinationURL: URL,
        variant: AssetVariant,
        sourceKey: String,
        sourceFilename: String?,
        catalog: any CatalogRepository,
        expectedFileSize: Int64,
        cancellation: ImportCancellationToken?
    ) throws -> Bool

    func copyLibraryGroup(
        _ group: PhotoGroup,
        from sourceLibrary: URL,
        to destinationLibrary: URL,
        sourceCatalog: (any CatalogRepository)?,
        destinationCatalog: any CatalogRepository,
        copyLabels: Bool,
        cancellation: ImportCancellationToken?
    ) throws -> ImportResult

    func moveGroupsToTrash(
        _ groups: [PhotoGroup],
        onProgress: (@Sendable (Int, Int, Int, Int) -> Void)?
    ) async -> TrashBatchResult

    func airDrop(
        _ groups: [PhotoGroup],
        mode: AirDropMode,
        onCompletion: @escaping @Sendable (Error?) -> Void
    ) throws -> any AirDropSessionHandling

    func urlsForAirDrop(_ groups: [PhotoGroup], mode: AirDropMode) -> [URL]
    func sourceKey(for group: PhotoGroup, variant: AssetVariant, sourceRoot: URL?, volumeUUID: String?) -> String
    func makeFolderName(template: String, date: Date, camera: String) -> String
}

@MainActor
package protocol VolumeMonitoring: AnyObject {
    var volumes: [MountedVolume] { get }
    func events() -> AsyncStream<VolumeEvent>
    func refresh()
}

package enum VolumeEvent: Sendable {
    case mounted(MountedVolume)
    case unmounted(URL)
}

package protocol VolumeEjecting: Sendable {
    func eject(volumeURL: URL) async throws
}

@MainActor
package protocol CameraMonitoring: AnyObject, Sendable {
    func events() -> AsyncStream<CameraEvent>
    func start()
    func descriptor(for id: String) -> CameraDescriptor?
    func groups(for id: String) -> [PhotoGroup]?
    func catalogSourceKey(for group: PhotoGroup, variant: AssetVariant) -> String
    func eject(id: String) async throws
    func download(group: PhotoGroup, variant: AssetVariant, to directory: URL, filename: String?) async throws -> URL
    func delete(group: PhotoGroup, variant: AssetVariant) async throws
    func requestMetadata(for group: PhotoGroup) async -> PhotoMetadata?
    func requestThumbnailData(for group: PhotoGroup, maxPixel: Int) async -> Data?
}

package enum CameraEvent: Sendable {
    case ready(CameraDescriptor, [PhotoGroup])
    case catalogUpdated(CameraDescriptor, [PhotoGroup])
    case removed(String)
    case camerasChanged([CameraDescriptor])
    case failed(String)
}

package enum CameraSourceLocation {
    package static func url(for cameraID: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safeID = cameraID.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
        return URL(fileURLWithPath: "/__photokichin_camera__")
            .appendingPathComponent(safeID, isDirectory: true)
    }

    package static func catalogKey(cameraID: String, groupKey: String, variant: AssetVariant) -> String {
        "camera:\(cameraID):\(groupKey):\(variant.rawValue)"
    }
}
