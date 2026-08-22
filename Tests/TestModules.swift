@testable import PhotokichinCore

struct PhotokichinTestModule {
    let name: String
    let run: () async throws -> Void
}

/// The deterministic test list lives outside the executable entry point.
/// New test files can add a function to `PhotokichinTestRunner` and register
/// it here without growing `TestRunner.swift`.
enum PhotokichinTestModules {
    static let all: [PhotokichinTestModule] = [
        PhotokichinTestModule(name: "Import state", run: { try PhotokichinTestRunner.runImportStateTests() }),
        PhotokichinTestModule(name: "Camera model", run: { try PhotokichinTestRunner.runCameraModelTests() }),
        PhotokichinTestModule(name: "Camera catalog", run: { try PhotokichinTestRunner.runCameraCatalogTests() }),
        PhotokichinTestModule(name: "Catalog", run: { try PhotokichinTestRunner.runCatalogTests() }),
        PhotokichinTestModule(name: "Catalog boundaries", run: { try PhotokichinTestRunner.runCatalogBoundaryTests() }),
        PhotokichinTestModule(name: "Filename identity", run: { try PhotokichinTestRunner.runFilenameIdentityTests() }),
        PhotokichinTestModule(name: "Source identity", run: { try PhotokichinTestRunner.runSourceIdentityTests() }),
        PhotokichinTestModule(name: "Library copy", run: { try PhotokichinTestRunner.runLibraryCopyTests() }),
        PhotokichinTestModule(name: "Labels", run: { try PhotokichinTestRunner.runLabelTests() }),
        PhotokichinTestModule(name: "Library AirDrop", run: { try PhotokichinTestRunner.runLibraryAirDropTests() }),
        PhotokichinTestModule(name: "File transfer import", run: { try PhotokichinTestRunner.runFileTransferImportTests() }),
        PhotokichinTestModule(name: "Loading coordinators", run: { try await PhotokichinTestRunner.runLoadingCoordinatorTests() }),
        PhotokichinTestModule(name: "AppModel workflows", run: { try await PhotokichinTestRunner.runAppModelWorkflowTests() })
    ]
}
