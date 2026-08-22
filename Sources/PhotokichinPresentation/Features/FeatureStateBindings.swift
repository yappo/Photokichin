import Foundation
import PhotokichinDomain

@MainActor
extension AppModel {
    var groups: [PhotoGroup] {
        get { sourceBrowser.groups }
        set {
            sourceBrowser.groups = newValue
            groupByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
            groupIndexByID = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.element.id, $0.offset) })
            groupStateRevision &+= 1
        }
    }
    var groupedPhotos: [(String, [PhotoGroup])] {
        get { sourceBrowser.groupedPhotos }
        set { sourceBrowser.groupedPhotos = newValue }
    }
    var focusedIDs: Set<String> {
        get { photoGrid.focusedIDs }
        set { photoGrid.focusedIDs = newValue }
    }
    var focusScrollRevision: Int {
        get { photoGrid.focusScrollRevision }
        set { photoGrid.focusScrollRevision = newValue }
    }
    var focusScrollEdge: FocusScrollEdge {
        get { photoGrid.focusScrollEdge }
        set { photoGrid.focusScrollEdge = newValue }
    }
    var selectedIDs: Set<String> {
        get { photoGrid.selectedIDs }
        set {
            photoGrid.selectedIDs = newValue
            rebuildFilteredPhotos()
        }
    }
    var deleteCandidateIDs: Set<String> {
        get { photoGrid.deleteCandidateIDs }
        set {
            photoGrid.deleteCandidateIDs = newValue
            rebuildFilteredPhotos()
        }
    }
    var sourceURL: URL? {
        get { sourceBrowser.sourceURL }
        set { sourceBrowser.sourceURL = newValue }
    }
    var sourceVolume: MountedVolume? {
        get { sourceBrowser.sourceVolume }
        set { sourceBrowser.sourceVolume = newValue }
    }
    var sourceCamera: CameraDescriptor? {
        get { sourceBrowser.sourceCamera }
        set { sourceBrowser.sourceCamera = newValue }
    }
    var cameras: [CameraDescriptor] {
        get { sourceBrowser.cameras }
        set { sourceBrowser.cameras = newValue }
    }
    var libraryURL: URL? {
        get { library.libraryURL }
        set { library.libraryURL = newValue }
    }
    var libraryURLs: [URL] {
        get { library.libraryURLs }
        set { library.libraryURLs = newValue }
    }
    var isScanning: Bool {
        get { sourceBrowser.isScanning }
        set { sourceBrowser.isScanning = newValue }
    }
    var isBusy: Bool {
        get { fileOperations.isBusy }
        set { fileOperations.isBusy = newValue }
    }
    var operationProgress: OperationProgress? {
        get { fileOperations.operationProgress }
        set { fileOperations.operationProgress = newValue }
    }
    var progressText: String {
        get { fileOperations.progressText }
        set { fileOperations.progressText = newValue }
    }
    var thumbnailSize: Double {
        get { photoGrid.thumbnailSize }
        set { photoGrid.thumbnailSize = newValue }
    }
    var gridColumnCount: Int {
        get { photoGrid.gridColumnCount }
        set { photoGrid.gridColumnCount = newValue }
    }
    var gridViewportHeight: Double {
        get { photoGrid.gridViewportHeight }
        set { photoGrid.gridViewportHeight = newValue }
    }
    var groupStateRevision: Int {
        get { photoGrid.groupStateRevision }
        set { photoGrid.groupStateRevision = newValue }
    }
    var listContentRevision: Int {
        get { photoGrid.listContentRevision }
        set { photoGrid.listContentRevision = newValue }
    }
    var importFilter: PhotoImportFilter {
        get { sourceBrowser.importFilter }
        set {
            sourceBrowser.importFilter = newValue
            handleFilterChange()
        }
    }
    var operationFilter: PhotoOperationFilter {
        get { sourceBrowser.operationFilter }
        set {
            sourceBrowser.operationFilter = newValue
            handleFilterChange()
        }
    }
    var filteredGroupedPhotos: [(String, [PhotoGroup])] {
        get { sourceBrowser.filteredGroupedPhotos }
        set { sourceBrowser.filteredGroupedPhotos = newValue }
    }
    var inspectorShown: Bool {
        get { photoGrid.inspectorShown }
        set { photoGrid.inspectorShown = newValue }
    }
    var viewerGroupID: String? {
        get { viewer.groupID }
        set { viewer.groupID = newValue }
    }
    var errorMessage: String? {
        get { fileOperations.errorMessage }
        set { fileOperations.errorMessage = newValue }
    }
    var lastImportResults: [ImportResult] {
        get { fileOperations.lastImportResults }
        set { fileOperations.lastImportResults = newValue }
    }
    var importTemplate: String {
        get { fileOperations.importTemplate }
        set { fileOperations.importTemplate = newValue }
    }
    var isCancellingImport: Bool {
        get { fileOperations.isCancellingImport }
        set { fileOperations.isCancellingImport = newValue }
    }
    var catalogSummary: CatalogSummary? {
        get { library.catalogSummary }
        set { library.catalogSummary = newValue }
    }
    var catalogIssues: [CatalogIssue] {
        get { library.catalogIssues }
        set { library.catalogIssues = newValue }
    }
    var isCatalogInspecting: Bool {
        get { library.isCatalogInspecting }
        set { library.isCatalogInspecting = newValue }
    }
    var isImportStateRefreshing: Bool {
        get { sourceBrowser.isImportStateRefreshing }
        set { sourceBrowser.isImportStateRefreshing = newValue }
    }
    var labels: [PhotoLabel] {
        get { library.labels }
        set { library.labels = newValue }
    }
    var savedLabelViews: [SavedLabelView] {
        get { library.savedLabelViews }
        set { library.savedLabelViews = newValue }
    }
    var activeLabelIDs: Set<String> {
        get { library.activeLabelIDs }
        set {
            library.activeLabelIDs = newValue
            handleFilterChange()
        }
    }
    /// Identifies a saved view that was explicitly selected in the sidebar.
    /// A matching set of labels created manually is intentionally not treated
    /// as a saved-view selection.
    var activeSavedLabelViewID: String? {
        get { library.activeSavedLabelViewID }
        set { library.activeSavedLabelViewID = newValue }
    }
    var isLabelPickerPresented: Bool {
        get { library.isLabelPickerPresented }
        set { library.isLabelPickerPresented = newValue }
    }
    var isLabelManagementPresented: Bool {
        get { library.isLabelManagementPresented }
        set { library.isLabelManagementPresented = newValue }
    }
    var copyLabelsOnLibraryCopy: Bool {
        get { library.copyLabelsOnLibraryCopy }
        set { library.copyLabelsOnLibraryCopy = newValue }
    }
}
