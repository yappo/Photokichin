import Foundation
import Testing
@testable import PhotokichinApplication
@testable import PhotokichinDomain

private struct ScannerSpy: PhotoScanning {
    let groups: [PhotoGroup]

    func scan(
        root: URL,
        initialPresentationBatchSize: Int,
        initialPresentationGroupTarget: Int,
        progress: (@Sendable ([PhotoGroup], Int) -> Void)?
    ) -> [PhotoGroup] {
        progress?(groups, groups.count)
        return groups
    }
}

@Suite("Application use cases")
struct ApplicationUseCaseTests {
    @Test("Browse use case delegates scanning and progress")
    func browsePhotos() {
        let root = URL(fileURLWithPath: "/tmp/application-fixture")
        let group = PhotoGroup(
            id: "one",
            basename: "IMG_0001",
            directory: root,
            jpegURL: root.appendingPathComponent("IMG_0001.JPG"),
            rawURL: nil,
            movieURL: nil,
            captureDate: nil,
            metadata: .empty,
            importedJPEG: false,
            importedRAW: false,
            isMetadataLoaded: false
        )
        let useCase = BrowsePhotosUseCase(scanner: ScannerSpy(groups: [group]))

        let result = useCase.execute(
            root: root,
            initialPresentationBatchSize: 1,
            initialPresentationGroupTarget: 1,
            progress: nil
        )

        #expect(result.map(\.id) == ["one"])
    }

    @Test("Cancellation token reports cancellation without shared mutable state")
    func cancellation() {
        let token = ImportCancellationToken()
        #expect(!token.isCancelled)
        token.cancel()
        #expect(token.isCancelled)
        #expect(throws: CancellationError.self) {
            try token.check()
        }
    }
}
