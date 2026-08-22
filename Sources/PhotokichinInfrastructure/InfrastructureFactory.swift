import Foundation
import PhotokichinApplication

private struct LiveCatalogRepositoryFactory: CatalogRepositoryFactory {
    let classifier: any MediaFormatClassifying

    func open(libraryRoot: URL) throws -> any CatalogRepository {
        try CatalogStore(libraryRoot: libraryRoot, classifier: classifier)
    }
}

@MainActor
package enum InfrastructureFactory {
    package static func makeAppDependencies() -> AppDependencies {
        let composition = InfrastructureComposition.production()
        let catalogFactory = LiveCatalogRepositoryFactory(classifier: composition.mediaClassifier)
        let scanner = PhotoScanner(
            classifier: composition.mediaClassifier,
            traversalPolicy: composition.traversalPolicy
        )
        let transfer = FileTransferService()
        let mediaReader = ImageIOMediaReader(pipeline: composition.metadataPipeline)
        let volumeMonitor = VolumeMonitor()
        let cameraMonitor = CameraMonitor(
            classifier: composition.mediaClassifier,
            cameraSupportResolver: composition.cameraSupportResolver,
            metadataReader: mediaReader
        )
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
