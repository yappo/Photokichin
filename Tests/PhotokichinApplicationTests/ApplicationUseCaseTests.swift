import Foundation
import Synchronization
import Testing
@testable import PhotokichinApplication
@testable import PhotokichinDomain

private func objectID(_ value: AnyObject) -> ObjectIdentifier {
    ObjectIdentifier(value)
}

private struct ScanCall: Sendable {
    let root: URL
    let initialPresentationBatchSize: Int
    let initialPresentationGroupTarget: Int
    let progressWasProvided: Bool
}

private final class ScannerSpy: PhotoScanning, Sendable {
    let groups: [PhotoGroup]
    private let recordedCall = Mutex<ScanCall?>(nil)

    init(groups: [PhotoGroup]) {
        self.groups = groups
    }

    var call: ScanCall? { recordedCall.withLock { $0 } }

    func scan(
        root: URL,
        initialPresentationBatchSize: Int,
        initialPresentationGroupTarget: Int,
        progress: (@Sendable ([PhotoGroup], Int) -> Void)?
    ) -> [PhotoGroup] {
        recordedCall.withLock {
            $0 = ScanCall(
                root: root,
                initialPresentationBatchSize: initialPresentationBatchSize,
                initialPresentationGroupTarget: initialPresentationGroupTarget,
                progressWasProvided: progress != nil
            )
        }
        progress?(groups, groups.count)
        return groups
    }
}

private final class GroupProgressRecorder: Sendable {
    private struct State: Sendable {
        var groupIDs: [String] = []
        var total = 0
    }
    private let state = Mutex(State())

    var groupIDs: [String] { state.withLock { $0.groupIDs } }
    var total: Int { state.withLock { $0.total } }

    func record(_ groups: [PhotoGroup], _ total: Int) {
        state.withLock {
            $0.groupIDs = groups.map(\.id)
            $0.total = total
        }
    }
}

private enum UseCaseTestError: Error, Equatable { case expected }

private final class CatalogSpy: CatalogRepository, Sendable {
    let catalogURL = URL(fileURLWithPath: "/tmp/application-catalog.sqlite")
    let catalogDirectoryURL = URL(fileURLWithPath: "/tmp/application-catalog")
    private let recordedImports = Mutex<[CatalogImportRecord]>([])

    var objectIdentifier: ObjectIdentifier { objectID(self) }

    func isImported(sourceKey: String, variant: AssetVariant, legacySourceKey: String?) -> Bool { false }
    func importedDestination(sourceKey: String, variant: AssetVariant, legacySourceKey: String?) -> URL? { nil }
    func libraryAssetStatus(for url: URL) -> Bool { false }
    func contentRecord(for url: URL, variant: AssetVariant) -> CatalogContentRecord? { nil }
    func matchCandidates(sourceFilenameKey: String?, fileSize: Int64, variant: AssetVariant) -> [CatalogMatchCandidate] { [] }
    func existingContentDestination(sha256: String, variant: AssetVariant, fileSize: Int64) -> URL? { nil }
    func recordLibraryAsset(url: URL, variant: AssetVariant, sha256: String, fileSize: Int64, preferredPhotoID: String?) throws {}
    func recordImports(_ records: [CatalogImportRecord]) throws { recordedImports.withLock { $0 += records } }
    func registerLibraryAssets(_ groups: [PhotoGroup]) throws {}
    func inspectLibrary() throws -> CatalogInspectionResult { CatalogInspectionResult(summary: summary(), issues: []) }
    func findCandidates(for issue: CatalogIssue, in root: URL) throws -> [URL] { [] }
    func relink(issueID: Int64, to candidateURL: URL) throws {}
    func forget(issueID: Int64) throws {}
    func issues() -> [CatalogIssue] { [] }
    func summary() -> CatalogSummary {
        CatalogSummary(
            catalogURL: catalogURL,
            catalogSize: 0,
            lastInspectionAt: nil,
            importedFileCount: recordedImports.withLock { $0.count },
            registeredAssetCount: 0,
            unregisteredPhotoCount: 0,
            missingCount: 0,
            candidateCount: 0,
            conflictCount: 0
        )
    }
    func integrityReport() -> String { "ok" }
    func backup(to destinationURL: URL) throws {}
    func migrateSourceIdentities(groups: [PhotoGroup], sourceRoot: URL, volumeUUID: String) throws -> SourceIdentityMigrationResult { SourceIdentityMigrationResult(migratedCount: 0, conflictCount: 0, backupURL: nil) }
    func labelSnapshot(for groups: [PhotoGroup]) -> LabelCatalogSnapshot { LabelCatalogSnapshot(labels: [], savedViews: [], photoIDByGroupID: [:], labelsByPhotoID: [:]) }
    func createLabel(name: String, colorHex: String) throws -> PhotoLabel { PhotoLabel(id: "label", name: name, normalizedName: name, colorHex: colorHex, sortOrder: 0) }
    func updateLabel(_ label: PhotoLabel) throws {}
    func deleteLabel(id: String) throws {}
    func mergeLabel(sourceID: String, destinationID: String) throws {}
    func setLabel(_ labelID: String, on photoIDs: [String], assigned: Bool) throws {}
    func saveLabelView(name: String, labelIDs: [String]) throws -> SavedLabelView { SavedLabelView(id: "view", name: name, labelIDs: labelIDs, sortOrder: 0) }
    func deleteSavedLabelView(id: String) throws {}
    func transferredLabels(for photoID: String) -> [TransferredLabel] { [] }
    func applyTransferredLabels(_ transferred: [TransferredLabel], to photoID: String) throws {}
    func photoID(for url: URL) -> String? { nil }
}

private struct ImportCall: Sendable {
    let groupID: String
    let libraryRoot: URL
    let template: String
    let catalogID: ObjectIdentifier
    let cancellationID: ObjectIdentifier?
    let sourceRoot: URL?
    let volumeUUID: String?
}

private struct InstallCall: Sendable {
    let partialURL: URL
    let destinationURL: URL
    let variant: AssetVariant
    let sourceKey: String
    let sourceFilename: String?
    let catalogID: ObjectIdentifier
    let expectedFileSize: Int64
    let cancellationID: ObjectIdentifier?
}

private struct CopyCall: Sendable {
    let groupID: String
    let sourceLibrary: URL
    let destinationLibrary: URL
    let sourceCatalogID: ObjectIdentifier?
    let destinationCatalogID: ObjectIdentifier
    let copyLabels: Bool
    let cancellationID: ObjectIdentifier?
}

private struct DeleteCall: Sendable {
    let groupIDs: [String]
    let progressWasProvided: Bool
}

private struct ShareCall: Sendable {
    let groupIDs: [String]
    let mode: AirDropMode
}

private struct SourceKeyCall: Sendable {
    let groupID: String
    let variant: AssetVariant
    let sourceRoot: URL?
    let volumeUUID: String?
}

private struct FolderNameCall: Sendable {
    let template: String
    let date: Date
    let camera: String
}

private final class TransferSpy: FileTransferring, Sendable {
    private struct State: Sendable {
        var importCalls: [ImportCall] = []
        var installCalls: [InstallCall] = []
        var copyCalls: [CopyCall] = []
        var deleteCalls: [DeleteCall] = []
        var shareCalls: [ShareCall] = []
        var sourceKeyCalls: [SourceKeyCall] = []
        var folderNameCalls: [FolderNameCall] = []
        var shouldThrow = false
    }
    private let state = Mutex(State())

    var importCalls: [ImportCall] { state.withLock { $0.importCalls } }
    var installCalls: [InstallCall] { state.withLock { $0.installCalls } }
    var copyCalls: [CopyCall] { state.withLock { $0.copyCalls } }
    var deleteCalls: [DeleteCall] { state.withLock { $0.deleteCalls } }
    var shareCalls: [ShareCall] { state.withLock { $0.shareCalls } }
    var sourceKeyCalls: [SourceKeyCall] { state.withLock { $0.sourceKeyCalls } }
    var folderNameCalls: [FolderNameCall] { state.withLock { $0.folderNameCalls } }
    var shouldThrow: Bool {
        get { state.withLock { $0.shouldThrow } }
        set { state.withLock { $0.shouldThrow = newValue } }
    }

    func importGroup(
        _ group: PhotoGroup,
        to libraryRoot: URL,
        template: String,
        catalog: any CatalogRepository,
        cancellation: ImportCancellationToken?,
        sourceRoot: URL?,
        volumeUUID: String?
    ) throws -> ImportResult {
        state.withLock {
            $0.importCalls.append(ImportCall(
                groupID: group.id,
                libraryRoot: libraryRoot,
                template: template,
                catalogID: objectID(catalog as AnyObject),
                cancellationID: cancellation.map { objectID($0) },
                sourceRoot: sourceRoot,
                volumeUUID: volumeUUID
            ))
        }
        if shouldThrow { throw UseCaseTestError.expected }
        try cancellation?.check()
        return ImportResult(groupID: group.id, message: "imported", copiedCount: 1, skippedCount: 0, failedCount: 0)
    }

    func installCameraDownloadedFile(
        partialURL: URL,
        destinationURL: URL,
        variant: AssetVariant,
        sourceKey: String,
        sourceFilename: String?,
        catalog: any CatalogRepository,
        expectedFileSize: Int64,
        cancellation: ImportCancellationToken?
    ) throws -> Bool {
        state.withLock {
            $0.installCalls.append(InstallCall(
                partialURL: partialURL,
                destinationURL: destinationURL,
                variant: variant,
                sourceKey: sourceKey,
                sourceFilename: sourceFilename,
                catalogID: objectID(catalog as AnyObject),
                expectedFileSize: expectedFileSize,
                cancellationID: cancellation.map { objectID($0) }
            ))
        }
        if shouldThrow { throw UseCaseTestError.expected }
        try cancellation?.check()
        return true
    }

    func copyLibraryGroup(
        _ group: PhotoGroup,
        from sourceLibrary: URL,
        to destinationLibrary: URL,
        sourceCatalog: (any CatalogRepository)?,
        destinationCatalog: any CatalogRepository,
        copyLabels: Bool,
        cancellation: ImportCancellationToken?
    ) throws -> ImportResult {
        state.withLock {
            $0.copyCalls.append(CopyCall(
                groupID: group.id,
                sourceLibrary: sourceLibrary,
                destinationLibrary: destinationLibrary,
                sourceCatalogID: sourceCatalog.map { objectID($0 as AnyObject) },
                destinationCatalogID: objectID(destinationCatalog as AnyObject),
                copyLabels: copyLabels,
                cancellationID: cancellation.map { objectID($0) }
            ))
        }
        if shouldThrow { throw UseCaseTestError.expected }
        try cancellation?.check()
        return ImportResult(groupID: group.id, message: "copied", copiedCount: 1, skippedCount: 0, failedCount: 0)
    }

    func moveGroupsToTrash(
        _ groups: [PhotoGroup],
        onProgress: (@Sendable (Int, Int, Int, Int) -> Void)?
    ) async -> TrashBatchResult {
        state.withLock {
            $0.deleteCalls.append(DeleteCall(groupIDs: groups.map(\.id), progressWasProvided: onProgress != nil))
        }
        onProgress?(1, groups.count, 1, groups.count)
        return TrashBatchResult(completedGroupIDs: Set(groups.map(\.id)), movedFileCount: groups.count, failedFileCount: 0, errorMessage: nil)
    }

    func airDrop(
        _ groups: [PhotoGroup],
        mode: AirDropMode,
        onCompletion: @escaping @Sendable (Error?) -> Void
    ) throws -> any AirDropSessionHandling {
        state.withLock { $0.shareCalls.append(ShareCall(groupIDs: groups.map(\.id), mode: mode)) }
        if shouldThrow { throw UseCaseTestError.expected }
        onCompletion(nil)
        return AirDropSpy()
    }

    func urlsForAirDrop(_ groups: [PhotoGroup], mode: AirDropMode) -> [URL] { [] }

    func sourceKey(for group: PhotoGroup, variant: AssetVariant, sourceRoot: URL?, volumeUUID: String?) -> String {
        state.withLock { $0.sourceKeyCalls.append(SourceKeyCall(groupID: group.id, variant: variant, sourceRoot: sourceRoot, volumeUUID: volumeUUID)) }
        return "source-key"
    }

    func makeFolderName(template: String, date: Date, camera: String) -> String {
        state.withLock { $0.folderNameCalls.append(FolderNameCall(template: template, date: date, camera: camera)) }
        return "folder"
    }
}

private final class AirDropSpy: AirDropSessionHandling {}

private final class CatalogFactorySpy: CatalogRepositoryFactory, Sendable {
    let catalog: CatalogSpy
    private struct State: Sendable {
        var libraryRoots: [URL] = []
        var shouldThrow = false
    }
    private let state = Mutex(State())

    init(catalog: CatalogSpy) {
        self.catalog = catalog
    }

    var libraryRoots: [URL] { state.withLock { $0.libraryRoots } }
    var shouldThrow: Bool {
        get { state.withLock { $0.shouldThrow } }
        set { state.withLock { $0.shouldThrow = newValue } }
    }

    func open(libraryRoot: URL) throws -> any CatalogRepository {
        state.withLock { $0.libraryRoots.append(libraryRoot) }
        if shouldThrow { throw UseCaseTestError.expected }
        return catalog
    }
}

private struct EjectorSpy: VolumeEjecting {
    let recorder: EjectRecorder
    var shouldThrow = false

    func eject(volumeURL: URL) async throws {
        if shouldThrow { throw UseCaseTestError.expected }
        recorder.append(volumeURL)
    }
}

private final class EjectRecorder: Sendable {
    private let storage = Mutex<[URL]>([])
    var urls: [URL] { storage.withLock { $0 } }
    func append(_ url: URL) { storage.withLock { $0.append(url) } }
}

private final class ProgressRecorder: Sendable {
    struct ProgressValue: Sendable, Equatable {
        let completedGroups: Int
        let totalGroups: Int
        let completedFiles: Int
        let totalFiles: Int
    }
    private struct State: Sendable {
        var values: [ProgressValue] = []
        var completionSuccess: [Bool] = []
    }
    private let storage = Mutex(State())
    var values: [ProgressValue] { storage.withLock { $0.values } }
    var completionSuccess: [Bool] { storage.withLock { $0.completionSuccess } }

    func append(_ value: (Int, Int, Int, Int)) {
        storage.withLock {
            $0.values.append(ProgressValue(completedGroups: value.0, totalGroups: value.1, completedFiles: value.2, totalFiles: value.3))
        }
    }
    func recordCompletion(_ error: Error?) { storage.withLock { $0.completionSuccess.append(error == nil) } }
}

@Suite("Application use cases")
struct ApplicationUseCaseTests {
    @Test("Browse delegates root, batch settings, target, and progress values")
    func browseDelegatesAllArgumentsAndProgress() {
        let root = URL(fileURLWithPath: "/tmp/application-browse-fixture")
        let group = makeGroup(id: "browse")
        let scanner = ScannerSpy(groups: [group])
        let progress = GroupProgressRecorder()
        let result = BrowsePhotosUseCase(scanner: scanner).execute(
            root: root,
            initialPresentationBatchSize: 7,
            initialPresentationGroupTarget: 11,
            progress: { progress.record($0, $1) }
        )

        #expect(result.map(\.id) == [group.id])
        #expect(scanner.call?.root == root)
        #expect(scanner.call?.initialPresentationBatchSize == 7)
        #expect(scanner.call?.initialPresentationGroupTarget == 11)
        #expect(scanner.call?.progressWasProvided == true)
        #expect(progress.groupIDs == [group.id])
        #expect(progress.total == 1)
    }

    @Test("Cancellation token reports cancellation")
    func cancellation() {
        let token = ImportCancellationToken()
        #expect(!token.isCancelled)
        token.cancel()
        #expect(token.isCancelled)
        #expect(throws: CancellationError.self) { try token.check() }
    }

    @Test("OpenCatalog delegates the library root and returns the repository")
    func openCatalogDelegatesAndReturnsCatalog() throws {
        let catalog = CatalogSpy()
        let factory = CatalogFactorySpy(catalog: catalog)
        let root = URL(fileURLWithPath: "/tmp/open-catalog-success")
        let result = try OpenCatalogUseCase(factory: factory).execute(libraryRoot: root)

        #expect(factory.libraryRoots == [root])
        #expect(result.catalogURL == catalog.catalogURL)
        #expect(objectID(result as AnyObject) == catalog.objectIdentifier)
    }

    @Test("OpenCatalog propagates factory errors")
    func openCatalogPropagatesErrors() {
        let factory = CatalogFactorySpy(catalog: CatalogSpy())
        factory.shouldThrow = true
        #expect(throws: UseCaseTestError.expected) {
            try OpenCatalogUseCase(factory: factory).execute(libraryRoot: URL(fileURLWithPath: "/tmp/open-catalog-error"))
        }
    }

    @Test("Import delegates every import argument and returns the transfer result")
    func importDelegatesAllArguments() throws {
        let transfer = TransferSpy()
        let catalog = CatalogSpy()
        let token = ImportCancellationToken()
        let group = makeGroup(id: "import-success")
        let libraryRoot = URL(fileURLWithPath: "/tmp/import-destination")
        let sourceRoot = URL(fileURLWithPath: "/tmp/import-source")
        let result = try ImportPhotosUseCase(transfer: transfer).execute(
            group,
            to: libraryRoot,
            template: "{date}_{camera}",
            catalog: catalog,
            cancellation: token,
            sourceRoot: sourceRoot,
            volumeUUID: "volume-123"
        )

        let call = try #require(transfer.importCalls.first)
        #expect(result.groupID == group.id)
        #expect(call.groupID == group.id)
        #expect(call.libraryRoot == libraryRoot)
        #expect(call.template == "{date}_{camera}")
        #expect(call.catalogID == catalog.objectIdentifier)
        #expect(call.cancellationID == objectID(token))
        #expect(call.sourceRoot == sourceRoot)
        #expect(call.volumeUUID == "volume-123")
    }

    @Test("Import propagates cancellation from the transfer boundary")
    func importPropagatesCancellation() {
        let transfer = TransferSpy()
        let token = ImportCancellationToken()
        token.cancel()
        let group = makeGroup(id: "import-cancel")
        #expect(throws: CancellationError.self) {
            try ImportPhotosUseCase(transfer: transfer).execute(
                group,
                to: URL(fileURLWithPath: "/tmp/import-cancel"),
                template: "template",
                catalog: CatalogSpy(),
                cancellation: token,
                sourceRoot: nil,
                volumeUUID: nil
            )
        }
        #expect(transfer.importCalls.first?.cancellationID == objectID(token))
    }

    @Test("Import propagates transfer errors")
    func importPropagatesErrors() {
        let transfer = TransferSpy()
        transfer.shouldThrow = true
        #expect(throws: UseCaseTestError.expected) {
            try ImportPhotosUseCase(transfer: transfer).execute(
                makeGroup(id: "import-error"),
                to: URL(fileURLWithPath: "/tmp/import-error"),
                template: "template",
                catalog: CatalogSpy(),
                cancellation: nil,
                sourceRoot: nil,
                volumeUUID: nil
            )
        }
    }

    @Test("InstallDownloadedFile delegates every camera install argument")
    func installDownloadedFileDelegatesAllArguments() throws {
        let transfer = TransferSpy()
        let catalog = CatalogSpy()
        let token = ImportCancellationToken()
        let partial = URL(fileURLWithPath: "/tmp/partial-download")
        let destination = URL(fileURLWithPath: "/tmp/installed-download.CR3")
        let installed = try ImportPhotosUseCase(transfer: transfer).installDownloadedFile(
            partialURL: partial,
            destinationURL: destination,
            variant: .raw,
            sourceKey: "camera:test:IMG.CR3",
            sourceFilename: "IMG.CR3",
            catalog: catalog,
            expectedFileSize: 1234,
            cancellation: token
        )

        let call = try #require(transfer.installCalls.first)
        #expect(installed)
        #expect(call.partialURL == partial)
        #expect(call.destinationURL == destination)
        #expect(call.variant == .raw)
        #expect(call.sourceKey == "camera:test:IMG.CR3")
        #expect(call.sourceFilename == "IMG.CR3")
        #expect(call.catalogID == catalog.objectIdentifier)
        #expect(call.expectedFileSize == 1234)
        #expect(call.cancellationID == objectID(token))
    }

    @Test("Import sourceKey delegates group, variant, source root, and volume UUID")
    func sourceKeyDelegatesAllArguments() {
        let transfer = TransferSpy()
        let group = makeGroup(id: "source-key")
        let root = URL(fileURLWithPath: "/tmp/source-key-root")
        let result = ImportPhotosUseCase(transfer: transfer).sourceKey(
            for: group,
            variant: .jpeg,
            sourceRoot: root,
            volumeUUID: "volume-source-key"
        )

        let call = transfer.sourceKeyCalls.first
        #expect(result == "source-key")
        #expect(call?.groupID == group.id)
        #expect(call?.variant == .jpeg)
        #expect(call?.sourceRoot == root)
        #expect(call?.volumeUUID == "volume-source-key")
    }

    @Test("Import folderName delegates template, date, and camera")
    func folderNameDelegatesAllArguments() {
        let transfer = TransferSpy()
        let date = Date(timeIntervalSince1970: 123)
        let result = ImportPhotosUseCase(transfer: transfer).folderName(template: "{date}_{camera}", date: date, camera: "EOS R")
        let call = transfer.folderNameCalls.first
        #expect(result == "folder")
        #expect(call?.template == "{date}_{camera}")
        #expect(call?.date == date)
        #expect(call?.camera == "EOS R")
    }

    @Test("Copy delegates group, catalogs, libraries, labels, and cancellation")
    func copyDelegatesAllArguments() throws {
        let transfer = TransferSpy()
        let sourceCatalog = CatalogSpy()
        let destinationCatalog = CatalogSpy()
        let token = ImportCancellationToken()
        let group = makeGroup(id: "copy-success")
        let source = URL(fileURLWithPath: "/tmp/source-library")
        let destination = URL(fileURLWithPath: "/tmp/destination-library")
        let result = try CopyPhotosUseCase(transfer: transfer).execute(
            group,
            from: source,
            to: destination,
            sourceCatalog: sourceCatalog,
            destinationCatalog: destinationCatalog,
            copyLabels: true,
            cancellation: token
        )

        let call = try #require(transfer.copyCalls.first)
        #expect(result.groupID == group.id)
        #expect(call.groupID == group.id)
        #expect(call.sourceLibrary == source)
        #expect(call.destinationLibrary == destination)
        #expect(call.sourceCatalogID == sourceCatalog.objectIdentifier)
        #expect(call.destinationCatalogID == destinationCatalog.objectIdentifier)
        #expect(call.copyLabels)
        #expect(call.cancellationID == objectID(token))
    }

    @Test("Copy propagates transfer errors")
    func copyPropagatesErrors() {
        let transfer = TransferSpy()
        transfer.shouldThrow = true
        #expect(throws: UseCaseTestError.expected) {
            try CopyPhotosUseCase(transfer: transfer).execute(
                makeGroup(id: "copy-error"),
                from: URL(fileURLWithPath: "/tmp/source-error"),
                to: URL(fileURLWithPath: "/tmp/destination-error"),
                sourceCatalog: nil,
                destinationCatalog: CatalogSpy(),
                copyLabels: false,
                cancellation: nil
            )
        }
    }

    @Test("Delete delegates every group, forwards progress, and returns the transfer result")
    func deleteDelegatesGroupsAndProgress() async {
        let transfer = TransferSpy()
        let groups = [makeGroup(id: "delete-one"), makeGroup(id: "delete-two")]
        let progress = ProgressRecorder()
        let result = await DeletePhotosUseCase(transfer: transfer).moveToTrash(groups) { progress.append(($0, $1, $2, $3)) }

        let call = transfer.deleteCalls.first
        #expect(result.completedGroupIDs == Set(groups.map(\.id)))
        #expect(call?.groupIDs == groups.map(\.id))
        #expect(call?.progressWasProvided == true)
        #expect(progress.values == [ProgressRecorder.ProgressValue(completedGroups: 1, totalGroups: 2, completedFiles: 1, totalFiles: 2)])
    }

    @Test("Share delegates groups, mode, completion, and session result")
    func shareDelegatesAllArguments() throws {
        let transfer = TransferSpy()
        let groups = [makeGroup(id: "share-one"), makeGroup(id: "share-two")]
        let completion = ProgressRecorder()
        let session = try SharePhotosUseCase(transfer: transfer).execute(groups, mode: .jpegOnly) { completion.recordCompletion($0) }

        let call = try #require(transfer.shareCalls.first)
        #expect(call.groupIDs == groups.map(\.id))
        #expect(call.mode == .jpegOnly)
        #expect(session is AirDropSpy)
        #expect(completion.completionSuccess == [true])
    }

    @Test("Share propagates transfer errors")
    func sharePropagatesErrors() {
        let transfer = TransferSpy()
        transfer.shouldThrow = true
        #expect(throws: UseCaseTestError.expected) {
            try SharePhotosUseCase(transfer: transfer).execute([], mode: .rawOnly) { _ in }
        }
    }

    @Test("Eject delegates the volume URL and completes successfully")
    func ejectDelegatesVolumeURL() async throws {
        let recorder = EjectRecorder()
        let volume = URL(fileURLWithPath: "/Volumes/test-card")
        try await EjectVolumeUseCase(ejector: EjectorSpy(recorder: recorder)).execute(volumeURL: volume)
        #expect(recorder.urls == [volume])
    }

    @Test("Eject propagates ejector errors")
    func ejectPropagatesErrors() async {
        let recorder = EjectRecorder()
        await #expect(throws: UseCaseTestError.expected) {
            try await EjectVolumeUseCase(ejector: EjectorSpy(recorder: recorder, shouldThrow: true)).execute(volumeURL: URL(fileURLWithPath: "/Volumes/eject-error"))
        }
        #expect(recorder.urls.isEmpty)
    }

    private func makeGroup(id: String) -> PhotoGroup {
        let root = URL(fileURLWithPath: "/tmp/application-\(id)")
        return PhotoGroup(
            id: id,
            basename: "IMG_\(id)",
            directory: root,
            jpegURL: root.appendingPathComponent("IMG_\(id).JPG"),
            rawURL: nil,
            movieURL: nil,
            captureDate: nil,
            metadata: .empty,
            importedJPEG: false,
            importedRAW: false,
            isMetadataLoaded: true
        )
    }
}
