import Foundation
import Testing
@testable import PhotokichinDomain

@Suite("Photo domain")
struct PhotoDomainTests {
    @Test("JPG and CR3 pair reports partial and complete states")
    func pairImportState() {
        let root = URL(fileURLWithPath: "/tmp/domain-fixture")
        var group = PhotoGroup(
            id: "pair",
            basename: "IMG_0001",
            directory: root,
            renderedImageURL: root.appendingPathComponent("IMG_0001.JPG"),
            rawURL: root.appendingPathComponent("IMG_0001.CR3"),
            movieURL: nil,
            captureDate: nil,
            metadata: .empty,
            importedRenderedImage: true,
            importedRAW: false,
            isMetadataLoaded: false
        )

        #expect(group.cardImportState == .partial)
        group.importedRAW = true
        #expect(group.cardImportState == .imported)
    }

    @Test("Source identity preserves volume and relative path")
    func sourceIdentity() throws {
        let root = URL(fileURLWithPath: "/Volumes/EOS_DIGITAL")
        let photo = root.appendingPathComponent("DCIM/100EOS_R/IMG_0001.JPG")
        let key = SourceIdentity.key(
            url: photo,
            variant: .renderedImage,
            sourceRoot: root,
            volumeUUID: "ABC-123"
        )

        #expect(key == "volume:abc-123:DCIM/100EOS_R/IMG_0001:JPG")
        let components = try #require(SourceIdentity.components(url: photo, sourceRoot: root, volumeUUID: "ABC-123"))
        #expect(components.relativePath == "DCIM/100EOS_R/IMG_0001")
    }

    @Test("Import filters distinguish none, possible, partial, and complete groups")
    func importFiltersAndOrdering() {
        let root = URL(fileURLWithPath: "/tmp/domain-filter-fixture")
        let none = group(root: root, jpeg: false, raw: false, importedRenderedImage: false, importedRAW: false)
        #expect(none.cardImportState == .notApplicable)

        let pending = group(root: root, jpeg: true, raw: true, importedRenderedImage: false, importedRAW: false)
        #expect(pending.cardImportState == .notImported)

        var possible = group(root: root, jpeg: true, raw: true, importedRenderedImage: false, importedRAW: false)
        possible.possibleImportedRenderedImage = true
        #expect(possible.displayImportState == .possible)
        #expect(possible.matches(importFilter: .possible, operationFilter: .all, selected: false, deleteCandidate: false))
        #expect(!possible.matches(importFilter: .notImported, operationFilter: .all, selected: false, deleteCandidate: false))

        let rawOnlyImported = group(root: root, jpeg: true, raw: true, importedRenderedImage: false, importedRAW: true)
        #expect(rawOnlyImported.cardImportState == .partial)
        let renderedOnlyImported = group(root: root, jpeg: true, raw: true, importedRenderedImage: true, importedRAW: false)
        #expect(renderedOnlyImported.cardImportState == .partial)
        let complete = group(root: root, jpeg: true, raw: true, importedRenderedImage: true, importedRAW: true)
        #expect(complete.cardImportState == .imported)
        #expect(complete.matches(importFilter: .all, operationFilter: .all, selected: false, deleteCandidate: false))
        let cr3Only = group(root: root, jpeg: false, raw: true, importedRenderedImage: false, importedRAW: true)
        #expect(cr3Only.cardImportState == .imported)
        #expect(rawOnlyImported.matches(importFilter: .partial, operationFilter: .selected, selected: true, deleteCandidate: false))
        #expect(!rawOnlyImported.matches(importFilter: .notImported, operationFilter: .selected, selected: true, deleteCandidate: false))
        #expect(!rawOnlyImported.matches(importFilter: .partial, operationFilter: .deleteCandidates, selected: true, deleteCandidate: false))

        let chronological = [
            group(root: root, jpeg: true, raw: true, importedRenderedImage: false, importedRAW: false),
            group(root: root, jpeg: true, raw: true, importedRenderedImage: true, importedRAW: true),
            group(root: root, jpeg: true, raw: true, importedRenderedImage: false, importedRAW: false)
        ]
        let clustered = PhotoImportCluster.preservingOrder(dateKey: "2026年08月13日", photos: chronological)
        #expect(clustered.flatMap(\.photos).map(\.id) == chronological.map(\.id))
    }

    @Test("Metadata publication preserves initial order and grid navigation boundaries")
    func presentationOrderAndNavigation() {
        let root = URL(fileURLWithPath: "/tmp/domain-navigation-fixture")
        var earlier = group(root: root, jpeg: true, raw: true, importedRenderedImage: false, importedRAW: false)
        var later = group(root: root, jpeg: true, raw: true, importedRenderedImage: true, importedRAW: true)
        earlier.presentationOrder = 10
        later.presentationOrder = 11
        earlier.captureDate = Date(timeIntervalSince1970: 2)
        later.captureDate = Date(timeIntervalSince1970: 1)
        #expect([later, earlier].sorted(by: PhotoGroup.presentationPrecedes).map(\.id) == [earlier.id, later.id])
        #expect(PhotoGridNavigation.previousSectionIndex(currentColumn: 2, previousCount: 800, columns: 5) == 797)
        #expect(PhotoGridNavigation.previousSectionIndex(currentColumn: 4, previousCount: 802, columns: 5) == 801)
        #expect(PhotoGridNavigation.pageTargetIndex(current: 803, count: 804, itemOffset: -15) == 788)
    }

    @Test("Camera photo references expose exactly the remote variants")
    func cameraBackedValues() {
        let pair = CameraPhotoReference(
            cameraID: "camera-test",
            groupKey: "DCIM/100EOS_R/IMG_0001",
            assets: [
                CameraAssetReference(identifier: "handle:1", filename: "IMG_0001.JPG", variant: .renderedImage, fileSize: 10, captureDate: nil),
                CameraAssetReference(identifier: "handle:2", filename: "IMG_0001.CR3", variant: .raw, fileSize: 20, captureDate: nil)
            ]
        )
        let group = PhotoGroup(id: "camera:camera-test:DCIM/100EOS_R/IMG_0001", basename: "IMG_0001", directory: URL(fileURLWithPath: "/__camera__"), renderedImageURL: nil, rawURL: nil, movieURL: nil, captureDate: nil, metadata: .empty, importedRenderedImage: false, importedRAW: false, isMetadataLoaded: true, cameraReference: pair)
        #expect(group.isCameraBacked)
        #expect(group.variants == [.renderedImage, .raw])
        #expect(group.importableVariants == [.renderedImage, .raw])
        #expect(group.cardImportState == .notImported)

        let renderedOnly = CameraPhotoReference(cameraID: "camera-test", groupKey: "IMG_0002", assets: [CameraAssetReference(identifier: "handle:3", filename: "IMG_0002.JPG", variant: .renderedImage, fileSize: 30, captureDate: nil)])
        let jpegGroup = PhotoGroup(id: "camera:camera-test:IMG_0002", basename: "IMG_0002", directory: URL(fileURLWithPath: "/__camera__"), renderedImageURL: nil, rawURL: nil, movieURL: nil, captureDate: nil, metadata: .empty, importedRenderedImage: false, importedRAW: false, isMetadataLoaded: true, cameraReference: renderedOnly)
        #expect(jpegGroup.variants == [.renderedImage])
        #expect(jpegGroup.importableVariants == [.renderedImage])

        let rawOnly = CameraPhotoReference(cameraID: "camera-test", groupKey: "IMG_0003", assets: [CameraAssetReference(identifier: "handle:4", filename: "IMG_0003.CR3", variant: .raw, fileSize: 40, captureDate: nil)])
        let rawGroup = PhotoGroup(id: "camera:camera-test:IMG_0003", basename: "IMG_0003", directory: URL(fileURLWithPath: "/__camera__"), renderedImageURL: nil, rawURL: nil, movieURL: nil, captureDate: nil, metadata: .empty, importedRenderedImage: false, importedRAW: false, isMetadataLoaded: true, cameraReference: rawOnly)
        #expect(rawGroup.variants == [.raw])
        #expect(rawGroup.importableVariants == [.raw])
    }

    @Test("Filename identity keeps extensions while normalizing case")
    func filenameIdentity() {
        #expect(FilenameIdentity.key(for: "IMG_0001.JPG") == "img_0001.jpg")
        #expect(FilenameIdentity.key(for: "フォルダ/写真.JPG") == "写真.jpg")
    }

    private func group(root: URL, jpeg: Bool, raw: Bool, importedRenderedImage: Bool, importedRAW: Bool) -> PhotoGroup {
        PhotoGroup(id: UUID().uuidString, basename: "IMG_0001", directory: root,
                   renderedImageURL: jpeg ? root.appendingPathComponent("IMG_0001.JPG") : nil,
                   rawURL: raw ? root.appendingPathComponent("IMG_0001.CR3") : nil,
                   movieURL: nil, captureDate: Date(timeIntervalSince1970: 0), metadata: .empty,
                   importedRenderedImage: importedRenderedImage, importedRAW: importedRAW, isMetadataLoaded: true)
    }
}
