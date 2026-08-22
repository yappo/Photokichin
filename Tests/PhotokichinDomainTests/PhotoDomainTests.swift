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
            jpegURL: root.appendingPathComponent("IMG_0001.JPG"),
            rawURL: root.appendingPathComponent("IMG_0001.CR3"),
            movieURL: nil,
            captureDate: nil,
            metadata: .empty,
            importedJPEG: true,
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
            variant: .jpeg,
            sourceRoot: root,
            volumeUUID: "ABC-123"
        )

        #expect(key == "volume:abc-123:DCIM/100EOS_R/IMG_0001:JPG")
        let components = try #require(SourceIdentity.components(url: photo, sourceRoot: root, volumeUUID: "ABC-123"))
        #expect(components.relativePath == "DCIM/100EOS_R/IMG_0001")
    }
}
