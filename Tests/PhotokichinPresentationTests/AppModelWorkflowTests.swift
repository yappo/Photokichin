import Foundation
import Synchronization
import Testing
@testable import PhotokichinDomain
@testable import PhotokichinApplication
@testable import PhotokichinPresentation

@MainActor
private final class TestVolumeMonitor: VolumeMonitoring {
    var volumes: [MountedVolume] = []

    func events() -> AsyncStream<VolumeEvent> { AsyncStream { _ in } }
    func refresh() {}
}

@MainActor
private final class TestCameraMonitor: CameraMonitoring {
    private var continuation: AsyncStream<CameraEvent>.Continuation?

    func events() -> AsyncStream<CameraEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    func start() {}
    func descriptor(for id: String) -> CameraDescriptor? { nil }
    func groups(for id: String) -> [PhotoGroup]? { nil }
    func catalogSourceKey(for group: PhotoGroup, variant: AssetVariant) -> String {
        "camera:test:\(group.id):\(variant.rawValue)"
    }
    func eject(id: String) async throws {}
    func download(
        group: PhotoGroup,
        variant: AssetVariant,
        to directory: URL,
        filename requestedFilename: String?
    ) async throws -> URL {
        throw NSError(
            domain: "PhotokichinTests",
            code: 80,
            userInfo: [NSLocalizedDescriptionKey: "this test camera has no downloadable files"]
        )
    }
    func delete(group: PhotoGroup, variant: AssetVariant) async throws {}
    func requestMetadata(for group: PhotoGroup) async -> PhotoMetadata? { nil }
    func requestThumbnailData(for group: PhotoGroup, maxPixel: Int) async -> Data? { nil }

    func publishReadyCamera(_ descriptor: CameraDescriptor, groups: [PhotoGroup]) {
        continuation?.yield(.ready(descriptor, groups))
    }
}

private final class TestCatalogRepository: CatalogRepository, Sendable {
    let catalogURL: URL
    let catalogDirectoryURL: URL
    private let imports = Mutex<[String: URL]>([:])

    init(libraryRoot: URL) {
        catalogDirectoryURL = libraryRoot
        catalogURL = libraryRoot.appendingPathComponent("catalog.sqlite")
    }

    func isImported(sourceKey: String, variant: AssetVariant, legacySourceKey: String?) -> Bool {
        importedDestination(sourceKey: sourceKey, variant: variant, legacySourceKey: legacySourceKey) != nil
    }
    func importedDestination(sourceKey: String, variant: AssetVariant, legacySourceKey: String?) -> URL? { imports.withLock { $0["\(sourceKey):\(variant.rawValue)"] } }
    func libraryAssetStatus(for url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func contentRecord(for url: URL, variant: AssetVariant) -> CatalogContentRecord? { nil }
    func matchCandidates(sourceFilenameKey: String?, fileSize: Int64, variant: AssetVariant) -> [CatalogMatchCandidate] { [] }
    func existingContentDestination(sha256: String, variant: AssetVariant, fileSize: Int64) -> URL? { nil }
    func recordLibraryAsset(url: URL, variant: AssetVariant, sha256: String, fileSize: Int64, preferredPhotoID: String?) throws {}
    func recordImports(_ records: [CatalogImportRecord]) throws {
        imports.withLock { storage in
            for record in records { storage["\(record.sourceKey):\(record.variant.rawValue)"] = record.destinationURL }
        }
    }
    func registerLibraryAssets(_ groups: [PhotoGroup]) throws {}
    func inspectLibrary() throws -> CatalogInspectionResult { CatalogInspectionResult(summary: summary(), issues: []) }
    func findCandidates(for issue: CatalogIssue, in root: URL) throws -> [URL] { [] }
    func relink(issueID: Int64, to candidateURL: URL) throws {}
    func forget(issueID: Int64) throws {}
    func issues() -> [CatalogIssue] { [] }
    func summary() -> CatalogSummary {
        CatalogSummary(catalogURL: catalogURL, catalogSize: 0, lastInspectionAt: nil, importedFileCount: imports.withLock { $0.count }, registeredAssetCount: 0, unregisteredPhotoCount: 0, missingCount: 0, candidateCount: 0, conflictCount: 0)
    }
    func integrityReport() -> String { "ok" }
    func backup(to destinationURL: URL) throws {}
    func migrateSourceIdentities(groups: [PhotoGroup], sourceRoot: URL, volumeUUID: String) throws -> SourceIdentityMigrationResult { SourceIdentityMigrationResult(migratedCount: 0, conflictCount: 0, backupURL: nil) }
    func labelSnapshot(for groups: [PhotoGroup]) -> LabelCatalogSnapshot { LabelCatalogSnapshot(labels: [], savedViews: [], photoIDByGroupID: [:], labelsByPhotoID: [:]) }
    func createLabel(name: String, colorHex: String) throws -> PhotoLabel { PhotoLabel(id: UUID().uuidString, name: name, normalizedName: name.lowercased(), colorHex: colorHex, sortOrder: 0, lastUsedAt: nil) }
    func updateLabel(_ label: PhotoLabel) throws {}
    func deleteLabel(id: String) throws {}
    func mergeLabel(sourceID: String, destinationID: String) throws {}
    func setLabel(_ labelID: String, on photoIDs: [String], assigned: Bool) throws {}
    func saveLabelView(name: String, labelIDs: [String]) throws -> SavedLabelView { SavedLabelView(id: UUID().uuidString, name: name, labelIDs: labelIDs, sortOrder: 0) }
    func deleteSavedLabelView(id: String) throws {}
    func transferredLabels(for photoID: String) -> [TransferredLabel] { [] }
    func applyTransferredLabels(_ transferred: [TransferredLabel], to photoID: String) throws {}
    func photoID(for url: URL) -> String? { nil }
}

private struct TestCatalogFactory: CatalogRepositoryFactory {
    func open(libraryRoot: URL) throws -> any CatalogRepository {
        TestCatalogRepository(libraryRoot: libraryRoot)
    }
}

private struct TestMediaReader: MediaReading {
    func readMetadata(url: URL) -> PhotoMetadata? { nil }
    func thumbnailData(url: URL, maxPixel: Int) -> Data? { nil }
}

private struct TestScanner: PhotoScanning {
    func scan(root: URL, initialPresentationBatchSize: Int, initialPresentationGroupTarget: Int, progress: (@Sendable ([PhotoGroup], Int) -> Void)?) -> [PhotoGroup] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [String: (URL?, URL?)] = [:]
        for case let url as URL in enumerator {
            guard ["JPG", "CR3"].contains(url.pathExtension.uppercased()) else { continue }
            var entry = files[url.deletingPathExtension().path] ?? (nil, nil)
            if url.pathExtension.uppercased() == "JPG" { entry.0 = url } else { entry.1 = url }
            files[url.deletingPathExtension().path] = entry
        }
        let groups = files.keys.sorted().map { key in
            let value = files[key]!
            return PhotoGroup(id: key, basename: URL(fileURLWithPath: key).lastPathComponent, directory: URL(fileURLWithPath: key).deletingLastPathComponent(), renderedImageURL: value.0, rawURL: value.1, movieURL: nil, captureDate: nil, metadata: .empty, importedRenderedImage: false, importedRAW: false, isMetadataLoaded: false)
        }
        progress?(groups, groups.count)
        return groups
    }
}

private struct TestTransfer: FileTransferring {
    func importGroup(_ group: PhotoGroup, to libraryRoot: URL, template: String, catalog: any CatalogRepository, cancellation: ImportCancellationToken?, sourceRoot: URL?, volumeUUID: String?) throws -> ImportResult {
        try cancellation?.check()
        let destination = libraryRoot.appendingPathComponent("Test Import", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var records: [CatalogImportRecord] = []
        var copied = 0
        for (url, variant) in [(group.renderedImageURL, AssetVariant.renderedImage), (group.rawURL, AssetVariant.raw)] {
            guard let url else { continue }
            try cancellation?.check()
            let target = destination.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: target)
            copied += 1
            records.append(CatalogImportRecord(sourceKey: sourceKey(for: group, variant: variant, sourceRoot: sourceRoot, volumeUUID: volumeUUID), variant: variant, destinationURL: target, sha256: "", fileSize: 0))
        }
        try catalog.recordImports(records)
        return ImportResult(groupID: group.id, message: "ok", copiedCount: copied, skippedCount: 0, failedCount: 0)
    }
    func installCameraDownloadedFile(partialURL: URL, destinationURL: URL, variant: AssetVariant, sourceKey: String, sourceFilename: String?, catalog: any CatalogRepository, expectedFileSize: Int64, cancellation: ImportCancellationToken?) throws -> Bool { try cancellation?.check(); return false }
    func copyLibraryGroup(_ group: PhotoGroup, from sourceLibrary: URL, to destinationLibrary: URL, sourceCatalog: (any CatalogRepository)?, destinationCatalog: any CatalogRepository, copyLabels: Bool, cancellation: ImportCancellationToken?) throws -> ImportResult { ImportResult(groupID: group.id, message: "ok", copiedCount: 0, skippedCount: 0, failedCount: 0) }
    func moveGroupsToTrash(_ groups: [PhotoGroup], onProgress: (@Sendable (Int, Int, Int, Int) -> Void)?) async -> TrashBatchResult { TrashBatchResult(completedGroupIDs: Set(groups.map(\.id)), movedFileCount: 0, failedFileCount: 0, errorMessage: nil) }
    func airDrop(_ groups: [PhotoGroup], mode: AirDropMode, onCompletion: @escaping @Sendable (Error?) -> Void) throws -> any AirDropSessionHandling { onCompletion(nil); return TestAirDropSession() }
    func urlsForAirDrop(_ groups: [PhotoGroup], mode: AirDropMode) -> [URL] { [] }
    func sourceKey(for group: PhotoGroup, variant: AssetVariant, sourceRoot: URL?, volumeUUID: String?) -> String { SourceIdentity.legacyKey(url: variant == .renderedImage ? group.renderedImageURL! : group.rawURL!, variant: variant) }
    func makeFolderName(template: String, date: Date, camera: String) -> String { "Test Import" }
}

private final class TestAirDropSession: AirDropSessionHandling {}

private struct TestVolumeEjector: VolumeEjecting {
    func eject(volumeURL: URL) async throws {}
}

@MainActor
private final class AppModelTestEnvironment {
    let model: AppModel
    let cameraMonitor: TestCameraMonitor
    private let defaults: UserDefaults
    private let suiteName: String

    init() {
        suiteName = "PhotokichinTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        cameraMonitor = TestCameraMonitor()
        let transfer = TestTransfer()
        let useCases = AppUseCases(
            browsePhotos: BrowsePhotosUseCase(scanner: TestScanner()),
            openCatalog: OpenCatalogUseCase(factory: TestCatalogFactory()),
            importPhotos: ImportPhotosUseCase(transfer: transfer),
            copyPhotos: CopyPhotosUseCase(transfer: transfer),
            deletePhotos: DeletePhotosUseCase(transfer: transfer),
            sharePhotos: SharePhotosUseCase(transfer: transfer),
            mediaReader: TestMediaReader(),
            ejectVolume: EjectVolumeUseCase(ejector: TestVolumeEjector())
        )
        model = AppModel(
            dependencies: AppDependencies(
                volumeMonitor: TestVolumeMonitor(),
                cameraMonitor: cameraMonitor,
                useCases: useCases
            ),
            userDefaults: defaults
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
@Suite("AppModel workflows")
struct AppModelWorkflowTests {
    @Test("Source switching publishes only the latest scan")
    func sourceSwitching() async throws {
        let root = try makeTemporaryDirectory(prefix: "Photokichin-appmodel-scan")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try createPhotos(in: first, prefix: "FIRST", count: 3)
        try createPhotos(in: second, prefix: "SECOND", count: 2)

        let environment = AppModelTestEnvironment()
        defer { environment.cleanUp() }
        let model = environment.model
        #expect(model.libraryURL == nil, "an isolated AppModel must not restore the user's library")
        #expect(model.libraryURLs.isEmpty, "an isolated AppModel must not restore the user's saved library URLs")
        #expect(model.volumeMonitor.volumes.isEmpty, "an isolated AppModel must not inspect mounted volumes")

        // No sleep is used here. The second scan invalidates the first token;
        // only the latest directory is allowed to publish its result.
        model.scan(url: first)
        model.scan(url: second)
        await model.waitUntilIdle()

        #expect(model.sourceURL?.standardizedFileURL == second.standardizedFileURL, "the last scan source was not retained")
        #expect(model.groups.count == 2, "the last scan did not publish its complete group list")
        #expect(model.groups.allSatisfy { $0.basename.hasPrefix("SECOND") }, "a cancelled scan leaked groups into the later source")
        #expect(!model.isScanning, "the last scan remained active after its task completed")
    }

    @Test("Selection, filtering, viewer position, and keyboard navigation stay coherent")
    func selectionAndNavigation() throws {
        let root = try makeTemporaryDirectory(prefix: "Photokichin-appmodel-state")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppModelTestEnvironment()
        defer { environment.cleanUp() }
        let model = environment.model
        model.sourceURL = root
        model.sourceVolume = MountedVolume(
            id: root.path,
            url: root,
            name: "試験カード",
            isRemovable: true,
            isEjectable: true,
            volumeUUID: "test-volume"
        )

        let groups = (0..<20).map { index in
            makeWorkflowGroup(
                root: root,
                id: "state-\(index)",
                basename: "STATE_\(String(format: "%04d", index))",
                imported: index == 0,
                captureDate: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        model.replaceGroups(groups)
        model.setFocus(ids: [groups[0].id])

        model.toggleFocusedSelection()
        #expect(model.selectedIDs == [groups[0].id], "focused selection did not select the focused photo")
        model.toggleFocusedDeleteCandidate()
        #expect(model.deleteCandidateIDs == [groups[0].id], "focused delete candidate was not recorded")
        #expect(model.selectedIDs.isDisjoint(with: model.deleteCandidateIDs), "selection and delete candidate remained on the same photo")
        model.toggleFocusedSelection()
        #expect(model.selectedIDs == [groups[0].id], "selecting a delete candidate did not remove it from delete candidates")
        #expect(model.deleteCandidateIDs.isEmpty, "the selected photo remained a delete candidate")

        model.importFilter = .imported
        #expect(model.filteredPhotoCount == 1, "import-state filter returned the wrong count")
        model.importFilter = .all
        model.operationFilter = .selected
        #expect(model.filteredPhotoCount == 1, "selection filter returned the wrong count")
        model.operationFilter = .all
        model.clearSelection()
        #expect(model.selectedIDs.isEmpty && model.selectedPhotoCount == 0, "clearSelection did not clear the selected photo")

        model.updateGridColumnCount(width: 500)
        model.updateGridViewport(height: 500)
        model.setFocus(ids: [groups[0].id])
        model.moveFocus(direction: .right)
        #expect(model.focusedIDs == [groups[1].id], "right navigation did not move to the adjacent photo")
        model.moveFocusPage(direction: .down)
        #expect(model.focusedIDs != [groups[1].id], "page navigation did not move the focus")
        model.moveFocus(to: .end)
        #expect(model.focusedIDs == [groups.last!.id], "End navigation did not focus the last photo")
        model.moveFocus(to: .beginning)
        #expect(model.focusedIDs == [groups[0].id], "Home navigation did not focus the first photo")

        model.openViewer(for: groups[5])
        #expect(model.viewerPositionText == "6 / 20", "viewer position text was inconsistent with the visible list")
        #expect(model.viewerNeighborGroups.map(\.id) == [groups[4].id, groups[6].id], "viewer neighbors were not the adjacent photos")
        model.clearSelection()
        #expect(model.selectedIDs.isEmpty, "selection was not clear after viewer navigation")
        model.closeViewer()
    }

    @Test("Import publishes progress, copies both variants, and updates state")
    func importing() async throws {
        let root = try makeTemporaryDirectory(prefix: "Photokichin-appmodel-import")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let jpeg = source.appendingPathComponent("IMG_9000.JPG")
        let raw = source.appendingPathComponent("IMG_9000.CR3")
        try Data("app-model-jpeg".utf8).write(to: jpeg)
        try Data("app-model-raw".utf8).write(to: raw)

        let environment = AppModelTestEnvironment()
        defer { environment.cleanUp() }
        let model = environment.model
        model.sourceURL = source
        model.sourceVolume = MountedVolume(
            id: source.path,
            url: source,
            name: "試験カード",
            isRemovable: true,
            isEjectable: true,
            volumeUUID: nil
        )
        let group = PhotoGroup(
            id: source.appendingPathComponent("IMG_9000").path,
            basename: "IMG_9000",
            directory: source,
            renderedImageURL: jpeg,
            rawURL: raw,
            movieURL: nil,
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: .empty,
            importedRenderedImage: false,
            importedRAW: false,
            isMetadataLoaded: true
        )
        model.replaceGroups([group])
        model.setFocus(ids: [group.id])
        model.toggleFocusedSelection()

        model.importSelected(to: destination, template: "{date}_{camera}")
        #expect(model.isBusy, "importSelected did not enter the busy state")
        #expect(model.operationProgress?.title == "取り込み中", "importSelected did not publish import progress")
        await model.waitUntilIdle()

        #expect(!model.isBusy, "isBusy remained true after import completion")
        #expect(model.operationProgress == nil, "operationProgress remained after import completion")
        #expect(model.lastImportResults.count == 1, "import completion did not retain one result")
        let result = try requireValue(model.lastImportResults.first, "import result was missing")
        #expect(result.copiedCount == 2 && result.failedCount == 0, "JPG＋CR3 import did not complete successfully")
        #expect(model.progressText == "取り込みが完了しました", "import completion text was not published")
        #expect(model.groups.first?.cardImportState == .imported, "the selected photo import state was not updated")
        #expect(FileManager.default.fileExists(atPath: try findFile(named: "IMG_9000.JPG", under: destination).path), "copied JPG was not found")
        #expect(FileManager.default.fileExists(atPath: try findFile(named: "IMG_9000.CR3", under: destination).path), "copied CR3 was not found")

        #expect(FileManager.default.fileExists(atPath: try findFile(named: "IMG_9000.JPG", under: destination).path), "copied JPG was not registered in the destination")
    }

    @Test("Camera catalog replacement preserves valid focus and removes stale focus")
    func cameraCatalogFocus() async throws {
        let environment = AppModelTestEnvironment()
        defer { environment.cleanUp() }
        let model = environment.model
        let descriptor = CameraDescriptor(
            id: "test-camera",
            name: "試験カメラ",
            serialNumber: "TEST",
            isReady: true,
            groupCount: 3,
            canDeleteFiles: true,
            canEject: false,
            connectionState: .ready
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-camera-test-\(UUID().uuidString)", isDirectory: true)
        let first = (0..<3).map { index in
            makeWorkflowGroup(root: root, id: "camera-\(index)", basename: "CAMERA_\(index)", imported: false, captureDate: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        model.sourceCamera = descriptor
        model.sourceVolume = nil
        model.sourceURL = CameraSourceLocation.url(for: descriptor.id)
        environment.cameraMonitor.publishReadyCamera(descriptor, groups: first)
        await yieldUntil { model.groups.count == first.count }
        model.setFocus(ids: [first[1].id])

        let appended = first + [makeWorkflowGroup(root: root, id: "camera-3", basename: "CAMERA_3", imported: false, captureDate: Date(timeIntervalSince1970: 3))]
        environment.cameraMonitor.publishReadyCamera(descriptor, groups: appended)
        await yieldUntil { model.groups.count == appended.count }
        #expect(model.focusedIDs == [first[1].id], "camera catalog replacement did not retain an existing focus")

        let reduced = [appended[0], appended[2], appended[3]]
        environment.cameraMonitor.publishReadyCamera(descriptor, groups: reduced)
        await yieldUntil { Set(model.groups.map(\.id)) == Set(reduced.map(\.id)) }
        #expect(!model.focusedIDs.isEmpty, "camera catalog replacement left focus empty after the focused photo disappeared")
        #expect(model.focusedIDs.isSubset(of: Set([appended[0].id, appended[2].id, appended[3].id])), "camera catalog replacement retained a removed focus")
    }

    private func yieldUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createPhotos(in root: URL, prefix: String, count: Int) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<count {
            let url = root.appendingPathComponent("\(prefix)_\(String(format: "%04d", index)).JPG")
            try Data("\(prefix)-\(index)".utf8).write(to: url)
        }
    }

    private func makeWorkflowGroup(
        root: URL,
        id: String,
        basename: String,
        imported: Bool,
        captureDate: Date
    ) -> PhotoGroup {
        PhotoGroup(
            id: id,
            basename: basename,
            directory: root,
            renderedImageURL: root.appendingPathComponent("\(basename).JPG"),
            rawURL: nil,
            movieURL: nil,
            captureDate: captureDate,
            metadata: .empty,
            importedRenderedImage: imported,
            importedRAW: false,
            isMetadataLoaded: true
        )
    }

    private func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        try #require(value, Comment(rawValue: message))
    }

    private func findFile(named name: String, under root: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "PhotokichinTests", code: 1)
        }
        for case let url as URL in enumerator where url.lastPathComponent == name { return url }
        throw NSError(domain: "PhotokichinTests", code: 2)
    }
}
