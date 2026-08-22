import Foundation
import PhotokichinApplication

private struct LiveCatalogRepositoryFactory: CatalogRepositoryFactory {
    func open(libraryRoot: URL) throws -> any CatalogRepository {
        try CatalogStore(libraryRoot: libraryRoot)
    }
}

@MainActor
package enum InfrastructureFactory {
    package static func makeAppDependencies() -> AppDependencies {
        let catalogFactory = LiveCatalogRepositoryFactory()
        let scanner = PhotoScanner()
        let transfer = FileTransferService()
        let mediaReader = ImageIOMediaReader()
        let volumeMonitor = VolumeMonitor()
        let cameraMonitor = CameraMonitor()
        let useCases = AppUseCases(
            browsePhotos: BrowsePhotosUseCase(scanner: scanner),
            openCatalog: OpenCatalogUseCase(factory: catalogFactory),
            importPhotos: ImportPhotosUseCase(transfer: transfer),
            copyPhotos: CopyPhotosUseCase(transfer: transfer),
            deletePhotos: DeletePhotosUseCase(transfer: transfer),
            sharePhotos: SharePhotosUseCase(transfer: transfer),
            mediaReader: mediaReader,
            ejectVolume: EjectVolumeUseCase(ejector: VolumeEjectorService())
        )
        return AppDependencies(
            volumeMonitor: volumeMonitor,
            cameraMonitor: cameraMonitor,
            useCases: useCases
        )
    }
}
