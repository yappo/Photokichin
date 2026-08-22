import AppKit
import Foundation
import SwiftUI

enum FocusDirection: Equatable {
    case left
    case right
    case up
    case down
}

enum FocusBoundary {
    case beginning
    case end
}

enum FocusScrollEdge {
    case beginning
    case end
}

enum PhotoFilter: CaseIterable, Identifiable, Hashable {
    case all
    case selected
    case deleteCandidates
    case marked

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "すべて"
        case .selected: return "通常選択"
        case .deleteCandidates: return "削除候補"
        case .marked: return "通常選択＋削除候補"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .selected: return "checkmark.circle"
        case .deleteCandidates: return "trash"
        case .marked: return "checkmark.circle.badge.xmark"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private struct SourceBrowsingState {
        var importFilter: PhotoImportFilter
        var operationFilter: PhotoOperationFilter
        var focusedIDs: Set<String>
        var lastFocusedID: String?
    }

    private struct NavigationPosition {
        let section: Int
        let indexInSection: Int
        let flatIndex: Int
    }

    private struct CancelledSourceProcessing {
        let scanTask: Task<Void, Never>?
        let directoryScanTask: Task<[PhotoGroup], Never>?
        let scanStateTask: Task<Void, Never>?
        let scanStateWorkerTask: Task<[PhotoGroup]?, Never>?
        let catalogInspectionTask: Task<Void, Never>?
        let catalogInspectionWorkerTask: Task<CatalogInspectionResult?, Never>?
        let catalogVerificationWorkerTask: Task<String?, Never>?

        func waitForIOToStop() async {
            _ = await directoryScanTask?.value
            _ = await scanStateWorkerTask?.value
            _ = await catalogInspectionWorkerTask?.value
            _ = await catalogVerificationWorkerTask?.value
            _ = await scanStateTask?.value
            _ = await catalogInspectionTask?.value
            _ = await scanTask?.value
        }
    }

    @Published var groups: [PhotoGroup] = [] {
        didSet {
            groupByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
            groupIndexByID = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.element.id, $0.offset) })
            groupStateRevision &+= 1
        }
    }
    @Published private(set) var groupedPhotos: [(String, [PhotoGroup])] = []
    @Published var focusedIDs: Set<String> = []
    @Published private(set) var focusScrollRevision = 0
    @Published private(set) var focusScrollEdge: FocusScrollEdge = .end
    @Published var selectedIDs: Set<String> = [] {
        didSet { rebuildFilteredPhotos() }
    }
    @Published var deleteCandidateIDs: Set<String> = [] {
        didSet { rebuildFilteredPhotos() }
    }
    @Published var sourceURL: URL?
    @Published var sourceVolume: MountedVolume?
    @Published var sourceCamera: CameraDescriptor?
    @Published private(set) var cameras: [CameraDescriptor] = []
    @Published var libraryURL: URL?
    @Published private(set) var libraryURLs: [URL] = []
    @Published var isScanning = false
    @Published var isBusy = false
    @Published var operationProgress: OperationProgress?
    @Published var progressText = "SDカードまたはフォルダを選択してください"
    @Published var thumbnailSize: Double = 180
    @Published private(set) var gridColumnCount = 1
    @Published private(set) var gridViewportHeight: Double = 700
    @Published private(set) var groupStateRevision = 0
    @Published private(set) var listContentRevision = 0
    @Published var importFilter: PhotoImportFilter = .all { didSet { handleFilterChange() } }
    @Published var operationFilter: PhotoOperationFilter = .all { didSet { handleFilterChange() } }
    @Published private(set) var filteredGroupedPhotos: [(String, [PhotoGroup])] = []
    @Published var inspectorShown = true
    @Published var viewerGroupID: String?
    @Published var errorMessage: String?
    @Published var lastImportResults: [ImportResult] = []
    @Published var importTemplate = "{date}_{camera}"
    @Published private(set) var isCancellingImport = false
    @Published private(set) var catalogSummary: CatalogSummary?
    @Published private(set) var catalogIssues: [CatalogIssue] = []
    @Published private(set) var isCatalogInspecting = false
    @Published private(set) var isImportStateRefreshing = false
    @Published private(set) var labels: [PhotoLabel] = []
    @Published private(set) var savedLabelViews: [SavedLabelView] = []
    @Published var activeLabelIDs: Set<String> = [] { didSet { handleFilterChange() } }
    /// Identifies a saved view that was explicitly selected in the sidebar.
    /// A matching set of labels created manually is intentionally not treated
    /// as a saved-view selection.
    @Published private(set) var activeSavedLabelViewID: String?
    @Published var isLabelPickerPresented = false
    @Published var isLabelManagementPresented = false
    @Published var copyLabelsOnLibraryCopy = true

    let volumeMonitor: VolumeMonitor
    let cameraMonitor: CameraMonitor
    private let usesPersistentState: Bool
    private var catalog: CatalogStore?
    private var targetCatalog: CatalogStore?
    private var groupByID: [String: PhotoGroup] = [:]
    private var groupIndexByID: [String: Int] = [:]
    private var navigationPositionByID: [String: NavigationPosition] = [:]
    private var currentScanToken = UUID()
    private var importStateRefreshToken = UUID()
    private var scanTask: Task<Void, Never>?
    private var directoryScanTask: Task<[PhotoGroup], Never>?
    private var scanStateTask: Task<Void, Never>?
    private var scanStateWorkerTask: Task<[PhotoGroup]?, Never>?
    private var importTask: Task<Void, Never>?
    private var importCancellation: ImportCancellationToken?
    private var airDropSession: FileTransferService.AirDropSession?
    private var catalogInspectionTask: Task<Void, Never>?
    private var catalogInspectionWorkerTask: Task<CatalogInspectionResult?, Never>?
    private var catalogVerificationWorkerTask: Task<String?, Never>?
    private var lastFocusedID: String?
    private var userMovedFocusForCurrentSource = false
    private var focusBeforeFilter: Set<String>?
    private var lastFocusBeforeFilter: String?
    private var metadataTotal = 0
    private var metadataCompleted = 0
    private var metadataEnqueuedIDs: Set<String> = []
    private var metadataSourceScanFinished = false
    private var browsingStateBySourcePath: [String: SourceBrowsingState] = [:]
    private var pendingRestoredFocusIDs: Set<String> = []
    private var pendingRestoredLastFocusID: String?
    private var pendingMetadata: [String: PhotoMetadata] = [:]
    private var completedMetadataIDs: Set<String> = []
    private let metadataProgressDisplayInterval = 64
    private var keyMonitor: Any?
    weak var photoSelectionResponder: NSView?
    private var photoIDsByLabelID: [String: Set<String>] = [:]

    init(testing: Bool = false) {
        usesPersistentState = !testing
        volumeMonitor = VolumeMonitor(startMonitoring: !testing)
        cameraMonitor = CameraMonitor.shared

        if testing {
            return
        }

        let defaults = UserDefaults.standard
        var savedLibraryPaths = defaults.stringArray(forKey: "libraryURLs") ?? []
        if let legacyPath = defaults.string(forKey: "libraryURL"),
           !savedLibraryPaths.contains(legacyPath) {
            savedLibraryPaths.insert(legacyPath, at: 0)
        }
        libraryURLs = savedLibraryPaths.map { URL(fileURLWithPath: $0) }

        let activeLibraryPath = defaults.string(forKey: "libraryURL")
            ?? savedLibraryPaths.first
        if let activeLibraryPath {
            let url = URL(fileURLWithPath: activeLibraryPath)
            if FileManager.default.fileExists(atPath: url.path) {
                libraryURL = url
                catalog = try? CatalogStore(libraryRoot: url)
                targetCatalog = catalog
                catalogSummary = catalog?.summary()
                catalogIssues = catalog?.issues() ?? []
            }
        }

        if let volume = volumeMonitor.volumes.first(where: { $0.name == "EOS_DIGITAL" }) {
            scan(url: volume.url, volume: volume)
        }
        volumeMonitor.onMount = { [weak self] volume in
            guard let self, !self.isBusy, !self.isScanning else { return }
            self.scan(url: volume.url, volume: volume)
        }
        volumeMonitor.onUnmount = { [weak self] volumeURL in
            self?.handleUnmountedVolume(volumeURL)
        }
        cameraMonitor.onCameraReady = { [weak self] descriptor, groups in
            guard let self,
                  self.sourceCamera?.id == descriptor.id,
                  !self.isBusy else { return }
            self.updateVisibleCameraCatalog(descriptor, groups: groups, isComplete: true)
        }
        cameraMonitor.onCameraCatalogUpdate = { [weak self] descriptor, groups in
            guard let self,
                  self.sourceCamera?.id == descriptor.id,
                  !self.isBusy else { return }
            self.updateVisibleCameraCatalog(descriptor, groups: groups, isComplete: false)
        }
        cameraMonitor.onCameraRemoved = { [weak self] cameraID in
            self?.handleRemovedCamera(cameraID)
        }
        cameraMonitor.onCamerasChanged = { [weak self] cameras in
            guard let self else { return }
            self.cameras = cameras
            if let sourceCamera = self.sourceCamera,
               let updated = cameras.first(where: { $0.id == sourceCamera.id }) {
                self.sourceCamera = updated
            }
        }
        cameraMonitor.onError = { [weak self] message in
            self?.errorMessage = message
        }
        cameraMonitor.start()
    }

    deinit {
        scanTask?.cancel()
        directoryScanTask?.cancel()
        scanStateTask?.cancel()
        scanStateWorkerTask?.cancel()
        importCancellation?.cancel()
        importTask?.cancel()
        catalogInspectionTask?.cancel()
        catalogInspectionWorkerTask?.cancel()
        catalogVerificationWorkerTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

#if PHOTOKICHIN_TESTING
    /// Waits for the source scan or import operation that is currently owned
    /// by this model. Production code keeps these tasks private; deterministic
    /// tests use this boundary instead of sleeping for an assumed duration.
    func waitForCurrentOperationsForTesting() async {
        while true {
            let currentScan = scanTask
            let currentImport = importTask
            if currentScan == nil, currentImport == nil { return }
            if let currentScan { await currentScan.value }
            if let currentImport { await currentImport.value }
            await Task.yield()
        }
    }

    /// Rebuilds the derived collections after a test installs an explicit
    /// group snapshot. The application always reaches this through scan or a
    /// catalog callback, so this is deliberately test-only.
    func rebuildDerivedStateForTesting() {
        rebuildGroupedPhotos()
    }

    /// Feeds a completed camera catalog through the same path used by
    /// ImageCaptureCore callbacks. No camera device or didAdd event is needed.
    func replaceVisibleCameraCatalogForTesting(
        _ descriptor: CameraDescriptor,
        groups: [PhotoGroup],
        isComplete: Bool = true
    ) {
        sourceCamera = descriptor
        sourceVolume = nil
        sourceURL = CameraMonitor.sourceURL(for: descriptor.id)
        updateVisibleCameraCatalog(descriptor, groups: groups, isComplete: isComplete)
    }
#endif

    var selectedGroups: [PhotoGroup] {
        selectedIDs.compactMap { groupByID[$0] }
    }

    var focusedGroups: [PhotoGroup] {
        focusedIDs.compactMap { groupByID[$0] }
    }

    var deleteCandidateGroups: [PhotoGroup] {
        deleteCandidateIDs.compactMap { groupByID[$0] }
    }

    var focusedGroup: PhotoGroup? {
        focusedIDs.first.flatMap { groupByID[$0] }
    }

    var viewerGroup: PhotoGroup? {
        guard let viewerGroupID else { return nil }
        return groupByID[viewerGroupID]
    }

    var viewerPositionText: String {
        guard let viewerGroup,
              let index = displayGroups.firstIndex(where: { $0.id == viewerGroup.id }) else { return "" }
        return "\(index + 1) / \(displayGroups.count)"
    }

    var viewerNeighborGroups: [PhotoGroup] {
        guard let viewerGroup,
              let index = displayGroups.firstIndex(where: { $0.id == viewerGroup.id }) else { return [] }
        return [index - 1, index + 1]
            .filter { displayGroups.indices.contains($0) }
            .map { displayGroups[$0] }
    }

    private var displayGroups: [PhotoGroup] {
        navigationSections.flatMap { $0 }
    }

    /// The exact photo order rendered by PhotoListView. A date containing
    /// multiple import states is rendered as contiguous state runs without
    /// changing chronology, so keyboard navigation uses those same runs.
    private var navigationSections: [[PhotoGroup]] {
        filteredGroupedPhotos.flatMap { day, photos -> [[PhotoGroup]] in
            let clusters = PhotoImportCluster.preservingOrder(dateKey: day, photos: photos)
            return clusters.count > 1 ? clusters.map(\.photos) : [photos]
        }
    }

    var isLibraryView: Bool {
        guard let sourceURL else { return false }
        return libraryURLs.contains { $0.standardizedFileURL == sourceURL.standardizedFileURL }
    }

    var isCameraSource: Bool { sourceCamera != nil }

    var isCameraCataloging: Bool { sourceCamera?.isCataloging == true }

    var canDeleteSourceFiles: Bool {
        if sourceVolume != nil { return true }
        return sourceCamera?.canDeleteFiles == true
    }

    private var catalogRootURL: URL? {
        isLibraryView ? sourceURL : libraryURL
    }

    var totalPhotoCount: Int { groups.count }

    var filteredPhotoCount: Int {
        filteredGroupedPhotos.reduce(0) { $0 + $1.1.count }
    }

    var selectedPhotoCount: Int { selectedIDs.count }

    var deleteCandidatePhotoCount: Int { deleteCandidateIDs.count }

    var focusedPhotoCount: Int { focusedIDs.count }

    var activeLabels: [PhotoLabel] {
        labels.filter { activeLabelIDs.contains($0.id) }
    }

    var availableImportFilters: [PhotoImportFilter] {
        PhotoImportFilter.allCases.filter { filter in
            filter != .possible || isCameraSource
        }
    }

    /// Custom command-menu shortcuts must be disabled while a label sheet is
    /// active so standard text editing commands such as Command-A remain with
    /// the sheet's first responder instead of operating the photo list.
    var blocksPhotoListCommandShortcuts: Bool {
        isLabelPickerPresented || isLabelManagementPresented
    }

    var labelTargetGroups: [PhotoGroup] {
        let candidates = selectedGroups.isEmpty ? focusedGroups : selectedGroups
        return candidates.filter { $0.photoID != nil && $0.libraryAssetStatus != .unregistered && $0.libraryAssetStatus != .notApplicable }
    }

    var excludedLabelTargetCount: Int {
        let candidates = selectedGroups.isEmpty ? focusedGroups : selectedGroups
        return candidates.count - labelTargetGroups.count
    }

    var canCopyToTargetLibrary: Bool {
        guard isLibraryView,
              let sourceURL,
              let libraryURL,
              sourceURL.standardizedFileURL != libraryURL.standardizedFileURL else { return false }
        return !selectedGroups.isEmpty
    }

    var hasActiveFilters: Bool {
        importFilter != .all || operationFilter != .all || !activeLabelIDs.isEmpty
    }

    var activeFilterDescription: String {
        let filters = [
            importFilter == .all ? nil : "取り込み状態: \(importFilter.title)",
            operationFilter == .all ? nil : "操作状態: \(operationFilter.title)",
            activeLabelIDs.isEmpty ? nil : "ラベル: \(activeLabels.map(\.name).joined(separator: " × "))"
        ].compactMap { $0 }
        return filters.isEmpty ? "すべて" : filters.joined(separator: " × ")
    }

    func selectedCount(in photos: [PhotoGroup]) -> Int {
        photos.reduce(into: 0) { count, photo in
            if selectedIDs.contains(photo.id) { count += 1 }
        }
    }

    func deleteCandidateCount(in photos: [PhotoGroup]) -> Int {
        photos.reduce(into: 0) { count, photo in
            if deleteCandidateIDs.contains(photo.id) { count += 1 }
        }
    }

    func clearSelection(in photos: [PhotoGroup]) {
        selectedIDs.subtract(photos.map(\.id))
    }

    func selectAll(in photos: [PhotoGroup]) {
        let ids = photos.map(\.id)
        selectedIDs.formUnion(ids)
        deleteCandidateIDs.subtract(ids)
    }

    func clearDeleteCandidates(in photos: [PhotoGroup]) {
        deleteCandidateIDs.subtract(photos.map(\.id))
    }

    func markDeleteCandidates(in photos: [PhotoGroup]) {
        guard canDeleteSourceFiles else { return }
        let ids = photos.map(\.id)
        deleteCandidateIDs.formUnion(ids)
        selectedIDs.subtract(ids)
    }

    private func rebuildGroupedPhotos() {
        let dictionary = Dictionary(grouping: groups, by: \.dateKey)
        groupedPhotos = dictionary.keys.sorted { lhs, rhs in
            if lhs == "撮影日不明" { return false }
            if rhs == "撮影日不明" { return true }
            return lhs < rhs
        }.map { key in
            (key, dictionary[key, default: []].sorted(by: PhotoGroup.presentationPrecedes))
        }
        rebuildFilteredPhotos()
    }

    private func rebuildFilteredPhotos() {
        let matchingPhotoIDs: Set<String>? = activeLabelIDs.isEmpty ? nil : activeLabelIDs
            .compactMap { photoIDsByLabelID[$0] }
            .sorted { $0.count < $1.count }
            .reduce(nil as Set<String>?) { partial, next in
                partial.map { $0.intersection(next) } ?? next
            } ?? []
        filteredGroupedPhotos = groupedPhotos.compactMap { day, photos in
            let filteredPhotos = photos.filter { group in
                group.matches(
                    importFilter: importFilter,
                    operationFilter: operationFilter,
                    selected: selectedIDs.contains(group.id),
                    deleteCandidate: deleteCandidateIDs.contains(group.id)
                ) && matchingPhotoIDs.map { ids in group.photoID.map(ids.contains) ?? false } != false
            }
            return filteredPhotos.isEmpty ? nil : (day, filteredPhotos)
        }

        navigationPositionByID.removeAll(keepingCapacity: true)
        var flatIndex = 0
        for (section, photos) in navigationSections.enumerated() {
            for (indexInSection, photo) in photos.enumerated() {
                navigationPositionByID[photo.id] = NavigationPosition(
                    section: section,
                    indexInSection: indexInSection,
                    flatIndex: flatIndex
                )
                flatIndex += 1
            }
        }
        listContentRevision &+= 1
    }

    private func handleFilterChange() {
        let filtering = hasActiveFilters
        if filtering, focusBeforeFilter == nil {
            focusBeforeFilter = focusedIDs
            lastFocusBeforeFilter = lastFocusedID
        }

        rebuildFilteredPhotos()

        if filtering {
            focusFirstVisiblePhoto()
        } else if let focusBeforeFilter {
            let availableIDs = Set(groups.map(\.id))
            let restoredIDs = focusBeforeFilter.intersection(availableIDs)
            focusedIDs = restoredIDs
            lastFocusedID = lastFocusBeforeFilter.flatMap { restoredIDs.contains($0) ? $0 : nil }
                ?? restoredIDs.first
            self.focusBeforeFilter = nil
            lastFocusBeforeFilter = nil
        }
    }

    private func focusFirstVisiblePhoto() {
        let first = displayGroups.first
        guard let first else {
            focusedIDs.removeAll()
            lastFocusedID = nil
            return
        }
        focusedIDs = [first.id]
        lastFocusedID = first.id
        requestMetadataForCurrentCameraFocus()
    }

    private func requestMetadataForCurrentCameraFocus() {
        guard isCameraSource,
              let focusedGroup = navigationFocusedGroup else { return }
        prioritizeMetadata(for: focusedGroup.id, priority: .viewerCurrent)
    }

    var selectedCountText: String {
        "取り込み \(selectedIDs.count)枚 / 削除 \(deleteCandidateIDs.count)枚"
    }

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }

            // A SwiftUI sheet is presented as an attached key window. Every
            // key belongs to that sheet while it is active; consuming arrows,
            // Return, Delete, Space, L, or Escape here would operate the photo
            // list behind the sheet and break ordinary text-field behavior.
            let keyWindow = NSApp.keyWindow
            if keyWindow?.sheetParent != nil || NSApp.modalWindow != nil {
                return event
            }
            // Also leave all keys alone while an AppKit field editor is active
            // in the main window (for example, a popover text field).
            if keyWindow?.firstResponder is NSTextView || keyWindow?.firstResponder is NSTextField {
                return event
            }

            if event.keyCode == 49 {
                guard event.isARepeat == false else { return nil }
                self.toggleViewer()
                return nil
            }

            if event.charactersIgnoringModifiers?.lowercased() == "l",
               !event.modifierFlags.contains(.command), !event.isARepeat {
                self.presentLabelPicker()
                return nil
            }

            let viewerIsOpen = self.viewerGroupID != nil
            if viewerIsOpen {
                switch event.keyCode {
                case 36, 76:
                    guard !event.isARepeat else { return nil }
                    self.toggleViewerSelection()
                    return nil
                case 51, 117:
                    guard !event.isARepeat else { return nil }
                    self.toggleViewerDeleteCandidate()
                    return nil
                case 53: self.closeViewer(); return nil
                default: break
                }
            }

            // AppKit already translates Fn+Down/Fn+Up into the dedicated
            // Page Down/Page Up key codes (121/116). Arrow-key events can
            // themselves carry the `.function` flag, so inferring a page key
            // from that flag makes a plain Down/Up jump by a whole page.
            let isPageDown = event.keyCode == 121
            let isPageUp = event.keyCode == 116

            // Before the first incremental scan snapshot exists there is no
            // valid navigation target. Once photos are visible, native repeat
            // events are applied immediately; replaying a large key queue at
            // scan completion blocks the main actor and makes the UI appear
            // hung after a source switch.
            if self.isScanning && self.groups.isEmpty {
                switch event.keyCode {
                case 123, 124, 125, 126, 115, 116, 119, 121: return nil
                default: break
                }
            }

            if isPageDown {
                self.moveFocusPage(direction: .down)
                if viewerIsOpen { self.syncViewerToNavigationFocus() }
                return nil
            }
            if isPageUp {
                self.moveFocusPage(direction: .up)
                if viewerIsOpen { self.syncViewerToNavigationFocus() }
                return nil
            }
            if event.keyCode == 115 {
                self.moveFocus(to: .beginning)
                if viewerIsOpen { self.syncViewerToNavigationFocus() }
                return nil
            }
            if event.keyCode == 119 {
                self.moveFocus(to: .end)
                if viewerIsOpen { self.syncViewerToNavigationFocus() }
                return nil
            }

            switch event.keyCode {
            case 123:
                self.moveFocus(direction: .left)
                if viewerIsOpen { self.syncViewerToNavigationFocus() }
                return nil
            case 124:
                self.moveFocus(direction: .right)
                if viewerIsOpen { self.syncViewerToNavigationFocus() }
                return nil
            case 125:
                self.moveFocus(direction: .down)
                if viewerIsOpen { self.syncViewerToNavigationFocus() }
                return nil
            case 126:
                self.moveFocus(direction: .up)
                if viewerIsOpen { self.syncViewerToNavigationFocus() }
                return nil
            case 36, 76:
                guard !event.isARepeat else { return event }
                self.toggleFocusedSelection()
                return nil
            case 51, 117:
                guard !event.isARepeat else { return event }
                self.toggleFocusedDeleteCandidate()
                return nil
            default:
                return event
            }
        }
    }

    func openViewer(for group: PhotoGroup) {
        viewerGroupID = group.id
    }

    func toggleViewer() {
        if viewerGroupID != nil {
            closeViewer()
        } else if let first = focusedGroups.first {
            openViewer(for: first)
        }
    }

    func closeViewer() {
        viewerGroupID = nil
    }

    private func syncViewerToNavigationFocus() {
        guard viewerGroupID != nil,
              let focusedID = navigationFocusedGroup?.id else { return }
        viewerGroupID = focusedID
    }

    func toggleViewerSelection() {
        guard let viewerGroup else { return }
        toggleSelection(for: [viewerGroup.id])
    }

    func toggleViewerDeleteCandidate() {
        guard let viewerGroup else { return }
        toggleDeleteCandidate(for: [viewerGroup.id])
    }

    func adjustThumbnailSize(by delta: Double) {
        thumbnailSize = min(640, max(90, thumbnailSize + delta))
    }

    func updateGridColumnCount(width: CGFloat) {
        let horizontalPadding: CGFloat = 44
        let spacing: CGFloat = 12
        let usableWidth = max(1, width - horizontalPadding)
        let stride = CGFloat(thumbnailSize) + spacing
        gridColumnCount = max(1, Int((usableWidth + spacing) / stride))
    }

    func updateGridViewport(height: CGFloat) {
        gridViewportHeight = max(1, height)
    }

    private var initialScanPresentationGroupTarget: Int {
        // The initial scan snapshot covers the visible viewport and one
        // viewport of prefetch in both directions. These dimensions mirror
        // PhotoGroupTile and the list row spacing; the target therefore
        // follows the actual window, column count, and thumbnail size.
        let thumbnailHeight = thumbnailSize * PhotoGridLayoutMetrics.thumbnailHeightRatio
        let captionHeight = NSFont.preferredFont(forTextStyle: .caption1).boundingRectForFont.height
        let rowHeight = max(
            1,
            thumbnailHeight + PhotoGridLayoutMetrics.tileTextSpacing + captionHeight
        )
        let visibleRows = max(1, Int(ceil(gridViewportHeight / rowHeight)))
        return visibleRows
            * max(1, gridColumnCount)
            * PhotoGridLayoutMetrics.initialWorkingSetViewportCount
    }

    func moveFocus(direction: FocusDirection) {
        guard let current = navigationFocusedGroup else { return }

        guard let position = navigationPositionByID[current.id],
              navigationSections.indices.contains(position.section) else { return }
        let sectionIndex = position.section
        let photoIndex = position.indexInSection
        let photos = navigationSections[sectionIndex]

        let columns = max(1, gridColumnCount)
        let target: PhotoGroup?
        switch direction {
        case .left:
            // Horizontal navigation follows the visual grid, including the
            // row boundary. At the left edge, left moves to the last item of
            // the previous row (and naturally crosses a date section).
            target = position.flatIndex > 0 ? displayGroups[position.flatIndex - 1] : nil
        case .right:
            // At the right edge, right moves to the first item of the next
            // row. The final item remains the boundary of the document.
            target = position.flatIndex + 1 < displayGroups.count
                ? displayGroups[position.flatIndex + 1]
                : nil
        case .up:
            if photoIndex >= columns {
                target = photos[photoIndex - columns]
            } else if sectionIndex > 0 {
                let previousPhotos = navigationSections[sectionIndex - 1]
                target = PhotoGridNavigation.previousSectionIndex(
                    currentColumn: photoIndex % columns,
                    previousCount: previousPhotos.count,
                    columns: columns
                ).map { previousPhotos[$0] }
            } else {
                target = nil
            }
        case .down:
            let candidate = photoIndex + columns
            if candidate < photos.count {
                target = photos[candidate]
            } else if sectionIndex + 1 < navigationSections.count {
                let nextPhotos = navigationSections[sectionIndex + 1]
                target = nextPhotos[min(photoIndex % columns, nextPhotos.count - 1)]
            } else {
                target = nil
            }
        }

        guard let target else { return }
        focusedIDs = [target.id]
        lastFocusedID = target.id
        userMovedFocusForCurrentSource = true
        switch direction {
        case .left, .up:
            focusScrollEdge = .beginning
        case .right, .down:
            focusScrollEdge = .end
        }
        focusScrollRevision &+= 1
        requestMetadataForCurrentCameraFocus()
    }

    func moveFocusPage(direction: FocusDirection) {
        guard direction == .up || direction == .down,
              let current = navigationFocusedGroup,
              let position = navigationPositionByID[current.id],
              !displayGroups.isEmpty else { return }

        // A page is one viewport minus one row, so the next focused photo
        // remains visibly connected to the current page while scrolling.
        let captionHeight = NSFont.preferredFont(forTextStyle: .caption1).boundingRectForFont.height
        let rowHeight = max(
            1,
            thumbnailSize * PhotoGridLayoutMetrics.thumbnailHeightRatio
                + PhotoGridLayoutMetrics.tileTextSpacing
                + captionHeight
        )
        let visibleRows = max(1, Int((gridViewportHeight - 80) / rowHeight))
        let rowsToMove = max(1, visibleRows - 1)
        let itemCount = rowsToMove * max(1, gridColumnCount)
        let offset = direction == .down ? itemCount : -itemCount
        guard let targetIndex = PhotoGridNavigation.pageTargetIndex(
            current: position.flatIndex,
            count: displayGroups.count,
            itemOffset: offset
        ) else { return }
        guard targetIndex != position.flatIndex else { return }
        focusedIDs = [displayGroups[targetIndex].id]
        lastFocusedID = displayGroups[targetIndex].id
        userMovedFocusForCurrentSource = true
        focusScrollEdge = direction == .down ? .end : .beginning
        focusScrollRevision &+= 1
        requestMetadataForCurrentCameraFocus()
    }

    private var navigationFocusedGroup: PhotoGroup? {
        if let lastFocusedID,
           focusedIDs.contains(lastFocusedID),
           let group = groupByID[lastFocusedID] {
            return group
        }
        return displayGroups.first(where: { focusedIDs.contains($0.id) })
    }

    func moveFocus(to boundary: FocusBoundary) {
        let target: PhotoGroup?
        switch boundary {
        case .beginning:
            target = displayGroups.first
        case .end:
            target = displayGroups.last
        }
        guard let target else { return }
        focusedIDs = [target.id]
        lastFocusedID = target.id
        userMovedFocusForCurrentSource = true
        switch boundary {
        case .beginning: focusScrollEdge = .beginning
        case .end: focusScrollEdge = .end
        }
        // Home/End must scroll even when the focus is already on the
        // requested boundary. In that case focusedIDs does not change, so
        // observing only focusedIDs would correctly emit no event while the
        // visible scroll position could still be elsewhere.
        focusScrollRevision &+= 1
        requestMetadataForCurrentCameraFocus()
    }

    func scan(url: URL, volume: MountedVolume? = nil) {
        let cancelledProcessing = invalidateSourceProcessing()
        let token = currentScanToken
        sourceCamera = nil
        if let previousSourcePath = sourceURL?.path {
            browsingStateBySourcePath[previousSourcePath] = SourceBrowsingState(
                importFilter: importFilter,
                operationFilter: operationFilter,
                focusedIDs: focusedIDs,
                lastFocusedID: lastFocusedID
            )
        }
        closeViewer()
        userMovedFocusForCurrentSource = false
        focusedIDs.removeAll()
        focusBeforeFilter = nil
        lastFocusBeforeFilter = nil
        selectedIDs.removeAll()
        deleteCandidateIDs.removeAll()
        activeLabelIDs.removeAll()
        activeSavedLabelViewID = nil
        labels.removeAll()
        savedLabelViews.removeAll()
        photoIDsByLabelID.removeAll()
        let restoredState = browsingStateBySourcePath[url.path]
        importFilter = restoredState?.importFilter ?? .all
        operationFilter = restoredState?.operationFilter ?? .all
        pendingRestoredFocusIDs = restoredState?.focusedIDs ?? []
        pendingRestoredLastFocusID = restoredState?.lastFocusedID
        isScanning = true
        progressText = "ファイル一覧を読み込んでいます…"
        groups = []
        rebuildGroupedPhotos()
        let publishesIncrementalScanResults = url.path.hasPrefix("/Volumes/")
        let initialPresentationBatchSize = publishesIncrementalScanResults
            ? max(1, gridColumnCount)
            : Int.max
        let initialPresentationGroupTarget = publishesIncrementalScanResults
            ? initialScanPresentationGroupTarget
            : Int.max
        let reportScanProgress: @Sendable ([PhotoGroup], Int) -> Void = { [weak self] snapshot, fileCount in
            Task { @MainActor [weak self] in
                guard let self, self.currentScanToken == token, self.isScanning else { return }
                guard snapshot.count > self.groups.count else { return }
                let currentByID = self.groupByID
                let mergedSnapshot = snapshot.map { scannedGroup in
                    guard let current = currentByID[scannedGroup.id] else { return scannedGroup }
                    var merged = scannedGroup
                    merged.metadata = current.metadata
                    merged.captureDate = current.captureDate
                    merged.isMetadataLoaded = current.isMetadataLoaded
                    return merged
                }
                self.groups = mergedSnapshot
                self.rebuildGroupedPhotos()
                // The list is rendered incrementally while a source is being
                // scanned. Focus the first available photo as soon as the
                // first snapshot exists, instead of waiting for the entire
                // source scan to finish.
                if self.focusedIDs.isEmpty, self.pendingRestoredFocusIDs.isEmpty {
                    self.focusFirstVisiblePhoto()
                }
                self.progressText = "写真を探しています… \(snapshot.count)組 / \(fileCount)ファイル"
                self.enqueueMetadataLoading(
                    groups: mergedSnapshot,
                    token: token,
                    sourceScanFinished: false
                )
            }
        }
        scanTask = Task { [weak self] in
            await cancelledProcessing.waitForIOToStop()
            // A cancelled detached ImageIO read does not stop synchronously
            // executing decoder work. Wait for the old source's reads before
            // starting this source, otherwise a fast card-to-library switch
            // temporarily runs both sources at once.
            await MetadataLoadingCoordinator.shared.quiesce()
            await ThumbnailLoadingCoordinator.shared.quiesce()
            guard let self, self.currentScanToken == token else { return }

            // quiesce() intentionally leaves both coordinators closed so a
            // removable volume cannot receive new reads while it is being
            // detached. A new scan is the explicit hand-off to a live source;
            // reopen the coordinators before the scan publishes tiles whose
            // .task modifiers immediately enqueue metadata and thumbnails.
            MetadataLoadingCoordinator.shared.resumeAfterQuiesce()
            ThumbnailLoadingCoordinator.shared.beginSource(rootURL: url)

            // Do not expose the new source view until its ImageIO coordinators
            // are accepting requests. If sourceURL changes while quiesce() is
            // still in progress, the new SwiftUI tiles run their .task once,
            // receive a rejected subscription, and remain placeholders even
            // after the coordinator reopens.
            self.sourceURL = url
            self.sourceVolume = volume
            if self.isLibraryView, self.catalog == nil {
                self.catalog = try? CatalogStore(libraryRoot: url)
                self.catalogSummary = self.catalog?.summary()
                self.catalogIssues = self.catalog?.issues() ?? []
            }

            let directoryScanTask = Task.detached(priority: .userInitiated) {
                PhotoScanner.scan(
                    root: url,
                    initialPresentationBatchSize: initialPresentationBatchSize,
                    initialPresentationGroupTarget: initialPresentationGroupTarget,
                    progress: reportScanProgress
                )
            }
            self.directoryScanTask = directoryScanTask
            let scanned = await directoryScanTask.value
            guard self.currentScanToken == token else { return }
            self.directoryScanTask = nil
            self.flushPendingMetadata()
            let currentByID = self.groupByID
            let mergedScanned = scanned.map { scannedGroup in
                guard let current = currentByID[scannedGroup.id] else { return scannedGroup }
                var merged = scannedGroup
                merged.metadata = current.metadata
                merged.captureDate = current.captureDate
                merged.isMetadataLoaded = current.isMetadataLoaded
                return merged
            }
            self.groups = mergedScanned
            self.rebuildGroupedPhotos()
            let availableIDs = Set(mergedScanned.map(\.id))
            if !self.userMovedFocusForCurrentSource {
                let restoredIDs = self.pendingRestoredFocusIDs.intersection(availableIDs)
                if !restoredIDs.isEmpty {
                    self.focusedIDs = restoredIDs
                    self.lastFocusedID = self.pendingRestoredLastFocusID.flatMap {
                        availableIDs.contains($0) ? $0 : nil
                    } ?? restoredIDs.first
                    // A restored focus is the result of an earlier user
                    // navigation in this source. Import-state enrichment must
                    // not replace it with the first photo a moment later.
                    self.userMovedFocusForCurrentSource = true
                } else {
                    self.focusFirstVisiblePhoto()
                }
            }
            self.pendingRestoredFocusIDs.removeAll(keepingCapacity: true)
            self.pendingRestoredLastFocusID = nil
            self.isScanning = false
            self.progressText = "\(scanned.count)グループを表示中"
            if !self.isLibraryView,
               let catalog = self.catalog,
               let sourceVolume = self.sourceVolume,
               let volumeUUID = sourceVolume.volumeUUID {
                let migration = await Task.detached(priority: .utility) {
                    try? catalog.migrateSourceIdentities(groups: scanned, sourceRoot: url, volumeUUID: volumeUUID)
                }.value
                if let migration, migration.migratedCount > 0 {
                    self.progressText = "取り込み履歴を新しいカード識別子へ移行しました（\(migration.migratedCount)件）"
                }
            }
            self.enqueueMetadataLoading(
                groups: mergedScanned,
                token: token,
                sourceScanFinished: true
            )
            self.scheduleImportStateEnrichment(
                groups: mergedScanned,
                isLibraryView: self.isLibraryView,
                catalog: self.catalog,
                targetCatalog: self.targetCatalog,
                sourceRoot: self.sourceURL,
                targetRoot: self.libraryURL,
                volumeUUID: self.sourceVolume?.volumeUUID,
                token: token,
                inspectLibraryAfterEnrichment: self.isLibraryView
            )
            self.scanTask = nil
        }
    }

    func scan(camera descriptor: CameraDescriptor) {
        guard descriptor.isReady else {
            errorMessage = "カメラとの接続を準備しています。接続が完了すると写真一覧を開けます。"
            return
        }
        let cameraGroups = cameraMonitor.groups(for: descriptor.id) ?? []

        let cancelledProcessing = invalidateSourceProcessing()
        let token = currentScanToken
        let cameraURL = CameraMonitor.sourceURL(for: descriptor.id)
        if let previousSourcePath = sourceURL?.path {
            browsingStateBySourcePath[previousSourcePath] = SourceBrowsingState(
                importFilter: importFilter,
                operationFilter: operationFilter,
                focusedIDs: focusedIDs,
                lastFocusedID: lastFocusedID
            )
        }
        closeViewer()
        CameraThumbnailCoordinator.shared.cancelAll()
        userMovedFocusForCurrentSource = false
        focusedIDs.removeAll()
        focusBeforeFilter = nil
        lastFocusBeforeFilter = nil
        selectedIDs.removeAll()
        deleteCandidateIDs.removeAll()
        activeLabelIDs.removeAll()
        activeSavedLabelViewID = nil
        labels.removeAll()
        savedLabelViews.removeAll()
        photoIDsByLabelID.removeAll()
        let restoredState = browsingStateBySourcePath[cameraURL.path]
        importFilter = restoredState?.importFilter ?? .all
        operationFilter = restoredState?.operationFilter ?? .all
        pendingRestoredFocusIDs = restoredState?.focusedIDs ?? []
        pendingRestoredLastFocusID = restoredState?.lastFocusedID
        sourceURL = cameraURL
        sourceVolume = nil
        sourceCamera = descriptor
        isScanning = true
        progressText = cameraGroups.isEmpty
            ? "USBカメラの写真一覧を準備しています…"
            : String(cameraGroups.count) + "組を表示中・追加読み込み中"
        groups = cameraGroups
        rebuildGroupedPhotos()
        if !cameraGroups.isEmpty {
            focusFirstVisiblePhoto()
        }

        scanTask = Task { [weak self] in
            await cancelledProcessing.waitForIOToStop()
            await MetadataLoadingCoordinator.shared.quiesce()
            await ThumbnailLoadingCoordinator.shared.quiesce()
            guard let self, !Task.isCancelled, self.currentScanToken == token else { return }

            MetadataLoadingCoordinator.shared.resumeAfterQuiesce()
            ThumbnailLoadingCoordinator.shared.beginSource(rootURL: cameraURL)
            guard !Task.isCancelled, self.currentScanToken == token else { return }
            if !cameraGroups.isEmpty {
                self.updateVisibleCameraCatalog(descriptor, groups: cameraGroups, isComplete: !descriptor.isCataloging)
            } else if !descriptor.isCataloging {
                self.updateVisibleCameraCatalog(descriptor, groups: [], isComplete: true)
            }
            if self.currentScanToken == token {
                self.scanTask = nil
            }
        }
    }

    private func updateVisibleCameraCatalog(_ descriptor: CameraDescriptor, groups: [PhotoGroup], isComplete: Bool) {
        guard sourceCamera?.id == descriptor.id else { return }
        sourceCamera = descriptor
        guard sourceURL?.path == CameraMonitor.sourceURL(for: descriptor.id).path else { return }

        scanTask?.cancel()
        scanTask = nil
        self.groups = groups
        rebuildGroupedPhotos()
        if let importCatalog = targetCatalog {
            scheduleImportStateEnrichment(
                groups: groups,
                isLibraryView: false,
                catalog: importCatalog,
                targetCatalog: importCatalog,
                sourceRoot: sourceURL,
                targetRoot: libraryURL,
                volumeUUID: nil,
                token: currentScanToken
            )
        }
        let availableIDs = Set(groups.map(\.id))
        let retainedFocusedIDs = focusedIDs.intersection(availableIDs)
        if groups.isEmpty {
            focusedIDs.removeAll()
            lastFocusedID = nil
        } else if !retainedFocusedIDs.isEmpty {
            focusedIDs = retainedFocusedIDs
            if let lastFocusedID, retainedFocusedIDs.contains(lastFocusedID) == false {
                self.lastFocusedID = retainedFocusedIDs.first
            }
        } else if !userMovedFocusForCurrentSource {
            let restoredIDs = pendingRestoredFocusIDs.intersection(availableIDs)
            if !restoredIDs.isEmpty {
                focusedIDs = restoredIDs
                lastFocusedID = pendingRestoredLastFocusID.flatMap {
                    availableIDs.contains($0) ? $0 : nil
                } ?? restoredIDs.first
                userMovedFocusForCurrentSource = true
            } else if !groups.isEmpty {
                focusFirstVisiblePhoto()
            }
        } else if !groups.isEmpty {
            focusFirstVisiblePhoto()
        }
        pendingRestoredFocusIDs.removeAll(keepingCapacity: true)
        pendingRestoredLastFocusID = nil
        isScanning = !isComplete
        progressText = isComplete
            ? String(groups.count) + "組を表示中"
            : String(groups.count) + "組を表示中・追加読み込み中"
    }

    private func updateCameraMetadata(_ metadata: PhotoMetadata?, for groupID: String) {
        guard let index = groupIndexByID[groupID] else { return }
        var updated = groups[index]
        if let metadata {
            var merged = updated.metadata
            merged.captureDate = metadata.captureDate ?? merged.captureDate
            merged.cameraMake = metadata.cameraMake ?? merged.cameraMake
            merged.cameraModel = metadata.cameraModel ?? merged.cameraModel
            merged.lensModel = metadata.lensModel ?? merged.lensModel
            merged.focalLength = metadata.focalLength ?? merged.focalLength
            merged.aperture = metadata.aperture ?? merged.aperture
            merged.shutterSpeed = metadata.shutterSpeed ?? merged.shutterSpeed
            merged.iso = metadata.iso ?? merged.iso
            merged.exposureBias = metadata.exposureBias ?? merged.exposureBias
            merged.orientation = metadata.orientation ?? merged.orientation
            merged.gps = metadata.gps ?? merged.gps
            merged.firmware = metadata.firmware ?? merged.firmware
            merged.pixelWidth = metadata.pixelWidth ?? merged.pixelWidth
            merged.pixelHeight = metadata.pixelHeight ?? merged.pixelHeight
            updated.metadata = merged
            if let captureDate = merged.captureDate {
                updated.captureDate = captureDate
            }
        }
        updated.isMetadataLoaded = true
        groups[index] = updated
        rebuildGroupedPhotos()
    }

    @discardableResult
    private func invalidateSourceProcessing() -> CancelledSourceProcessing {
        let cancelled = CancelledSourceProcessing(
            scanTask: scanTask,
            directoryScanTask: directoryScanTask,
            scanStateTask: scanStateTask,
            scanStateWorkerTask: scanStateWorkerTask,
            catalogInspectionTask: catalogInspectionTask,
            catalogInspectionWorkerTask: catalogInspectionWorkerTask,
            catalogVerificationWorkerTask: catalogVerificationWorkerTask
        )
        currentScanToken = UUID()
        importStateRefreshToken = UUID()
        isImportStateRefreshing = false
        scanTask?.cancel()
        scanTask = nil
        directoryScanTask?.cancel()
        directoryScanTask = nil
        scanStateTask?.cancel()
        scanStateTask = nil
        scanStateWorkerTask?.cancel()
        scanStateWorkerTask = nil
        catalogInspectionTask?.cancel()
        catalogInspectionTask = nil
        catalogInspectionWorkerTask?.cancel()
        catalogInspectionWorkerTask = nil
        catalogVerificationWorkerTask?.cancel()
        catalogVerificationWorkerTask = nil
        metadataEnqueuedIDs.removeAll(keepingCapacity: true)
        metadataSourceScanFinished = false
        pendingMetadata.removeAll(keepingCapacity: true)
        completedMetadataIDs.removeAll(keepingCapacity: true)
        metadataTotal = 0
        metadataCompleted = 0
        return cancelled
    }

    private func handleUnmountedVolume(_ volumeURL: URL) {
        guard let sourceVolume else { return }
        let mountedPath = volumeURL.standardizedFileURL.path
        let sourceVolumePath = sourceVolume.url.standardizedFileURL.path
        guard mountedPath == sourceVolumePath else { return }

        let cancelledProcessing = invalidateSourceProcessing()
        closeViewer()
        groups.removeAll()
        groupedPhotos.removeAll()
        filteredGroupedPhotos.removeAll()
        focusedIDs.removeAll()
        selectedIDs.removeAll()
        deleteCandidateIDs.removeAll()
        sourceURL = nil
        self.sourceVolume = nil
        isScanning = false
        isBusy = false
        isCancellingImport = false
        importCancellation = nil
        importTask = nil
        operationProgress = nil
        progressText = "SDカードが取り外されました"
        Task {
            await cancelledProcessing.waitForIOToStop()
            await MetadataLoadingCoordinator.shared.quiesce()
            await ThumbnailLoadingCoordinator.shared.quiesce()
        }
    }

    private func handleRemovedCamera(_ cameraID: String) {
        guard sourceCamera?.id == cameraID else { return }
        let cancelledProcessing = invalidateSourceProcessing()
        closeViewer()
        groups.removeAll()
        groupedPhotos.removeAll()
        filteredGroupedPhotos.removeAll()
        focusedIDs.removeAll()
        selectedIDs.removeAll()
        deleteCandidateIDs.removeAll()
        sourceURL = nil
        sourceVolume = nil
        sourceCamera = nil
        isScanning = false
        isBusy = false
        isCancellingImport = false
        importCancellation = nil
        importTask = nil
        operationProgress = nil
        progressText = "USBカメラが取り外されました"
        Task {
            await cancelledProcessing.waitForIOToStop()
            await MetadataLoadingCoordinator.shared.quiesce()
            await ThumbnailLoadingCoordinator.shared.quiesce()
            CameraThumbnailCoordinator.shared.cancelAll()
        }
    }

    func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "写真の入ったSDカードまたはフォルダを選択してください"
        if panel.runModal() == .OK, let url = panel.url { scan(url: url) }
    }

    private func persistLibrarySelection() {
        guard usesPersistentState else { return }
        UserDefaults.standard.set(libraryURLs.map(\.path), forKey: "libraryURLs")
        if let libraryURL {
            UserDefaults.standard.set(libraryURL.path, forKey: "libraryURL")
        } else {
            UserDefaults.standard.removeObject(forKey: "libraryURL")
        }
    }

    private func registerLibrary(_ url: URL) -> URL {
        let normalizedURL = url.standardizedFileURL
        if !libraryURLs.contains(where: { $0.standardizedFileURL == normalizedURL }) {
            libraryURLs.append(normalizedURL)
        }
        guard usesPersistentState else { return normalizedURL }
        UserDefaults.standard.set(libraryURLs.map(\.path), forKey: "libraryURLs")
        return normalizedURL
    }

    func setTargetLibrary(_ url: URL) {
        guard !isBusy, !isScanning else {
            errorMessage = "処理中は保存先ライブラリを切り替えられません。"
            return
        }

        let normalizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = "ライブラリが見つかりません: \(normalizedURL.path)"
            return
        }

        let wasLibraryView = isLibraryView
        do {
            let targetCatalog = try CatalogStore(libraryRoot: normalizedURL)
            libraryURL = registerLibrary(normalizedURL)
            self.targetCatalog = targetCatalog
            persistLibrarySelection()
            progressText = "保存先ライブラリ: \(normalizedURL.lastPathComponent)"

            // While a library is open, `catalog` describes the library being
            // displayed. The target library is only a destination for a later
            // copy operation and must not replace the displayed catalog here;
            // doing so makes every source asset look like an unregistered EXT
            // asset when it is absent from the target catalog.
            if wasLibraryView {
                if let sourceURL {
                    scheduleImportStateEnrichment(
                        groups: groups,
                        isLibraryView: true,
                        catalog: catalog,
                        targetCatalog: targetCatalog,
                        sourceRoot: sourceURL,
                        targetRoot: normalizedURL,
                        volumeUUID: sourceVolume?.volumeUUID,
                        token: currentScanToken
                    )
                }
                return
            }

            catalog = targetCatalog
            catalogSummary = targetCatalog.summary()
            catalogIssues = targetCatalog.issues()

            // A card/folder view keeps its scanned groups and thumbnails. Only
            // the import-state fields need to be evaluated against the new
            // target catalog.
            if !wasLibraryView, let sourceURL {
                scheduleImportStateEnrichment(
                    groups: groups,
                    isLibraryView: false,
                    catalog: targetCatalog,
                    targetCatalog: targetCatalog,
                    sourceRoot: sourceURL,
                    targetRoot: normalizedURL,
                    volumeUUID: sourceVolume?.volumeUUID,
                    token: currentScanToken
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearTargetLibrary() {
        guard !isBusy, !isScanning else {
            errorMessage = "処理中は保存先ライブラリを切り替えられません。"
            return
        }
        guard libraryURL != nil else { return }

        let wasLibraryView = isLibraryView
        libraryURL = nil
        targetCatalog = nil
        persistLibrarySelection()
        progressText = "保存先ライブラリ未設定"

        // A library view keeps using its own catalog for EXT display, but its
        // target import flags must be refreshed as no longer imported.
        if wasLibraryView {
            if let sourceURL {
                scheduleImportStateEnrichment(
                    groups: groups,
                    isLibraryView: true,
                    catalog: catalog,
                    targetCatalog: nil,
                    sourceRoot: sourceURL,
                    targetRoot: nil,
                    volumeUUID: sourceVolume?.volumeUUID,
                    token: currentScanToken
                )
            }
            return
        }

        // In a card view there is no import-state catalog after the target is
        // cleared, so reset the displayed import flags against a nil catalog.
        catalog = nil
        catalogSummary = nil
        catalogIssues = []
        guard let sourceURL else { return }
        scheduleImportStateEnrichment(
            groups: groups,
            isLibraryView: false,
            catalog: nil,
            targetCatalog: nil,
            sourceRoot: sourceURL,
            targetRoot: nil,
            volumeUUID: sourceVolume?.volumeUUID,
            token: currentScanToken
        )
    }

    func openLibrary(_ url: URL) {
        // Source scans are cancellable: scan(url:) invalidates the current
        // token and waits for the old metadata/thumbnail I/O before exposing
        // the library. Only an actual file operation must block navigation.
        guard !isBusy else {
            errorMessage = "処理中はライブラリを切り替えられません。"
            return
        }

        let normalizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = "ライブラリが見つかりません: \(normalizedURL.path)"
            return
        }

        do {
            let store = try CatalogStore(libraryRoot: normalizedURL)
            closeViewer()
            let wasTargetUnset = libraryURL == nil
            _ = registerLibrary(normalizedURL)
            if wasTargetUnset {
                libraryURL = normalizedURL
                persistLibrarySelection()
            }
            catalog = store
            if libraryURL?.standardizedFileURL == normalizedURL {
                targetCatalog = store
            } else if let targetRoot = libraryURL {
                targetCatalog = try? CatalogStore(libraryRoot: targetRoot)
            } else {
                targetCatalog = nil
            }
            catalogSummary = store.summary()
            catalogIssues = store.issues()
            scan(url: normalizedURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "ライブラリのフォルダを選択するか、新規フォルダを作成してください"
        panel.prompt = "ライブラリを開く"
        if panel.runModal() == .OK, let url = panel.url {
            openLibrary(url)
        }
    }

    func chooseTargetLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "保存先ライブラリのフォルダを選択するか、新規フォルダを作成してください"
        panel.prompt = "保存先に設定"
        if panel.runModal() == .OK, let url = panel.url {
            setTargetLibrary(url)
        }
    }

    func showLibrary() {
        guard let libraryURL else { errorMessage = AppError.noLibrary.localizedDescription; return }
        openLibrary(libraryURL)
    }

    func inspectLibrary() {
        guard let libraryURL = catalogRootURL else { errorMessage = AppError.noLibrary.localizedDescription; return }
        let store: CatalogStore
        if let catalog {
            store = catalog
        } else {
            guard let created = try? CatalogStore(libraryRoot: libraryURL) else {
                errorMessage = AppError.cannotOpenCatalog(libraryURL).localizedDescription
                return
            }
            catalog = created
            store = created
        }
        catalogInspectionTask?.cancel()
        catalogInspectionWorkerTask?.cancel()
        isCatalogInspecting = true
        catalogInspectionTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { try? store.inspectLibrary() }
            self?.catalogInspectionWorkerTask = worker
            let result = await worker.value
            guard let self else { return }
            guard let result else {
                self.isCatalogInspecting = false
                self.catalogInspectionWorkerTask = nil
                self.catalogInspectionTask = nil
                guard !worker.isCancelled else { return }
                self.errorMessage = "ライブラリの検査に失敗しました。"
                return
            }
            guard self.catalogRootURL?.standardizedFileURL == libraryURL.standardizedFileURL else { return }
            self.catalogSummary = result.summary
            self.catalogIssues = result.issues
            self.isCatalogInspecting = false
            self.groups = self.groups.map { self.withImportState($0) }
            self.rebuildGroupedPhotos()
            self.catalogInspectionWorkerTask = nil
            self.catalogInspectionTask = nil
        }
    }

    func registerUnregisteredLibraryPhotos() {
        guard isLibraryView, let catalog else { return }
        let candidates = groups.filter { $0.libraryAssetStatus != .registered }
        guard !candidates.isEmpty else { progressText = "未登録の写真はありません"; return }
        do {
            try catalog.registerLibraryAssets(candidates)
            groups = groups.map { withImportState($0) }
            refreshLabelData()
            catalogSummary = catalog.summary()
            catalogIssues = catalog.issues()
            rebuildGroupedPhotos()
            progressText = "\(candidates.count)組を管理対象に登録しました"
        } catch { errorMessage = error.localizedDescription }
    }

    func relinkCatalogIssue(_ issue: CatalogIssue, to candidateURL: URL) {
        guard let catalog else { return }
        do {
            try catalog.relink(issueID: issue.id, to: candidateURL)
            catalogIssues = catalog.issues()
            catalogSummary = catalog.summary()
            groups = groups.map { withImportState($0) }
            refreshLabelData()
            rebuildGroupedPhotos()
            progressText = "\(candidateURL.lastPathComponent)を紐付けました"
        } catch { errorMessage = error.localizedDescription }
    }

    func forgetCatalogIssue(_ issue: CatalogIssue) {
        guard let catalog else { return }
        do {
            try catalog.forget(issueID: issue.id)
            catalogIssues = catalog.issues()
            catalogSummary = catalog.summary()
            groups = groups.map { withImportState($0) }
            refreshLabelData()
            rebuildGroupedPhotos()
            progressText = "\(issue.lastKnownURL.lastPathComponent)の履歴を削除しました"
        } catch { errorMessage = error.localizedDescription }
    }

    func recopyCatalogIssue(_ issue: CatalogIssue) {
        guard let libraryURL = catalogRootURL, let catalog else { return }
        let transfer = FileTransferService.shared
        guard let sourceGroup = groups.first(where: {
            guard let url = $0.url(for: issue.variant) else { return false }
            return transfer.sourceKey(for: $0, variant: issue.variant, sourceRoot: sourceURL, volumeUUID: sourceVolume?.volumeUUID) == issue.sourceKey ||
                SourceIdentity.legacyKey(url: url, variant: issue.variant) == issue.sourceKey
        }) else {
            errorMessage = "元のSDカードまたはフォルダを開いてから再コピーしてください。"
            return
        }
        guard !isBusy else { return }
        isBusy = true
        progressText = "再コピー中…"
        let template = importTemplate
        let sourceRoot = sourceURL
        let volumeUUID = sourceVolume?.volumeUUID
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                try? transfer.importGroup(
                    sourceGroup,
                    to: libraryURL,
                    template: template,
                    catalog: catalog,
                    sourceRoot: sourceRoot,
                    volumeUUID: volumeUUID
                )
            }.value
            guard let self else { return }
            self.isBusy = false
            if let result, result.failedCount == 0 {
                self.catalogIssues = catalog.issues()
                self.catalogSummary = catalog.summary()
                self.progressText = "再コピーしました"
            } else {
                self.errorMessage = result?.message ?? "再コピーに失敗しました。"
            }
        }
    }

    func searchCandidates(for issue: CatalogIssue) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "再リンク候補を探すフォルダを選択してください"
        guard panel.runModal() == .OK, let folder = panel.url, let catalog else { return }
        do {
            _ = try catalog.findCandidates(for: issue, in: folder)
            catalogIssues = catalog.issues()
            catalogSummary = catalog.summary()
            progressText = "候補を検索しました"
        } catch { errorMessage = error.localizedDescription }
    }

    func backupCatalog(to destinationURL: URL) {
        guard let catalog else { errorMessage = "カタログがありません。"; return }
        do {
            try catalog.backup(to: destinationURL)
            progressText = "カタログをバックアップしました"
        } catch { errorMessage = error.localizedDescription }
    }

    func verifyCatalog() {
        guard let catalog else { errorMessage = "カタログがありません。"; return }
        catalogInspectionTask?.cancel()
        catalogVerificationWorkerTask?.cancel()
        isCatalogInspecting = true
        catalogInspectionTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                Task.isCancelled ? nil : catalog.integrityReport()
            }
            self?.catalogVerificationWorkerTask = worker
            guard let result = await worker.value else { return }
            guard let self else { return }
            self.progressText = result == "ok" ? "ファイルとSQLiteの完全検査が完了しました" : result
            self.isCatalogInspecting = false
            self.catalogVerificationWorkerTask = nil
            self.catalogInspectionTask = nil
        }
    }

    func showCatalogInFinder() {
        guard let catalog else { return }
        NSWorkspace.shared.activateFileViewerSelecting([catalog.catalogDirectoryURL])
    }

    func importSelected(to destination: URL, template: String) {
        guard !selectedGroups.isEmpty else { errorMessage = AppError.noSelectedPhotos.localizedDescription; return }
        if isCameraSource {
            importSelectedFromCamera(to: destination, template: template)
            return
        }
        isBusy = true
        lastImportResults = []
        importTemplate = template
        let destinationURL = registerLibrary(destination)
        libraryURL = destinationURL
        persistLibrarySelection()
        do {
            let store = try CatalogStore(libraryRoot: destinationURL)
            catalog = store
            targetCatalog = store
            let groupsToImport = selectedGroups
            let sourceRoot = self.sourceURL
            let volumeUUID = self.sourceVolume?.volumeUUID
            let operationToken = currentScanToken
            let totalImportFiles = groupsToImport.reduce(0) { count, group in
                count + [group.jpegURL, group.rawURL].compactMap { $0 }.count
            }
            operationProgress = OperationProgress(
                title: "取り込み中",
                completedGroups: 0,
                totalGroups: groupsToImport.count,
                completedFiles: 0,
                totalFiles: totalImportFiles
            )
            let cancellation = ImportCancellationToken()
            importCancellation = cancellation
            isCancellingImport = false
            importTask = Task { [weak self] in
                guard let self else { return }
                var results: [ImportResult] = []
                var nextIndex = 0
                var completed = 0
                var completedFiles = 0
                let maxConcurrentImports = min(2, groupsToImport.count)

                await withTaskGroup(of: ImportResult.self) { taskGroup in
                    for _ in 0..<maxConcurrentImports {
                        let group = groupsToImport[nextIndex]
                        nextIndex += 1
                        taskGroup.addTask(priority: .userInitiated) {
                            await Task.detached(priority: .userInitiated) {
                                try? FileTransferService.shared.importGroup(
                                    group,
                                    to: destination,
                                    template: template,
                                    catalog: store,
                                    cancellation: cancellation,
                                    sourceRoot: sourceRoot,
                                    volumeUUID: volumeUUID
                                )
                            }.value ?? ImportResult(groupID: group.id, message: "取り込みに失敗しました", copiedCount: 0, skippedCount: 0, failedCount: 1)
                        }
                    }

                    while let result = await taskGroup.next() {
                        if cancellation.isCancelled {
                            taskGroup.cancelAll()
                            break
                        }
                        guard self.currentScanToken == operationToken else {
                            taskGroup.cancelAll()
                            return
                        }
                        results.append(result)
                        completed += 1
                        let completedGroup = groupsToImport.first(where: { $0.id == result.groupID })
                        completedFiles += [completedGroup?.jpegURL, completedGroup?.rawURL].compactMap { $0 }.count
                        let basename = completedGroup?.basename ?? result.groupID
                        self.operationProgress = OperationProgress(
                            title: "取り込み中",
                            completedGroups: completed,
                            totalGroups: groupsToImport.count,
                            completedFiles: completedFiles,
                            totalFiles: totalImportFiles
                        )
                        self.progressText = "取り込み中… \(completed)/\(groupsToImport.count)  \(basename)"
                        self.updateImportState(for: result.groupID)

                        if nextIndex < groupsToImport.count {
                            let group = groupsToImport[nextIndex]
                            nextIndex += 1
                            taskGroup.addTask(priority: .userInitiated) {
                                await Task.detached(priority: .userInitiated) {
                                    try? FileTransferService.shared.importGroup(
                                        group,
                                        to: destination,
                                        template: template,
                                        catalog: store,
                                        cancellation: cancellation,
                                        sourceRoot: sourceRoot,
                                        volumeUUID: volumeUUID
                                    )
                                }.value ?? ImportResult(groupID: group.id, message: "取り込みに失敗しました", copiedCount: 0, skippedCount: 0, failedCount: 1)
                            }
                        }
                    }
                }
                guard self.currentScanToken == operationToken else { return }
                self.lastImportResults = results
                self.isBusy = false
                self.isCancellingImport = false
                self.importCancellation = nil
                self.importTask = nil
                self.operationProgress = nil
                if cancellation.isCancelled {
                    self.focusNextPendingImport()
                    self.progressText = "取り込みを中断しました（\(completed)/\(groupsToImport.count)組）"
                    return
                }
                let failures = results.filter { $0.failedCount > 0 }.count
                self.focusNextPendingImport()
                self.progressText = failures == 0 ? "取り込みが完了しました" : "取り込み完了（一部失敗あり）"
            }
        } catch {
            isBusy = false
            operationProgress = nil
            errorMessage = error.localizedDescription
        }
    }

    private func importSelectedFromCamera(to destination: URL, template: String) {
        guard sourceCamera != nil else {
            errorMessage = "USBカメラが選択されていません。"
            return
        }
        isBusy = true
        lastImportResults = []
        importTemplate = template
        let destinationURL = registerLibrary(destination)
        libraryURL = destinationURL
        persistLibrarySelection()

        do {
            let store = try CatalogStore(libraryRoot: destinationURL)
            catalog = store
            targetCatalog = store
            let groupsToImport = selectedGroups
            let operationToken = currentScanToken
            let totalImportFiles = groupsToImport.reduce(0) { $0 + $1.importableVariants.count }
            operationProgress = OperationProgress(
                title: "取り込み中",
                completedGroups: 0,
                totalGroups: groupsToImport.count,
                completedFiles: 0,
                totalFiles: totalImportFiles
            )
            let cancellation = ImportCancellationToken()
            importCancellation = cancellation
            isCancellingImport = false
            importTask = Task { [weak self] in
                guard let self else { return }
                var results: [ImportResult] = []
                var completed = 0
                var completedFiles = 0

                for group in groupsToImport {
                    guard !cancellation.isCancelled,
                          self.currentScanToken == operationToken else { break }
                    let result = await self.importCameraGroup(
                        group,
                        destination: destinationURL,
                        template: template,
                        catalog: store,
                        cancellation: cancellation
                    )
                    results.append(result)
                    completed += 1
                    completedFiles += group.importableVariants.count
                    self.operationProgress = OperationProgress(
                        title: "取り込み中",
                        completedGroups: completed,
                        totalGroups: groupsToImport.count,
                        completedFiles: completedFiles,
                        totalFiles: totalImportFiles
                    )
                    self.progressText = "取り込み中… \(completed)/\(groupsToImport.count)  \(group.basename)"
                    if result.failedCount == 0 && !group.importableVariants.isEmpty {
                        self.markCameraGroupImported(group.id)
                    }
                }

                guard self.currentScanToken == operationToken else { return }
                self.lastImportResults = results
                self.isBusy = false
                self.isCancellingImport = false
                self.importCancellation = nil
                self.importTask = nil
                self.operationProgress = nil
                if cancellation.isCancelled {
                    self.focusNextPendingImport()
                    self.progressText = "取り込みを中断しました（\(completed)/\(groupsToImport.count)組）"
                    return
                }
                let failures = results.filter { $0.failedCount > 0 }.count
                self.focusNextPendingImport()
                self.progressText = failures == 0 ? "取り込みが完了しました" : "取り込み完了（一部失敗あり）"
            }
        } catch {
            isBusy = false
            operationProgress = nil
            errorMessage = error.localizedDescription
        }
    }

    private func importCameraGroup(
        _ group: PhotoGroup,
        destination: URL,
        template: String,
        catalog: CatalogStore,
        cancellation: ImportCancellationToken
    ) async -> ImportResult {
        let date = group.metadata.captureDate ?? group.captureDate ?? Date()
        let folderName = FileTransferService.shared.makeFolderName(
            template: template,
            date: date,
            camera: group.metadata.cameraModel ?? "EOS R"
        )
        let destinationDirectory = destination.appendingPathComponent(folderName, isDirectory: true)
        do {
            try cancellation.check()
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            var copied = 0
            var skipped = 0
            var failed = 0
            var messages: [String] = []

            for variant in group.importableVariants {
                try cancellation.check()
                guard let asset = group.cameraReference?.asset(for: variant) else { continue }
                var partialURL: URL?
                do {
                    partialURL = try await cameraMonitor.download(
                        group: group,
                        variant: variant,
                        to: destinationDirectory,
                        filename: ".photokichin-partial-\(UUID().uuidString)"
                    )
                    let destinationURL = destinationDirectory.appendingPathComponent(asset.filename)
                    let sourceKey = cameraMonitor.catalogSourceKey(for: group, variant: variant)
                    let installed = try await Task.detached(priority: .userInitiated) {
                        try FileTransferService.shared.installCameraDownloadedFile(
                            partialURL: partialURL!,
                            destinationURL: destinationURL,
                            variant: variant,
                            sourceKey: sourceKey,
                            sourceFilename: asset.filename,
                            catalog: catalog,
                            expectedFileSize: asset.fileSize,
                            cancellation: cancellation
                        )
                    }.value
                    partialURL = nil
                    if installed { copied += 1 } else { skipped += 1 }
                } catch is CancellationError {
                    if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
                    throw CancellationError()
                } catch {
                    if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
                    failed += 1
                    messages.append("\(asset.filename): \(error.localizedDescription)")
                }
            }

            let message = messages.isEmpty
                ? "\(group.basename): \(copied)件取り込み、\(skipped)件スキップ"
                : "\(group.basename): \(messages.joined(separator: " / "))"
            return ImportResult(groupID: group.id, message: message, copiedCount: copied, skippedCount: skipped, failedCount: failed)
        } catch is CancellationError {
            return ImportResult(
                groupID: group.id,
                message: "取り込みを中断しました",
                copiedCount: 0,
                skippedCount: 0,
                failedCount: 1
            )
        } catch {
            return ImportResult(
                groupID: group.id,
                message: error.localizedDescription,
                copiedCount: 0,
                skippedCount: 0,
                failedCount: 1
            )
        }
    }

    private func markCameraGroupImported(_ groupID: String) {
        guard let index = groupIndexByID[groupID] else { return }
        var updated = groups[index]
        if updated.importableVariants.contains(.jpeg) { updated.importedJPEG = true }
        if updated.importableVariants.contains(.raw) { updated.importedRAW = true }
        groups[index] = updated
        rebuildGroupedPhotos()
    }

    func cancelImport() {
        guard isBusy,
              ["取り込み中", "ライブラリへコピー中"].contains(operationProgress?.title),
              !isCancellingImport else { return }
        isCancellingImport = true
        progressText = "取り込みを中断しています…"
        importCancellation?.cancel()
        importTask?.cancel()
    }

    func copySelectedToTargetLibrary() {
        guard canCopyToTargetLibrary,
              let sourceRoot = sourceURL,
              let targetRoot = libraryURL,
              let sourceCatalog = catalog else {
            errorMessage = "コピー元とコピー先のライブラリを確認してください。"
            return
        }
        guard !isBusy else { return }

        do {
            let targetCatalog = try CatalogStore(libraryRoot: targetRoot)
            let groupsToCopy = selectedGroups
            let copyLabels = copyLabelsOnLibraryCopy
            let operationToken = currentScanToken
            let totalFiles = groupsToCopy.reduce(0) { count, group in
                count + [group.jpegURL, group.rawURL].compactMap { $0 }.count
            }
            isBusy = true
            operationProgress = OperationProgress(
                title: "ライブラリへコピー中",
                completedGroups: 0,
                totalGroups: groupsToCopy.count,
                completedFiles: 0,
                totalFiles: totalFiles
            )
            progressText = "\(targetRoot.lastPathComponent)へコピー中…"
            let cancellation = ImportCancellationToken()
            importCancellation = cancellation
            isCancellingImport = false
            importTask = Task { [weak self] in
                guard let self else { return }
                var results: [ImportResult] = []
                var nextIndex = 0
                var completed = 0
                var completedFiles = 0
                let maxConcurrentCopies = min(2, groupsToCopy.count)

                await withTaskGroup(of: ImportResult.self) { taskGroup in
                    for _ in 0..<maxConcurrentCopies {
                        let group = groupsToCopy[nextIndex]
                        nextIndex += 1
                        taskGroup.addTask(priority: .userInitiated) {
                            await Task.detached(priority: .userInitiated) {
                                try? FileTransferService.shared.copyLibraryGroup(
                                    group,
                                    from: sourceRoot,
                                    to: targetRoot,
                                    sourceCatalog: sourceCatalog,
                                    destinationCatalog: targetCatalog,
                                    copyLabels: copyLabels,
                                    cancellation: cancellation
                                )
                            }.value ?? ImportResult(groupID: group.id, message: "ライブラリ間コピーに失敗しました", copiedCount: 0, skippedCount: 0, failedCount: 1)
                        }
                    }

                    while let result = await taskGroup.next() {
                        if cancellation.isCancelled {
                            taskGroup.cancelAll()
                            break
                        }
                        guard self.currentScanToken == operationToken else {
                            taskGroup.cancelAll()
                            return
                        }
                        results.append(result)
                        completed += 1
                        let completedGroup = groupsToCopy.first(where: { $0.id == result.groupID })
                        completedFiles += [completedGroup?.jpegURL, completedGroup?.rawURL].compactMap { $0 }.count
                        self.operationProgress = OperationProgress(
                            title: "ライブラリへコピー中",
                            completedGroups: completed,
                            totalGroups: groupsToCopy.count,
                            completedFiles: completedFiles,
                            totalFiles: totalFiles
                        )
                        self.progressText = "\(targetRoot.lastPathComponent)へコピー中… \(completed)/\(groupsToCopy.count)"

                        if nextIndex < groupsToCopy.count {
                            let group = groupsToCopy[nextIndex]
                            nextIndex += 1
                            taskGroup.addTask(priority: .userInitiated) {
                                await Task.detached(priority: .userInitiated) {
                                    try? FileTransferService.shared.copyLibraryGroup(
                                        group,
                                        from: sourceRoot,
                                        to: targetRoot,
                                        sourceCatalog: sourceCatalog,
                                        destinationCatalog: targetCatalog,
                                        copyLabels: copyLabels,
                                        cancellation: cancellation
                                    )
                                }.value ?? ImportResult(groupID: group.id, message: "ライブラリ間コピーに失敗しました", copiedCount: 0, skippedCount: 0, failedCount: 1)
                            }
                        }
                    }
                }

                guard self.currentScanToken == operationToken else { return }
                self.isBusy = false
                self.isCancellingImport = false
                self.importCancellation = nil
                self.importTask = nil
                self.operationProgress = nil
                if cancellation.isCancelled {
                    self.progressText = "ライブラリ間コピーを中断しました（\(completed)/\(groupsToCopy.count)組）"
                    return
                }
                let failures = results.filter { $0.failedCount > 0 }.count
                self.progressText = failures == 0
                    ? "\(targetRoot.lastPathComponent)へのコピーが完了しました"
                    : "\(targetRoot.lastPathComponent)へのコピー完了（一部失敗あり）"
                if failures > 0 {
                    self.errorMessage = results.filter { $0.failedCount > 0 }.map(\.message).joined(separator: " / ")
                }
            }
        } catch {
            isBusy = false
            operationProgress = nil
            errorMessage = error.localizedDescription
        }
    }

    func deleteCandidatesFromCard() {
        guard sourceVolume != nil else {
            errorMessage = "削除対象のソースが選択されていません。"
            return
        }
        guard !deleteCandidateGroups.isEmpty else { errorMessage = AppError.noDeleteCandidates.localizedDescription; return }
        let groupsToDelete = deleteCandidateGroups
        let cancelledProcessing = invalidateSourceProcessing()
        let operationToken = currentScanToken
        isBusy = true
        let fileCount = groupsToDelete.reduce(0) { count, group in
            count + [group.jpegURL, group.rawURL].compactMap { $0 }.count
        }
        operationProgress = OperationProgress(
            title: "ゴミ箱へ移動中",
            completedGroups: 0,
            totalGroups: groupsToDelete.count,
            completedFiles: 0,
            totalFiles: fileCount
        )
        progressText = "\(fileCount)ファイルをゴミ箱へ移動中…"
        Task { [weak self] in
            await cancelledProcessing.waitForIOToStop()
            await MetadataLoadingCoordinator.shared.quiesce()
            await ThumbnailLoadingCoordinator.shared.quiesce()
            guard let self, self.currentScanToken == operationToken else { return }
            let result = await FileTransferService.shared.moveGroupsToTrash(groupsToDelete) { [weak self] completedGroups, totalGroups, completedFiles, totalFiles in
                Task { @MainActor [weak self] in
                    guard let self, self.isBusy else { return }
                    self.operationProgress = OperationProgress(
                        title: "ゴミ箱へ移動中",
                        completedGroups: completedGroups,
                        totalGroups: totalGroups,
                        completedFiles: completedFiles,
                        totalFiles: totalFiles
                    )
                }
            }
            // The card remains mounted after a trash operation. Reopen both
            // read coordinators before the surviving tiles are rebuilt;
            // otherwise their .task modifiers would stay permanently blocked
            // by the safety barrier used during the operation.
            MetadataLoadingCoordinator.shared.resumeAfterQuiesce()
            ThumbnailLoadingCoordinator.shared.resumeAfterQuiesce()
            guard self.currentScanToken == operationToken else { return }
            self.groups.removeAll { result.completedGroupIDs.contains($0.id) }
            self.rebuildGroupedPhotos()
            self.focusedIDs.subtract(result.completedGroupIDs)
            self.selectedIDs.subtract(result.completedGroupIDs)
            self.deleteCandidateIDs.subtract(result.completedGroupIDs)
            self.isBusy = false
            self.operationProgress = nil
            if result.failedFileCount == 0 {
                self.progressText = "\(result.completedGroupIDs.count)グループをゴミ箱へ移動しました"
            } else {
                self.progressText = "ゴミ箱へ\(result.movedFileCount)件移動、\(result.failedFileCount)件失敗"
                self.errorMessage = result.errorMessage ?? "一部のファイルをゴミ箱へ移動できませんでした。"
            }
        }
    }

    /// Called only by the explicit destructive confirmation in the UI.
    func deleteCandidatesAfterConfirmation() {
        guard canDeleteSourceFiles else {
            errorMessage = "このソースのファイル削除には対応していません。"
            return
        }
        if sourceCamera != nil {
            deleteCandidatesFromCamera()
        } else {
            deleteCandidatesFromCard()
        }
    }

    private func deleteCandidatesFromCamera() {
        guard let sourceCamera,
              sourceCamera.canDeleteFiles else {
            errorMessage = "このカメラはファイル削除に対応していません。"
            return
        }
        guard !deleteCandidateGroups.isEmpty else {
            errorMessage = AppError.noDeleteCandidates.localizedDescription
            return
        }

        let groupsToDelete = deleteCandidateGroups
        let cancelledProcessing = invalidateSourceProcessing()
        let operationToken = currentScanToken
        let totalFiles = groupsToDelete.reduce(0) { $0 + $1.importableVariants.count }
        isBusy = true
        operationProgress = OperationProgress(
            title: "カメラから削除中",
            completedGroups: 0,
            totalGroups: groupsToDelete.count,
            completedFiles: 0,
            totalFiles: totalFiles
        )
        progressText = "カメラから\(totalFiles)ファイルを削除中…"

        Task { [weak self] in
            await cancelledProcessing.waitForIOToStop()
            await MetadataLoadingCoordinator.shared.quiesce()
            await ThumbnailLoadingCoordinator.shared.quiesce()
            guard let self, self.currentScanToken == operationToken else { return }

            var completedGroups = 0
            var processedFiles = 0
            var failedFiles = 0
            var failureMessages: [String] = []

            for group in groupsToDelete {
                var groupFailed = false
                for variant in group.importableVariants {
                    do {
                        try await self.cameraMonitor.delete(group: group, variant: variant)
                    } catch {
                        groupFailed = true
                        failedFiles += 1
                        failureMessages.append("\(group.basename) \(variant.rawValue): \(error.localizedDescription)")
                    }
                    processedFiles += 1
                    self.operationProgress = OperationProgress(
                        title: "カメラから削除中",
                        completedGroups: completedGroups,
                        totalGroups: groupsToDelete.count,
                        completedFiles: processedFiles,
                        totalFiles: totalFiles
                    )
                }
                if !groupFailed { completedGroups += 1 }
                self.operationProgress = OperationProgress(
                    title: "カメラから削除中",
                    completedGroups: completedGroups,
                    totalGroups: groupsToDelete.count,
                    completedFiles: processedFiles,
                    totalFiles: totalFiles
                )
            }

            guard self.currentScanToken == operationToken else { return }
            self.isBusy = false
            self.operationProgress = nil
            self.deleteCandidateIDs.removeAll()
            if failedFiles == 0 {
                self.progressText = "\(completedGroups)組をカメラから削除しました"
            } else {
                self.progressText = "カメラからの削除完了（\(failedFiles)件失敗）"
                self.errorMessage = failureMessages.prefix(3).joined(separator: "\n")
            }

            if let refreshedDescriptor = self.cameraMonitor.descriptor(for: sourceCamera.id) {
                self.scan(camera: refreshedDescriptor)
            }
        }
    }

    func airDrop(mode: AirDropMode) {
        guard !selectedGroups.isEmpty else { errorMessage = AppError.noSelectedPhotos.localizedDescription; return }
        guard airDropSession == nil, !isBusy else { return }
        do {
            let session = try FileTransferService.shared.airDrop(selectedGroups, mode: mode) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.airDropSession = nil
                    self.isBusy = false
                    if let error {
                        self.errorMessage = "AirDropに失敗しました: \(error.localizedDescription)"
                    } else {
                        self.progressText = "AirDropが完了しました"
                    }
                }
            }
            airDropSession = session
            isBusy = true
            let sourceTitle = isLibraryView ? "ライブラリの写真" : "カードまたはフォルダの写真"
            progressText = "\(sourceTitle)をAirDrop中（完了まで元ファイルを移動しないでください）"
        } catch { errorMessage = error.localizedDescription }
    }

    func ejectCurrentVolume() {
        if let sourceCamera {
            guard sourceCamera.canEject else {
                errorMessage = "このカメラは安全な取り出しに対応していません。"
                return
            }
            guard !isBusy, !isScanning else {
                errorMessage = "処理が終わるまでEjectできません。"
                return
            }

            let camera = sourceCamera
            let operationToken = currentScanToken
            isBusy = true
            progressText = "カメラへのIOを停止しています…"
            Task { [weak self] in
                await MetadataLoadingCoordinator.shared.quiesce()
                await ThumbnailLoadingCoordinator.shared.quiesce()

                guard let self,
                      self.currentScanToken == operationToken,
                      self.sourceCamera?.id == camera.id else {
                    MetadataLoadingCoordinator.shared.resumeAfterQuiesce()
                    ThumbnailLoadingCoordinator.shared.resumeAfterQuiesce()
                    self?.isBusy = false
                    return
                }

                self.progressText = "安全にEjectしています…"
                do {
                    try await self.cameraMonitor.eject(id: camera.id)
                    MetadataLoadingCoordinator.shared.resumeAfterQuiesce()
                    ThumbnailLoadingCoordinator.shared.resumeAfterQuiesce()
                    self.groups.removeAll()
                    self.selectedIDs.removeAll()
                    self.focusedIDs.removeAll()
                    self.deleteCandidateIDs.removeAll()
                    self.sourceURL = nil
                    self.sourceCamera = nil
                    self.isBusy = false
                    self.progressText = "Ejectしました"
                } catch {
                    MetadataLoadingCoordinator.shared.resumeAfterQuiesce()
                    ThumbnailLoadingCoordinator.shared.resumeAfterQuiesce()
                    self.isBusy = false
                    self.errorMessage = error.localizedDescription
                }
            }
            return
        }

        guard let sourceURL, sourceVolume != nil else { errorMessage = AppError.noSource.localizedDescription; return }
        guard !isBusy, !isScanning else { errorMessage = "処理が終わるまでEjectできません。"; return }
        let sourceVolume = self.sourceVolume
        let operationToken = currentScanToken
        isBusy = true
        progressText = "カードへのIOを停止しています…"
        Task { [weak self] in
            // Detached reads must return so their file descriptors are
            // closed before Disk Arbitration is called.
            await MetadataLoadingCoordinator.shared.quiesce()
            await ThumbnailLoadingCoordinator.shared.quiesce()

            guard let self,
                  self.currentScanToken == operationToken,
                  self.sourceURL?.standardizedFileURL == sourceURL.standardizedFileURL else {
                MetadataLoadingCoordinator.shared.resumeAfterQuiesce()
                ThumbnailLoadingCoordinator.shared.resumeAfterQuiesce()
                self?.isBusy = false
                return
            }

            self.progressText = "安全にEjectしています…"
            do {
                try await VolumeEjector.eject(volumeURL: sourceURL)
                self.groups = []
                self.selectedIDs.removeAll()
                self.focusedIDs.removeAll()
                self.deleteCandidateIDs.removeAll()
                self.sourceURL = nil
                self.sourceVolume = nil
                self.volumeMonitor.refresh()
                self.progressText = "Ejectしました"
                self.isBusy = false
            } catch {
                // The card remains mounted when Disk Arbitration rejects the
                // request. Re-enable the coordinators and rescan so cancelled
                // observers and in-flight metadata are rebuilt consistently.
                MetadataLoadingCoordinator.shared.resumeAfterQuiesce()
                ThumbnailLoadingCoordinator.shared.resumeAfterQuiesce()
                self.isBusy = false
                self.errorMessage = error.localizedDescription
                if self.currentScanToken == operationToken,
                   let sourceVolume,
                   self.sourceURL?.standardizedFileURL == sourceURL.standardizedFileURL {
                    self.scan(url: sourceURL, volume: sourceVolume)
                }
            }
        }
    }

    func focus(_ group: PhotoGroup, modifiers: NSEvent.ModifierFlags = []) {
        userMovedFocusForCurrentSource = true
        if modifiers.contains(.shift), let lastFocusedID,
            let firstIndex = groupIndexByID[lastFocusedID],
            let lastIndex = groupIndexByID[group.id] {
            let lower = min(firstIndex, lastIndex)
            let upper = max(firstIndex, lastIndex)
            focusedIDs.formUnion(groups[lower...upper].map(\.id))
        } else if modifiers.contains(.command) {
            if focusedIDs.contains(group.id) { focusedIDs.remove(group.id) } else { focusedIDs.insert(group.id) }
        } else {
            focusedIDs = [group.id]
        }
        lastFocusedID = group.id
        requestMetadataForCurrentCameraFocus()
    }

    func setFocus(ids: Set<String>) {
        userMovedFocusForCurrentSource = true
        focusedIDs = ids
        lastFocusedID = groups.first(where: { ids.contains($0.id) })?.id
        requestMetadataForCurrentCameraFocus()
    }

    func toggleFocusedSelection() {
        guard !focusedIDs.isEmpty else { return }
        toggleSelection(for: focusedIDs)
    }

    func toggleFocusedDeleteCandidate() {
        guard canDeleteSourceFiles, !focusedIDs.isEmpty else { return }
        toggleDeleteCandidate(for: focusedIDs)
    }

    func selectAll() {
        selectedIDs = Set(groups.map(\.id))
        deleteCandidateIDs.removeAll()
        lastFocusedID = groups.first?.id
    }

    func clearSelection() { selectedIDs.removeAll() }
    func clearDeleteCandidates() { deleteCandidateIDs.removeAll() }

    func focusPhotoList() {
        guard let responder = photoSelectionResponder,
              let window = responder.window else { return }
        window.makeFirstResponder(responder)
    }

    private func toggleSelection(for ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let shouldRemove = ids.allSatisfy { selectedIDs.contains($0) }
        if shouldRemove {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
            deleteCandidateIDs.subtract(ids)
        }
    }

    private func toggleSelection(for ids: [String]) {
        toggleSelection(for: Set(ids))
    }

    private func toggleDeleteCandidate(for ids: Set<String>) {
        guard canDeleteSourceFiles, !ids.isEmpty else { return }
        let shouldRemove = ids.allSatisfy { deleteCandidateIDs.contains($0) }
        if shouldRemove {
            deleteCandidateIDs.subtract(ids)
        } else {
            deleteCandidateIDs.formUnion(ids)
            selectedIDs.subtract(ids)
        }
    }

    private func toggleDeleteCandidate(for ids: [String]) {
        toggleDeleteCandidate(for: Set(ids))
    }

    func refreshLabelData() {
        guard isLibraryView, let catalog else {
            labels = []
            savedLabelViews = []
            photoIDsByLabelID = [:]
            return
        }
        let snapshot = catalog.labelSnapshot(for: groups)
        labels = snapshot.labels
        savedLabelViews = snapshot.savedViews
        var index: [String: Set<String>] = [:]
        groups = groups.map { group in
            var updated = group
            updated.photoID = snapshot.photoIDByGroupID[group.id]
            updated.labels = updated.photoID.flatMap { snapshot.labelsByPhotoID[$0] } ?? []
            if let photoID = updated.photoID {
                for label in updated.labels { index[label.id, default: []].insert(photoID) }
            }
            return updated
        }
        photoIDsByLabelID = index
        activeLabelIDs.formIntersection(Set(labels.map(\.id)))
        if let activeSavedLabelViewID,
           !savedLabelViews.contains(where: { $0.id == activeSavedLabelViewID }) {
            self.activeSavedLabelViewID = nil
        }
    }

    func presentLabelPicker() {
        guard isLibraryView else {
            errorMessage = "ラベルはライブラリ内の管理対象写真にだけ設定できます。"
            return
        }
        guard !labelTargetGroups.isEmpty else {
            errorMessage = "ラベルを設定できる管理対象写真が選ばれていません。"
            return
        }
        isLabelPickerPresented = true
    }

    func labelAssignmentState(_ label: PhotoLabel) -> LabelAssignmentState {
        let targets = labelTargetGroups
        guard !targets.isEmpty else { return .none }
        let assigned = targets.reduce(into: 0) { count, group in
            if group.labels.contains(where: { $0.id == label.id }) { count += 1 }
        }
        if assigned == 0 { return .none }
        if assigned == targets.count { return .all }
        return .some
    }

    func toggleLabelAssignment(_ label: PhotoLabel) {
        guard let catalog else { return }
        let photoIDs = labelTargetGroups.compactMap(\.photoID)
        do {
            try catalog.setLabel(label.id, on: photoIDs, assigned: labelAssignmentState(label) != .all)
            refreshLabelData()
            rebuildGroupedPhotos()
        } catch { errorMessage = error.localizedDescription }
    }

    func randomLabelColor(excluding current: String? = nil) -> String {
        let candidates = LabelPalette.colors.filter { $0 != current }
        return candidates.randomElement() ?? LabelPalette.colors[0]
    }

    func createLabel(name: String, colorHex: String, assignToTargets: Bool = true) {
        guard let catalog else { return }
        do {
            let label = try catalog.createLabel(name: name, colorHex: colorHex)
            if assignToTargets { try catalog.setLabel(label.id, on: labelTargetGroups.compactMap(\.photoID), assigned: true) }
            refreshLabelData()
            rebuildGroupedPhotos()
        } catch { errorMessage = error.localizedDescription }
    }

    func updateLabel(_ label: PhotoLabel) {
        guard let catalog else { return }
        do { try catalog.updateLabel(label); refreshLabelData(); rebuildGroupedPhotos() }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteLabel(_ label: PhotoLabel) {
        guard let catalog else { return }
        do {
            try catalog.deleteLabel(id: label.id)
            activeSavedLabelViewID = nil
            activeLabelIDs.remove(label.id)
            refreshLabelData()
            rebuildGroupedPhotos()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func mergeLabel(_ source: PhotoLabel, into destination: PhotoLabel) {
        guard let catalog else { return }
        do {
            try catalog.mergeLabel(sourceID: source.id, destinationID: destination.id)
            activeSavedLabelViewID = nil
            activeLabelIDs.remove(source.id)
            refreshLabelData()
            rebuildGroupedPhotos()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func moveLabel(_ label: PhotoLabel, by offset: Int) {
        guard let catalog, let index = labels.firstIndex(where: { $0.id == label.id }) else { return }
        let destinationIndex = index + offset
        guard labels.indices.contains(destinationIndex) else { return }
        var first = labels[index]
        var second = labels[destinationIndex]
        swap(&first.sortOrder, &second.sortOrder)
        do {
            try catalog.updateLabel(first)
            try catalog.updateLabel(second)
            refreshLabelData()
            rebuildGroupedPhotos()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleLabelFilter(_ label: PhotoLabel) {
        activeSavedLabelViewID = nil
        if activeLabelIDs.contains(label.id) { activeLabelIDs.remove(label.id) }
        else { activeLabelIDs.insert(label.id) }
    }

    /// Selecting a label from the sidebar is a navigation action: show that
    /// label by itself instead of adding it to the current AND condition.
    func selectSingleLabelFilter(_ label: PhotoLabel) {
        activeSavedLabelViewID = nil
        activeLabelIDs = [label.id]
    }

    /// The explicit condition-add action is used by the sidebar and keeps the
    /// existing labels in the current AND condition.
    func addLabelFilter(_ label: PhotoLabel) {
        activeSavedLabelViewID = nil
        activeLabelIDs.insert(label.id)
    }

    func applySavedLabelView(_ view: SavedLabelView) {
        activeLabelIDs = Set(view.labelIDs)
        activeSavedLabelViewID = view.id
    }

    func clearLabelFilters() {
        activeSavedLabelViewID = nil
        activeLabelIDs.removeAll()
    }

    func saveCurrentLabelView(name: String) {
        guard let catalog, !activeLabelIDs.isEmpty else { return }
        do { _ = try catalog.saveLabelView(name: name, labelIDs: Array(activeLabelIDs)); refreshLabelData() }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteSavedLabelView(_ view: SavedLabelView) {
        guard let catalog else { return }
        do {
            try catalog.deleteSavedLabelView(id: view.id)
            if activeSavedLabelViewID == view.id { activeSavedLabelViewID = nil }
            refreshLabelData()
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func withImportState(_ group: PhotoGroup) -> PhotoGroup {
        Self.importState(
            for: group,
            isLibraryView: isLibraryView,
            catalog: catalog,
            targetCatalog: targetCatalog,
            sourceRoot: sourceURL,
            targetRoot: libraryURL,
            volumeUUID: sourceVolume?.volumeUUID
        )
    }

    private func scheduleImportStateEnrichment(
        groups scannedGroups: [PhotoGroup],
        isLibraryView: Bool,
        catalog: CatalogStore?,
        targetCatalog: CatalogStore?,
        sourceRoot: URL?,
        targetRoot: URL?,
        volumeUUID: String?,
        token: UUID,
        inspectLibraryAfterEnrichment: Bool = false
    ) {
        scanStateTask?.cancel()
        let refreshToken = UUID()
        importStateRefreshToken = refreshToken
        isImportStateRefreshing = true
        scanStateTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { () -> [PhotoGroup]? in
                var enriched: [PhotoGroup] = []
                enriched.reserveCapacity(scannedGroups.count)
                for group in scannedGroups {
                    guard !Task.isCancelled else { return nil }
                    enriched.append(Self.importState(
                        for: group,
                        isLibraryView: isLibraryView,
                        catalog: catalog,
                        targetCatalog: targetCatalog,
                        sourceRoot: sourceRoot,
                        targetRoot: targetRoot,
                        volumeUUID: volumeUUID
                    ))
                }
                return enriched
            }
            self?.scanStateWorkerTask = worker
            guard let enriched = await worker.value else { return }
            guard let self,
                  self.currentScanToken == token,
                  self.importStateRefreshToken == refreshToken else { return }

            // Merge only the import-state fields so metadata or thumbnails
            // loaded while the scan was finishing are not overwritten.
            var merged = self.groups
            for enrichedGroup in enriched {
                guard let index = self.groupIndexByID[enrichedGroup.id] else { continue }
                var current = self.groupByID[enrichedGroup.id] ?? merged[index]
                current.importedJPEG = enrichedGroup.importedJPEG
                current.importedRAW = enrichedGroup.importedRAW
                current.possibleImportedJPEG = enrichedGroup.possibleImportedJPEG
                current.possibleImportedRAW = enrichedGroup.possibleImportedRAW
                current.libraryAssetStatus = enrichedGroup.libraryAssetStatus
                merged[index] = current
            }
            self.groups = merged
            self.refreshLabelData()
            self.rebuildGroupedPhotos()
            // Import-state enrichment can reorder the visible clusters. Move
            // the automatic initial focus with that reordering, but preserve
            // a focus that the user has already moved elsewhere.
            if !self.userMovedFocusForCurrentSource || self.focusedIDs.isEmpty {
                self.focusFirstVisiblePhoto()
            }
            self.isImportStateRefreshing = false
            self.scanStateTask = nil
            self.scanStateWorkerTask = nil
            if inspectLibraryAfterEnrichment,
               self.isLibraryView,
               self.currentScanToken == token {
                self.inspectLibrary()
            }
        }
    }

    private nonisolated static func importState(
        for group: PhotoGroup,
        isLibraryView: Bool,
        catalog: CatalogStore?,
        targetCatalog: CatalogStore?,
        sourceRoot: URL?,
        targetRoot: URL?,
        volumeUUID: String?
    ) -> PhotoGroup {
        var updated = group
        if group.isCameraBacked {
            updated.libraryAssetStatus = .notApplicable
            updated.importedJPEG = false
            updated.importedRAW = false
            updated.possibleImportedJPEG = false
            updated.possibleImportedRAW = false
            guard let catalog = targetCatalog,
                  let reference = group.cameraReference else { return updated }
            if let asset = reference.asset(for: .jpeg) {
                let sourceKey = CameraMonitor.catalogSourceKey(
                    cameraID: reference.cameraID,
                    groupKey: reference.groupKey,
                    variant: .jpeg
                )
                updated.importedJPEG = catalog.isImported(sourceKey: sourceKey, variant: .jpeg)
                if !updated.importedJPEG {
                    updated.possibleImportedJPEG = !catalog.matchCandidates(
                        sourceFilenameKey: FilenameIdentity.key(for: asset.filename),
                        fileSize: asset.fileSize,
                        variant: .jpeg
                    ).isEmpty
                }
            }
            if let asset = reference.asset(for: .raw) {
                let sourceKey = CameraMonitor.catalogSourceKey(
                    cameraID: reference.cameraID,
                    groupKey: reference.groupKey,
                    variant: .raw
                )
                updated.importedRAW = catalog.isImported(sourceKey: sourceKey, variant: .raw)
                if !updated.importedRAW {
                    updated.possibleImportedRAW = !catalog.matchCandidates(
                        sourceFilenameKey: FilenameIdentity.key(for: asset.filename),
                        fileSize: asset.fileSize,
                        variant: .raw
                    ).isEmpty
                }
            }
            return updated
        }
        if isLibraryView {
            // EXT is a property of the source library itself. Import state,
            // including the green checkmark, is a property of the target
            // library and must be checked at the target's corresponding path.
            let jpegSourceManaged = group.jpegURL.map { catalog?.libraryAssetStatus(for: $0) ?? false } ?? false
            let rawSourceManaged = group.rawURL.map { catalog?.libraryAssetStatus(for: $0) ?? false } ?? false
            let jpegTargetManaged = targetURL(
                for: group.jpegURL,
                sourceRoot: sourceRoot,
                targetRoot: targetRoot,
                catalog: targetCatalog
            )
            let rawTargetManaged = targetURL(
                for: group.rawURL,
                sourceRoot: sourceRoot,
                targetRoot: targetRoot,
                catalog: targetCatalog
            )
            let available = [group.jpegURL, group.rawURL].compactMap { $0 }.count
            let sourceManaged = [jpegSourceManaged, rawSourceManaged].filter { $0 }.count
            updated.importedJPEG = jpegTargetManaged
            updated.importedRAW = rawTargetManaged
            updated.possibleImportedJPEG = false
            updated.possibleImportedRAW = false
            updated.libraryAssetStatus = sourceManaged == 0 ? .unregistered : (sourceManaged == available ? .registered : .partial)
            return updated
        }
        updated.libraryAssetStatus = .notApplicable
        updated.importedJPEG = false
        updated.importedRAW = false
        updated.possibleImportedJPEG = false
        updated.possibleImportedRAW = false
        guard let catalog else { return updated }
        if let jpegURL = group.jpegURL {
            let sourceKey = SourceIdentity.key(url: jpegURL, variant: .jpeg, sourceRoot: sourceRoot, volumeUUID: volumeUUID)
            let legacyKey = SourceIdentity.legacyKey(url: jpegURL, variant: .jpeg)
            updated.importedJPEG = catalog.isImported(sourceKey: sourceKey, variant: .jpeg, legacySourceKey: legacyKey)
        }
        if let rawURL = group.rawURL {
            let sourceKey = SourceIdentity.key(url: rawURL, variant: .raw, sourceRoot: sourceRoot, volumeUUID: volumeUUID)
            let legacyKey = SourceIdentity.legacyKey(url: rawURL, variant: .raw)
            updated.importedRAW = catalog.isImported(sourceKey: sourceKey, variant: .raw, legacySourceKey: legacyKey)
        }
        return updated
    }

    private nonisolated static func targetURL(
        for sourceURL: URL?,
        sourceRoot: URL?,
        targetRoot: URL?,
        catalog: CatalogStore?
    ) -> Bool {
        guard let sourceURL,
              let sourceRoot,
              let targetRoot,
              let catalog else { return false }
        let sourcePath = sourceURL.standardizedFileURL.path
        let sourceRootPath = sourceRoot.standardizedFileURL.path
        let prefix = sourceRootPath.hasSuffix("/") ? sourceRootPath : sourceRootPath + "/"
        guard sourcePath.hasPrefix(prefix) else { return false }
        let relativePath = String(sourcePath.dropFirst(prefix.count))
        let destinationURL = targetRoot.appendingPathComponent(relativePath)
        return catalog.libraryAssetStatus(for: destinationURL)
    }

    private func updateImportState(for groupID: String) {
        guard let index = groupIndexByID[groupID] else { return }
        groups[index] = withImportState(groups[index])
        rebuildGroupedPhotos()
    }

    private func focusNextPendingImport() {
        guard !isLibraryView else { return }
        guard let next = groups.first(where: { group in
            switch group.cardImportState {
            case .notImported, .possible, .partial: return true
            case .imported, .notApplicable: return false
            }
        }) else { return }
        focusedIDs = [next.id]
        lastFocusedID = next.id
    }

    private func enqueueMetadataLoading(
        groups candidateGroups: [PhotoGroup],
        token: UUID,
        sourceScanFinished: Bool
    ) {
        guard currentScanToken == token else { return }
        metadataSourceScanFinished = metadataSourceScanFinished || sourceScanFinished
        let pendingGroups = candidateGroups.filter {
            !$0.isMetadataLoaded && !metadataEnqueuedIDs.contains($0.id)
        }
        metadataEnqueuedIDs.formUnion(pendingGroups.map(\.id))
        metadataTotal += pendingGroups.count

        if metadataTotal > metadataCompleted {
            progressText = "メタデータを読み込み中… \(metadataCompleted)/\(metadataTotal)"
        } else if metadataSourceScanFinished {
            progressText = "\(groups.count)グループを表示中"
        }

        guard !pendingGroups.isEmpty else {
            if metadataSourceScanFinished, metadataCompleted >= metadataTotal {
                flushPendingMetadata(forcePublish: true)
                progressText = "\(groups.count)グループを表示中"
            }
            return
        }

        MetadataLoadingCoordinator.shared.suspendBackgroundReads()
        if let lastFocusedID {
            MetadataLoadingCoordinator.shared.prioritize(
                groupID: lastFocusedID,
                priority: .viewerCurrent
            )
        }
        for group in pendingGroups {
            MetadataLoadingCoordinator.shared.enqueue(
                group: group,
                priority: .background
            ) { [weak self] metadata in
                guard let self, self.currentScanToken == token else { return }
                self.receiveMetadata(metadata, for: group.id, token: token)
            }
        }
        // Enqueue first, then sort once. Visible and viewer requests lead the
        // queue; background work begins after them without a timer.
        MetadataLoadingCoordinator.shared.resumeBackgroundReads()
    }

    private func receiveMetadata(_ metadata: PhotoMetadata?, for groupID: String, token: UUID) {
        guard currentScanToken == token else { return }
        completedMetadataIDs.insert(groupID)
        if let metadata {
            pendingMetadata[groupID] = metadata
        }

        metadataCompleted += 1
        let focusedMetadataArrived = focusedIDs.contains(groupID) || viewerGroupID == groupID
        if focusedMetadataArrived {
            flushPendingMetadata()
        }

        if metadataSourceScanFinished, metadataCompleted >= metadataTotal {
            flushPendingMetadata(forcePublish: true)
            progressText = "\(groups.count)グループを表示中"
            return
        }

        if metadataCompleted.isMultiple(of: metadataProgressDisplayInterval) {
            progressText = "メタデータを読み込み中… \(metadataCompleted)/\(metadataTotal)"
            flushPendingMetadata()
        }
    }

    private func flushPendingMetadata(forcePublish: Bool = false) {
        guard !pendingMetadata.isEmpty || !completedMetadataIDs.isEmpty else { return }
        let updates = pendingMetadata
        let completedIDs = completedMetadataIDs
        pendingMetadata.removeAll(keepingCapacity: true)
        completedMetadataIDs.removeAll(keepingCapacity: true)

        let focusedMetadataArrived = !focusedIDs.isDisjoint(with: completedIDs)
            || viewerGroupID.map { completedIDs.contains($0) } == true
        if focusedMetadataArrived, !forcePublish {
            // The inspector and viewer read through groupByID. Notify those
            // views without replacing the complete groups array and forcing
            // every photo tile to be evaluated again.
            objectWillChange.send()
        }

        for groupID in completedIDs {
            guard let index = groupIndexByID[groupID] else { continue }
            var updatedGroup = groupByID[groupID] ?? groups[index]
            if let metadata = updates[groupID] {
                updatedGroup.metadata = metadata
                if let captureDate = metadata.captureDate {
                    updatedGroup.captureDate = captureDate
                }
            }
            updatedGroup.isMetadataLoaded = true
            groupByID[groupID] = updatedGroup
        }

        // Background results stay in groupByID. Publish and regroup the full
        // photo array exactly once when the metadata sweep completes.
        if forcePublish {
            groups = groups.map { groupByID[$0.id] ?? $0 }
            rebuildGroupedPhotos()
        }
    }

    func prioritizeMetadata(for groupID: String, priority: MetadataRequestPriority) {
        guard let group = groupByID[groupID], !group.isMetadataLoaded else { return }
        if group.isCameraBacked {
            // A camera's metadata is not a background catalogue job. Only
            // the photo currently under keyboard/click focus or open in the
            // viewer may issue an explicit request. This keeps the delegate
            // gate closed for every other camera item.
            guard lastFocusedID == groupID || viewerGroupID == groupID else { return }
            let token = currentScanToken
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.currentScanToken == token else { return }
                MetadataLoadingCoordinator.shared.enqueue(
                    group: group,
                    priority: priority,
                    loader: { _ in await CameraMonitor.shared.requestMetadata(for: group) }
                ) { [weak self] metadata in
                    guard let self, self.currentScanToken == token else { return }
                    self.updateCameraMetadata(metadata, for: groupID)
                }
            }
            return
        }
        MetadataLoadingCoordinator.shared.prioritize(groupID: groupID, priority: priority)
    }
}
