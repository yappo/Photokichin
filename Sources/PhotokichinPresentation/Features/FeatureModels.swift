import Foundation
import Observation
import PhotokichinDomain

@MainActor
@Observable
final class SourceBrowserFeatureModel {
    var groups: [PhotoGroup] = []
    var groupedPhotos: [(String, [PhotoGroup])] = []
    var sourceURL: URL?
    var sourceVolume: MountedVolume?
    var sourceCamera: CameraDescriptor?
    var cameras: [CameraDescriptor] = []
    var isScanning = false
    var importFilter: PhotoImportFilter = .all
    var operationFilter: PhotoOperationFilter = .all
    var filteredGroupedPhotos: [(String, [PhotoGroup])] = []
    var isImportStateRefreshing = false
}

@MainActor
@Observable
final class PhotoGridFeatureModel {
    var focusedIDs: Set<String> = []
    var focusScrollRevision = 0
    var focusScrollEdge: FocusScrollEdge = .end
    var selectedIDs: Set<String> = []
    var deleteCandidateIDs: Set<String> = []
    var thumbnailSize: Double = 180
    var gridColumnCount = 1
    var gridViewportHeight: Double = 700
    var groupStateRevision = 0
    var listContentRevision = 0
    var inspectorShown = true
}

@MainActor
@Observable
final class LibraryFeatureModel {
    var libraryURL: URL?
    var libraryURLs: [URL] = []
    var catalogSummary: CatalogSummary?
    var catalogIssues: [CatalogIssue] = []
    var isCatalogInspecting = false
    var labels: [PhotoLabel] = []
    var savedLabelViews: [SavedLabelView] = []
    var activeLabelIDs: Set<String> = []
    var activeSavedLabelViewID: String?
    var isLabelPickerPresented = false
    var isLabelManagementPresented = false
    var copyLabelsOnLibraryCopy = true
}

@MainActor
@Observable
final class FileOperationFeatureModel {
    var isBusy = false
    var operationProgress: OperationProgress?
    var progressText = "SDカードまたはフォルダを選択してください"
    var errorMessage: String?
    var lastImportResults: [ImportResult] = []
    var importTemplate = "{date}_{camera}"
    var isCancellingImport = false
}

@MainActor
@Observable
final class ViewerFeatureModel {
    var groupID: String?
}
