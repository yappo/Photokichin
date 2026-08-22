import Foundation
@testable import PhotokichinDomain
@testable import PhotokichinInfrastructure

enum InfrastructureTestSupport {
    static let composition = InfrastructureComposition.production()
    static let classifier: any MediaFormatClassifying = composition.mediaClassifier
    static let traversalPolicy = composition.traversalPolicy
    static let metadataPipeline = composition.metadataPipeline

    static func scanner() -> PhotoScanner {
        PhotoScanner(classifier: classifier, traversalPolicy: traversalPolicy)
    }

    static func scan(root: URL) -> [PhotoGroup] {
        scanner().scan(
            root: root,
            initialPresentationBatchSize: .max,
            initialPresentationGroupTarget: .max,
            progress: nil
        )
    }

    static func catalogStore(libraryRoot: URL) throws -> CatalogStore {
        try CatalogStore(libraryRoot: libraryRoot, classifier: classifier)
    }
}
