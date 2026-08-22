import Foundation
import Testing
@testable import PhotokichinDomain
@testable import PhotokichinApplication
@testable import PhotokichinInfrastructure

@Suite("Camera catalog")
struct CameraCatalogTests {
    @Test("Camera builder pairs JPG and CR3 and handles single-variant assets")
    func builderPairsVariants() throws {
        let groups = CameraCatalogBuilder.groups(cameraID: "camera-pair", cameraName: "Test Camera", entries: makeEntries(), previousGroups: [], classifier: InfrastructureTestSupport.classifier)
        let paired = try requireValue(groups.first { $0.id.hasSuffix("DCIM/100/IMG_0001") }, "paired group is missing")
        #expect(Set(paired.cameraReference?.assets.map(\.variant) ?? []) == Set([.renderedImage, .raw]))
        #expect(paired.cameraReference?.assets.count == 2)
        let jpgOnly = try requireValue(groups.first { $0.id.hasSuffix("DCIM/100/IMG_0002") }, "JPG-only group is missing")
        #expect(jpgOnly.cameraReference?.asset(for: .renderedImage) != nil)
        #expect(jpgOnly.cameraReference?.asset(for: .raw) == nil)
        let rawOnly = try requireValue(groups.first { $0.id.hasSuffix("DCIM/100/IMG_0003") }, "CR3-only group is missing")
        #expect(rawOnly.cameraReference?.asset(for: .raw) != nil)
        #expect(rawOnly.cameraReference?.asset(for: .renderedImage) == nil)
        let movie = try requireValue(groups.first { $0.id.hasSuffix("DCIM/100/CLIP_0001") }, "MOV group is missing")
        #expect(movie.cameraReference?.asset(for: .movie) != nil)
    }

    @Test("Camera builder rejects unsupported extensions before grouping")
    func builderRejectsUnsupportedExtensions() {
        #expect(CameraCatalogBuilder.variant(for: "README.TXT", classifier: InfrastructureTestSupport.classifier) == nil)
        let groups = CameraCatalogBuilder.groups(cameraID: "camera-unsupported", cameraName: "Test Camera", entries: makeEntries(), previousGroups: [], classifier: InfrastructureTestSupport.classifier)
        #expect(groups.allSatisfy { !$0.id.contains("README") })
    }

    @Test("Camera builder assigns a contiguous stable presentation order")
    func builderAssignsStablePresentationOrder() {
        let groups = CameraCatalogBuilder.groups(cameraID: "camera-order", cameraName: "Test Camera", entries: makeEntries(), previousGroups: [], classifier: InfrastructureTestSupport.classifier)
        #expect(groups.count == 5)
        #expect(groups.allSatisfy { $0.presentationOrder >= 0 })
        #expect(groups.map(\.presentationOrder) == Array(0..<groups.count))
        let dates = groups.map(\.captureDate)
        #expect(dates == dates.sorted { ($0 ?? .distantFuture) < ($1 ?? .distantFuture) })
    }

    @Test("Camera builder preserves camera metadata and separates folder identities")
    func builderSeparatesFoldersAndCopiesMetadata() throws {
        let groups = CameraCatalogBuilder.groups(cameraID: "camera-folder", cameraName: "Test Camera", entries: makeEntries(), previousGroups: [], classifier: InfrastructureTestSupport.classifier)
        #expect(groups.allSatisfy { $0.metadata.cameraModel == "Test Camera" })
        let sameBasename = groups.filter { $0.basename == "IMG_0002" }
        #expect(sameBasename.count == 2)
        #expect(sameBasename.map(\.id) == sameBasename.map(\.id).sorted())
        let jpgOnly = try requireValue(groups.first { $0.basename == "IMG_0002" && $0.id.contains("DCIM/100") }, "JPG-only group is missing")
        let withoutName = CameraCatalogBuilder.groups(cameraID: "camera-folder", cameraName: nil, entries: [CameraCatalogEntry(asset: cameraAsset(id: "no-name", filename: "IMG.JPG", path: "IMG.JPG", variant: .renderedImage, date: Date(timeIntervalSince1970: 1)), pairedRaw: nil)], previousGroups: [], classifier: InfrastructureTestSupport.classifier)
        #expect(withoutName.first?.metadata.cameraModel == nil)
        #expect(jpgOnly.basename == "IMG_0002")
    }

    @Test("Camera builder preserves import, metadata, photo identity, and labels")
    func builderPreservesExistingState() throws {
        let groups = CameraCatalogBuilder.groups(cameraID: "camera-state", cameraName: "Test Camera", entries: makeEntries(), previousGroups: [], classifier: InfrastructureTestSupport.classifier)
        let previous = try requireValue(groups.first { $0.id.hasSuffix("DCIM/100/IMG_0002") }, "previous JPG group is missing")
        let removed = try requireValue(groups.first { $0.id.hasSuffix("DCIM/100/IMG_0003") }, "removed CR3 group is missing")
        var state = previous
        state.importedRenderedImage = true
        state.importedRAW = true
        state.possibleImportedRenderedImage = true
        state.possibleImportedRAW = true
        state.isMetadataLoaded = true
        state.libraryAssetStatus = .registered
        state.photoID = "persistent-photo-id"
        state.labels = [PhotoLabel(id: "label-1", name: "Keep", normalizedName: "keep", colorHex: "#000000", sortOrder: 0, lastUsedAt: nil)]
        let changed = cameraAsset(id: "path:DCIM/100/IMG_0002.JPG", filename: "IMG_0002.JPG", path: "DCIM/100/IMG_0002.JPG", variant: .renderedImage, date: Date(timeIntervalSince1970: 50))
        let replacement = CameraCatalogBuilder.groups(cameraID: "camera-state", cameraName: "Test Camera", entries: [CameraCatalogEntry(asset: changed, pairedRaw: nil)], previousGroups: [state, removed], classifier: InfrastructureTestSupport.classifier)
        #expect(replacement.count == 1)
        let preserved = try requireValue(replacement.first, "replacement group is missing")
        #expect(preserved.importedRenderedImage && preserved.importedRAW)
        #expect(preserved.possibleImportedRenderedImage && preserved.possibleImportedRAW)
        #expect(preserved.isMetadataLoaded && preserved.libraryAssetStatus == .registered)
        #expect(preserved.photoID == "persistent-photo-id" && preserved.labels.count == 1)
        #expect(!replacement.contains { $0.id == removed.id })
    }

    @Test("Refresh gate accepts the first notification")
    func refreshGateAcceptsInitialNotification() {
        let base = Date(timeIntervalSince1970: 1_000)
        #expect(CameraCatalogRefreshGate.decision(receivedAt: base, completionEventAt: nil, updateInFlight: false, updateStartedAt: nil, updateFinishedAt: nil, nextAllowedAt: nil) == .accepted)
    }

    @Test("Refresh gate ignores notifications inside the interval")
    func refreshGateRejectsInsideInterval() {
        let base = Date(timeIntervalSince1970: 1_000)
        let nextAllowed = base.addingTimeInterval(CameraCatalogRefreshGate.interval)
        #expect(CameraCatalogRefreshGate.decision(receivedAt: base.addingTimeInterval(4.999), completionEventAt: nil, updateInFlight: false, updateStartedAt: nil, updateFinishedAt: nil, nextAllowedAt: nextAllowed) == .ignored("five_second_interval"))
    }

    @Test("Refresh gate accepts the interval boundary")
    func refreshGateAcceptsIntervalBoundary() {
        let base = Date(timeIntervalSince1970: 1_000)
        let nextAllowed = base.addingTimeInterval(CameraCatalogRefreshGate.interval)
        #expect(CameraCatalogRefreshGate.decision(receivedAt: nextAllowed, completionEventAt: nil, updateInFlight: false, updateStartedAt: nil, updateFinishedAt: nil, nextAllowedAt: nextAllowed) == .accepted)
    }

    @Test("Refresh gate rejects notifications while replacement is in flight")
    func refreshGateRejectsInFlight() {
        let base = Date(timeIntervalSince1970: 1_000)
        #expect(CameraCatalogRefreshGate.decision(receivedAt: base.addingTimeInterval(1), completionEventAt: nil, updateInFlight: true, updateStartedAt: base, updateFinishedAt: nil, nextAllowedAt: nil) == .ignored("catalog_update_in_flight"))
    }

    @Test("Refresh gate rejects a notification before completion")
    func refreshGateRejectsBeforeCompletion() {
        let base = Date(timeIntervalSince1970: 1_000)
        let completion = base.addingTimeInterval(2)
        #expect(CameraCatalogRefreshGate.decision(receivedAt: base.addingTimeInterval(1), completionEventAt: completion, updateInFlight: false, updateStartedAt: nil, updateFinishedAt: nil, nextAllowedAt: nil) == .ignored("before_completion_event"))
    }

    @Test("Refresh gate accepts a notification after completion")
    func refreshGateAcceptsAfterCompletion() {
        let base = Date(timeIntervalSince1970: 1_000)
        let completion = base.addingTimeInterval(2)
        #expect(CameraCatalogRefreshGate.decision(receivedAt: base.addingTimeInterval(3), completionEventAt: completion, updateInFlight: false, updateStartedAt: nil, updateFinishedAt: nil, nextAllowedAt: nil) == .accepted)
    }

    private func makeEntries() -> [CameraCatalogEntry] {
        let early = Date(timeIntervalSince1970: 100)
        let middle = Date(timeIntervalSince1970: 200)
        let late = Date(timeIntervalSince1970: 300)
        let pairedJPEG = cameraAsset(id: "path:DCIM/100/IMG_0001.JPG", filename: "IMG_0001.JPG", path: "DCIM/100/IMG_0001.JPG", variant: .renderedImage, date: early)
        let pairedRAW = cameraAsset(id: "path:DCIM/100/IMG_0001.CR3", filename: "IMG_0001.CR3", path: "DCIM/100/IMG_0001.CR3", variant: .raw, date: early)
        let jpgOnly = cameraAsset(id: "path:DCIM/100/IMG_0002.JPG", filename: "IMG_0002.JPG", path: "DCIM/100/IMG_0002.JPG", variant: .renderedImage, date: middle)
        let rawOnly = cameraAsset(id: "path:DCIM/100/IMG_0003.CR3", filename: "IMG_0003.CR3", path: "DCIM/100/IMG_0003.CR3", variant: .raw, date: late)
        let movie = cameraAsset(id: "path:DCIM/100/CLIP_0001.MOV", filename: "CLIP_0001.MOV", path: "DCIM/100/CLIP_0001.MOV", variant: .movie, date: Date(timeIntervalSince1970: 250))
        let otherFolder = cameraAsset(id: "path:DCIM/101/IMG_0002.JPG", filename: "IMG_0002.JPG", path: "DCIM/101/IMG_0002.JPG", variant: .renderedImage, date: middle)
        return [
            CameraCatalogEntry(asset: rawOnly, pairedRaw: nil),
            CameraCatalogEntry(asset: pairedJPEG, pairedRaw: pairedRAW),
            CameraCatalogEntry(asset: jpgOnly, pairedRaw: nil),
            CameraCatalogEntry(asset: pairedJPEG, pairedRaw: pairedRAW),
            CameraCatalogEntry(asset: movie, pairedRaw: nil),
            CameraCatalogEntry(asset: otherFolder, pairedRaw: nil)
        ]
    }

    private func cameraAsset(id: String, filename: String, path: String, variant: AssetVariant, date: Date) -> CameraCatalogAsset {
        CameraCatalogAsset(identifier: id, filename: filename, remotePath: path, variant: variant, fileSize: 100, captureDate: date, width: 4_000, height: 3_000)
    }

    private func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        try #require(value, Comment(rawValue: message))
    }
}
