import Foundation
import PhotokichinDomain

package struct BrowsePhotosUseCase: Sendable {
    private let scanner: any PhotoScanning

    package init(scanner: any PhotoScanning) {
        self.scanner = scanner
    }

    package func execute(
        root: URL,
        initialPresentationBatchSize: Int,
        initialPresentationGroupTarget: Int,
        progress: (@Sendable ([PhotoGroup], Int) -> Void)?
    ) -> [PhotoGroup] {
        scanner.scan(
            root: root,
            initialPresentationBatchSize: initialPresentationBatchSize,
            initialPresentationGroupTarget: initialPresentationGroupTarget,
            progress: progress
        )
    }
}

package struct OpenCatalogUseCase: Sendable {
    private let factory: any CatalogRepositoryFactory

    package init(factory: any CatalogRepositoryFactory) {
        self.factory = factory
    }

    package func execute(libraryRoot: URL) throws -> any CatalogRepository {
        try factory.open(libraryRoot: libraryRoot)
    }
}

package struct EjectVolumeUseCase: Sendable {
    private let ejector: any VolumeEjecting

    package init(ejector: any VolumeEjecting) {
        self.ejector = ejector
    }

    package func execute(volumeURL: URL) async throws {
        try await ejector.eject(volumeURL: volumeURL)
    }
}

package struct ImportPhotosUseCase: Sendable {
    private let transfer: any FileTransferring

    package init(transfer: any FileTransferring) {
        self.transfer = transfer
    }

    package func execute(
        _ group: PhotoGroup,
        to libraryRoot: URL,
        template: String,
        catalog: any CatalogRepository,
        cancellation: ImportCancellationToken?,
        sourceRoot: URL?,
        volumeUUID: String?
    ) throws -> ImportResult {
        try transfer.importGroup(
            group,
            to: libraryRoot,
            template: template,
            catalog: catalog,
            cancellation: cancellation,
            sourceRoot: sourceRoot,
            volumeUUID: volumeUUID
        )
    }

    package func installDownloadedFile(
        partialURL: URL,
        destinationURL: URL,
        variant: AssetVariant,
        sourceKey: String,
        sourceFilename: String?,
        catalog: any CatalogRepository,
        expectedFileSize: Int64,
        cancellation: ImportCancellationToken?
    ) throws -> Bool {
        try transfer.installCameraDownloadedFile(
            partialURL: partialURL,
            destinationURL: destinationURL,
            variant: variant,
            sourceKey: sourceKey,
            sourceFilename: sourceFilename,
            catalog: catalog,
            expectedFileSize: expectedFileSize,
            cancellation: cancellation
        )
    }

    package func sourceKey(
        for group: PhotoGroup,
        variant: AssetVariant,
        sourceRoot: URL?,
        volumeUUID: String?
    ) -> String {
        transfer.sourceKey(
            for: group,
            variant: variant,
            sourceRoot: sourceRoot,
            volumeUUID: volumeUUID
        )
    }

    package func folderName(template: String, date: Date, camera: String) -> String {
        transfer.makeFolderName(template: template, date: date, camera: camera)
    }
}

package struct CopyPhotosUseCase: Sendable {
    private let transfer: any FileTransferring

    package init(transfer: any FileTransferring) {
        self.transfer = transfer
    }

    package func execute(
        _ group: PhotoGroup,
        from sourceLibrary: URL,
        to destinationLibrary: URL,
        sourceCatalog: (any CatalogRepository)?,
        destinationCatalog: any CatalogRepository,
        copyLabels: Bool,
        cancellation: ImportCancellationToken?
    ) throws -> ImportResult {
        try transfer.copyLibraryGroup(
            group,
            from: sourceLibrary,
            to: destinationLibrary,
            sourceCatalog: sourceCatalog,
            destinationCatalog: destinationCatalog,
            copyLabels: copyLabels,
            cancellation: cancellation
        )
    }
}

package struct DeletePhotosUseCase: Sendable {
    private let transfer: any FileTransferring

    package init(transfer: any FileTransferring) {
        self.transfer = transfer
    }

    package func moveToTrash(
        _ groups: [PhotoGroup],
        onProgress: (@Sendable (Int, Int, Int, Int) -> Void)?
    ) async -> TrashBatchResult {
        await transfer.moveGroupsToTrash(groups, onProgress: onProgress)
    }
}

package struct SharePhotosUseCase: Sendable {
    private let transfer: any FileTransferring

    package init(transfer: any FileTransferring) {
        self.transfer = transfer
    }

    package func execute(
        _ groups: [PhotoGroup],
        mode: AirDropMode,
        onCompletion: @escaping @Sendable (Error?) -> Void
    ) throws -> any AirDropSessionHandling {
        try transfer.airDrop(groups, mode: mode, onCompletion: onCompletion)
    }
}

package struct AppUseCases: Sendable {
    package let browsePhotos: BrowsePhotosUseCase
    package let openCatalog: OpenCatalogUseCase
    package let importPhotos: ImportPhotosUseCase
    package let copyPhotos: CopyPhotosUseCase
    package let deletePhotos: DeletePhotosUseCase
    package let sharePhotos: SharePhotosUseCase
    package let mediaReader: any MediaReading
    package let ejectVolume: EjectVolumeUseCase

    package init(
        browsePhotos: BrowsePhotosUseCase,
        openCatalog: OpenCatalogUseCase,
        importPhotos: ImportPhotosUseCase,
        copyPhotos: CopyPhotosUseCase,
        deletePhotos: DeletePhotosUseCase,
        sharePhotos: SharePhotosUseCase,
        mediaReader: any MediaReading,
        ejectVolume: EjectVolumeUseCase
    ) {
        self.browsePhotos = browsePhotos
        self.openCatalog = openCatalog
        self.importPhotos = importPhotos
        self.copyPhotos = copyPhotos
        self.deletePhotos = deletePhotos
        self.sharePhotos = sharePhotos
        self.mediaReader = mediaReader
        self.ejectVolume = ejectVolume
    }
}

@MainActor
package struct AppDependencies {
    package let volumeMonitor: any VolumeMonitoring
    package let cameraMonitor: any CameraMonitoring
    package let useCases: AppUseCases

    package init(
        volumeMonitor: any VolumeMonitoring,
        cameraMonitor: any CameraMonitoring,
        useCases: AppUseCases
    ) {
        self.volumeMonitor = volumeMonitor
        self.cameraMonitor = cameraMonitor
        self.useCases = useCases
    }
}
