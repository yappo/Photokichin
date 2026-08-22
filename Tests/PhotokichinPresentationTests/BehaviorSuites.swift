import Testing

@Suite("Domain behavior")
struct DomainBehaviorTests {
    @Test("Import state, filtering, ordering, and navigation")
    func importState() throws {
        try TestSupport.runImportStateTests()
    }

    @Test("Camera-backed photo values")
    func cameraModel() throws {
        try TestSupport.runCameraModelTests()
    }

    @Test("Filename identity")
    func filenameIdentity() throws {
        try TestSupport.runFilenameIdentityTests()
    }

    @Test("Volume source identity")
    func sourceIdentity() throws {
        try TestSupport.runSourceIdentityTests()
    }
}

@Suite("Infrastructure behavior")
struct InfrastructureBehaviorTests {
    @Test("Library AirDrop staging")
    func libraryAirDrop() throws {
        try TestSupport.runLibraryAirDropTests()
    }

    @Test("Catalog registration and integrity")
    func catalog() throws {
        try TestSupport.runCatalogTests()
    }

    @Test("Library copy")
    func libraryCopy() throws {
        try TestSupport.runLibraryCopyTests()
    }

    @Test("Labels and saved views")
    func labels() throws {
        try TestSupport.runLabelTests()
    }

    @Test("Camera catalog builder")
    func cameraCatalogBuilder() throws {
        try TestSupport.runCameraCatalogBuilderTests()
    }

    @Test("Camera catalog refresh gate")
    func cameraCatalogRefreshGate() throws {
        try TestSupport.runCameraCatalogRefreshGateTests()
    }

    @Test("Catalog import transaction boundaries")
    func catalogImportBoundaries() throws {
        try TestSupport.runRecordImportBoundaryTests()
    }

    @Test("Catalog inspection boundaries")
    func catalogInspectionBoundaries() throws {
        try TestSupport.runInspectionBoundaryTests()
    }

    @Test("Catalog relink and forget boundaries")
    func catalogRelinkBoundaries() throws {
        try TestSupport.runRelinkAndForgetBoundaryTests()
    }

    @Test("Source identity migration boundaries")
    func sourceIdentityMigrationBoundaries() throws {
        try TestSupport.runSourceIdentityMigrationBoundaryTests()
    }

    @Test("Catalog backup failure boundaries")
    func catalogBackupBoundaries() throws {
        try TestSupport.runBackupFailureBoundaryTests()
    }

    @Test("Safe JPG and CR3 transfer")
    func fileTransfer() throws {
        try TestSupport.runFileTransferImportTests()
    }
}

@Suite("Loading coordinators")
@MainActor
struct LoadingCoordinatorBehaviorTests {
    @Test("Metadata scheduling and cancellation")
    func metadata() async throws {
        try await TestSupport.runMetadataLoadingCoordinatorTests()
    }

    @Test("Thumbnail memory cache")
    func thumbnailCache() throws {
        try TestSupport.runThumbnailCacheTests()
    }

    @Test("Thumbnail scheduling and cancellation")
    func thumbnails() async throws {
        try await TestSupport.runThumbnailLoadingCoordinatorTests()
    }
}

@Suite("AppModel workflows")
@MainActor
struct AppModelBehaviorTests {
    @Test("Latest source wins during source switching")
    func sourceSwitching() async throws {
        try await TestSupport.runAppModelSourceSwitchTests()
    }

    @Test("Selection and keyboard navigation state")
    func selectionAndNavigation() throws {
        try TestSupport.runAppModelSelectionAndNavigationTests()
    }

    @Test("Import progress and completion state")
    func importing() async throws {
        try await TestSupport.runAppModelImportTests()
    }

    @Test("Incremental camera catalog focus")
    func cameraCatalogFocus() async throws {
        try await TestSupport.runAppModelCameraCatalogTests()
    }
}
