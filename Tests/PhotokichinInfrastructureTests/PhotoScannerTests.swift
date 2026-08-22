import Foundation
import Testing
@testable import PhotokichinDomain
@testable import PhotokichinInfrastructure

@Suite("Photo scanner")
struct PhotoScannerTests {
    @Test("Pairs JPG and CR3 while excluding Canon management files")
    func pairingAndExclusion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-scanner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dcim = root.appendingPathComponent("DCIM/100EOS_R", isDirectory: true)
        let management = root.appendingPathComponent("CANONMSC", isDirectory: true)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: management, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: dcim.appendingPathComponent("IMG_0001.JPG"))
        try Data("raw".utf8).write(to: dcim.appendingPathComponent("IMG_0001.CR3"))
        try Data("ignored".utf8).write(to: management.appendingPathComponent("IMG_9999.JPG"))

        let groups = PhotoScanner().scan(
            root: root,
            initialPresentationBatchSize: .max,
            initialPresentationGroupTarget: .max,
            progress: nil
        )

        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.variants == [.jpeg, .raw])
        #expect(!group.id.contains("CANONMSC"))
    }
}
