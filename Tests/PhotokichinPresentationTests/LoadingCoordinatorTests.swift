import AppKit
import Foundation
import Testing
@testable import PhotokichinDomain
@testable import PhotokichinApplication
@testable import PhotokichinPresentation

private nonisolated final class LoadingGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var result: Result<Value, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiters: [CheckedContinuation<Value, Never>] = []

    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }

    func run() async -> Value {
        markStarted()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result.getSuccess())
            } else {
                resultWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish(_ value: Value) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .success(value)
        let waiters = resultWaiters
        resultWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: value) }
    }

    private func markStarted() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }
}

private nonisolated extension Result where Failure == Never {
    func getSuccess() -> Success {
        switch self { case let .success(value): return value }
    }
}

private nonisolated final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }
    func update(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}

private nonisolated final class ThumbnailDataLoaderRouter: @unchecked Sendable {
    typealias Loader = @Sendable (URL, Int) async -> Data?
    private let lock = NSLock()
    private var loader: Loader = { _, _ in nil }

    func setLoader(_ loader: @escaping Loader) { lock.lock(); self.loader = loader; lock.unlock() }
    func load(url: URL, maxPixel: Int) async -> Data? {
        let loader = currentLoader()
        return await loader(url, maxPixel)
    }

    private func currentLoader() -> Loader { lock.lock(); defer { lock.unlock() }; return loader }
}

private nonisolated final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        lock.lock()
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        lock.unlock()
        for (_, waiter) in ready { waiter.resume() }
    }

    func wait(for expected: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if count >= expected {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((expected, continuation))
                lock.unlock()
            }
        }
    }

    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private nonisolated struct EmptyMediaReader: MediaReading {
    func readMetadata(url: URL) -> PhotoMetadata? { nil }
    func thumbnailData(url: URL, maxPixel: Int) -> Data? { nil }
}

@MainActor
@Suite("Loading coordinators")
struct LoadingCoordinatorTests {
    @Test("Already-loaded and URL-less metadata are delivered immediately")
    func metadataImmediateHandling() async throws {
        let coordinator = MetadataLoadingCoordinator(mediaReader: EmptyMediaReader())
        let root = fixtureRoot("metadata-immediate")
        let loadedMetadata = makeLoadedMetadata()
        let alreadyLoaded = makeLoadingGroup(root: root, id: "loaded", path: "loaded.JPG", isMetadataLoaded: true, metadata: loadedMetadata)
        var immediateResult: PhotoMetadata?
        let immediateID = coordinator.enqueue(group: alreadyLoaded, priority: .visible, onMetadata: { immediateResult = $0 })
        #expect(immediateID == nil)
        #expect(immediateResult == loadedMetadata)

        let noPrimaryURL = makeLoadingGroup(root: root, id: "no-primary", path: nil)
        var missingResultWasDelivered = false
        let missingID = coordinator.enqueue(group: noPrimaryURL, priority: .background, onMetadata: { missingResultWasDelivered = $0 == nil })
        #expect(missingID == nil)
        #expect(missingResultWasDelivered)
    }

    @Test("Metadata priority bypasses suspension and promotion reorders queued work")
    func metadataPriorityAndPromotion() async throws {
        let coordinator = MetadataLoadingCoordinator(mediaReader: EmptyMediaReader())
        let root = fixtureRoot("metadata-priority")
        let loadedMetadata = makeLoadedMetadata()
        let background = makeLoadingGroup(root: root, id: "background", path: "background.JPG")
        let visible = makeLoadingGroup(root: root, id: "visible", path: "visible.JPG")
        let viewer = makeLoadingGroup(root: root, id: "viewer", path: "viewer.JPG")
        let promoted = makeLoadingGroup(root: root, id: "promoted", path: "promoted.JPG")
        let backgroundGate = LoadingGate<PhotoMetadata?>()
        let visibleGate = LoadingGate<PhotoMetadata?>()
        let viewerGate = LoadingGate<PhotoMetadata?>()
        let promotedGate = LoadingGate<PhotoMetadata?>()
        let starts = LockedValue<[String]>([])
        let callbackSignals = ["background": TestSignal(), "visible": TestSignal(), "viewer": TestSignal(), "promoted": TestSignal()]
        coordinator.suspendBackgroundReads()
        _ = coordinator.enqueue(group: background, priority: .background, loader: { _ in starts.update { $0.append("background") }; return await backgroundGate.run() }, onMetadata: { _ in callbackSignals["background"]?.signal() })
        #expect(!backgroundGate.hasStarted)
        _ = coordinator.enqueue(group: visible, priority: .visible, loader: { _ in starts.update { $0.append("visible") }; return await visibleGate.run() }, onMetadata: { _ in callbackSignals["visible"]?.signal() })
        await visibleGate.waitUntilStarted()
        _ = coordinator.enqueue(group: viewer, priority: .viewerCurrent, loader: { _ in starts.update { $0.append("viewer") }; return await viewerGate.run() }, onMetadata: { _ in callbackSignals["viewer"]?.signal() })
        await viewerGate.waitUntilStarted()
        #expect(starts.read() == ["visible", "viewer"])
        _ = coordinator.enqueue(group: promoted, priority: .prefetch, loader: { _ in starts.update { $0.append("promoted") }; return await promotedGate.run() }, onMetadata: { _ in callbackSignals["promoted"]?.signal() })
        coordinator.prioritize(groupID: promoted.id, priority: .viewerNeighbor)
        visibleGate.finish(loadedMetadata)
        await callbackSignals["visible"]!.wait(for: 1)
        await promotedGate.waitUntilStarted()
        #expect(starts.read().last == "promoted")
        promotedGate.finish(loadedMetadata)
        viewerGate.finish(loadedMetadata)
        await callbackSignals["promoted"]!.wait(for: 1)
        await callbackSignals["viewer"]!.wait(for: 1)
        coordinator.resumeBackgroundReads()
        await backgroundGate.waitUntilStarted()
        backgroundGate.finish(loadedMetadata)
        await callbackSignals["background"]!.wait(for: 1)
    }

    @Test("Metadata observers share one read and cancellation leaves the remaining observer alive")
    func metadataSharedReadCancellation() async throws {
        let coordinator = MetadataLoadingCoordinator(mediaReader: EmptyMediaReader())
        let root = fixtureRoot("metadata-shared")
        let group = makeLoadingGroup(root: root, id: "shared", path: "shared.JPG")
        let loadedMetadata = makeLoadedMetadata()
        let gate = LoadingGate<PhotoMetadata?>()
        let loadCount = LockedValue(0)
        let firstSignal = TestSignal()
        let secondSignal = TestSignal()
        var firstValue: PhotoMetadata??
        var secondValue: PhotoMetadata??
        let loader: @Sendable (TaskPriority) async -> PhotoMetadata? = { _ in loadCount.update { $0 += 1 }; let value = await gate.run(); return Task.isCancelled ? nil : value }
        let firstID = coordinator.enqueue(group: group, priority: .visible, loader: loader, onMetadata: { firstValue = $0; firstSignal.signal() })
        #expect(firstID != nil)
        await gate.waitUntilStarted()
        let secondID = coordinator.enqueue(group: group, priority: .viewerNeighbor, loader: loader, onMetadata: { secondValue = $0; secondSignal.signal() })
        #expect(secondID != nil)
        if let firstID { coordinator.cancel(firstID) }
        gate.finish(loadedMetadata)
        await secondSignal.wait(for: 1)
        #expect(loadCount.read() == 1)
        #expect(firstSignal.value == 0)
        #expect(firstValue == nil)
        #expect(secondValue == loadedMetadata)
    }

    @Test("Metadata cancelAll and quiesce discard work, then resume accepts new work")
    func metadataCancelAllQuiesceAndResume() async throws {
        let coordinator = MetadataLoadingCoordinator(mediaReader: EmptyMediaReader())
        let root = fixtureRoot("metadata-lifecycle")
        let loadedMetadata = makeLoadedMetadata()
        let cancelledGate = LoadingGate<PhotoMetadata?>()
        var cancelledCallback = false
        coordinator.suspendBackgroundReads()
        _ = coordinator.enqueue(group: makeLoadingGroup(root: root, id: "cancelled", path: "cancelled.JPG"), priority: .background, loader: { _ in await cancelledGate.run() }, onMetadata: { _ in cancelledCallback = true })
        coordinator.cancelAll()
        coordinator.resumeBackgroundReads()
        #expect(!cancelledGate.hasStarted)
        #expect(!cancelledCallback)

        let quiesceGate = LoadingGate<PhotoMetadata?>()
        let quiesceSignal = TestSignal()
        _ = coordinator.enqueue(group: makeLoadingGroup(root: root, id: "quiesce", path: "quiesce.JPG"), priority: .visible, loader: { _ in await quiesceGate.run() }, onMetadata: { _ in quiesceSignal.signal() })
        await quiesceGate.waitUntilStarted()
        let quiesceTask = Task { @MainActor in await coordinator.quiesce() }
        await Task.yield()
        let rejected = coordinator.enqueue(group: makeLoadingGroup(root: root, id: "rejected", path: "rejected.JPG"), priority: .visible, onMetadata: { _ in })
        #expect(rejected == nil)
        quiesceGate.finish(loadedMetadata)
        await quiesceTask.value
        #expect(quiesceSignal.value == 0)

        coordinator.resumeAfterQuiesce()
        let resumedGate = LoadingGate<PhotoMetadata?>()
        let resumedSignal = TestSignal()
        _ = coordinator.enqueue(group: makeLoadingGroup(root: root, id: "resumed", path: "resumed.JPG"), priority: .visible, loader: { _ in await resumedGate.run() }, onMetadata: { _ in resumedSignal.signal() })
        await resumedGate.waitUntilStarted()
        resumedGate.finish(loadedMetadata)
        await resumedSignal.wait(for: 1)
    }

    @Test("Thumbnail cache returns exact and best available sizes")
    func thumbnailCache() throws {
        let root = fixtureRoot("thumbnail-cache")
        let url = root.appendingPathComponent("cache.JPG")
        let data = try #require(Data(base64Encoded: imageBase64))
        let image = try #require(NSImage(data: data))
        let small = try #require(NSImage(data: data))
        let large = try #require(NSImage(data: data))
        let cache = ThumbnailCache()
        cache.store(small, for: url, maxPixel: 100)
        cache.store(large, for: url, maxPixel: 300)
        #expect(cache.image(for: url, maxPixel: 100) === small)
        #expect(cache.bestImage(for: url, maxPixel: 250) === small)
        #expect(cache.bestImage(for: url, maxPixel: 400) === large)
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test("Thumbnail priority starts viewer work before queued prefetch work")
    func thumbnailPriority() async throws {
        let root = fixtureRoot("thumbnail-priority")
        let cache = ThumbnailCache()
        let router = ThumbnailDataLoaderRouter()
        let coordinator = ThumbnailLoadingCoordinator(cache: cache) { url, maxPixel in await router.load(url: url, maxPixel: maxPixel) }
        coordinator.beginSource(rootURL: root)
        let imageData = try #require(Data(base64Encoded: imageBase64))
        let groupA = makeLoadingGroup(root: root, id: "a", path: "A.JPG")
        let groupB = makeLoadingGroup(root: root, id: "b", path: "B.JPG")
        let groupC = makeLoadingGroup(root: root, id: "c", path: "C.JPG")
        let gateA = LoadingGate<Data?>(); let gateB = LoadingGate<Data?>(); let gateC = LoadingGate<Data?>()
        let starts = LockedValue<[String]>([])
        let signalA = TestSignal(); let signalB = TestSignal(); let signalC = TestSignal()
        router.setLoader { url, _ in
            starts.update { $0.append(url.lastPathComponent) }
            if url == groupA.primaryURL { return await gateA.run() }
            if url == groupB.primaryURL { return await gateB.run() }
            if url == groupC.primaryURL { return await gateC.run() }
            return nil
        }
        defer { coordinator.cancelAll() }
        let firstID = coordinator.subscribe(group: groupA, maxPixel: 100, priority: .visible) { if $0 != nil { signalA.signal() } }
        #expect(firstID != nil)
        await gateA.waitUntilStarted()
        _ = coordinator.subscribe(group: groupB, maxPixel: 100, priority: .prefetch) { if $0 != nil { signalB.signal() } }
        _ = coordinator.subscribe(group: groupC, maxPixel: 100, priority: .viewerCurrent) { if $0 != nil { signalC.signal() } }
        gateA.finish(imageData)
        await signalA.wait(for: 1)
        await gateC.waitUntilStarted()
        #expect(starts.read() == ["A.JPG", "C.JPG"])
        gateC.finish(imageData)
        await signalC.wait(for: 1)
        await gateB.waitUntilStarted()
        gateB.finish(imageData)
        await signalB.wait(for: 1)
    }

    @Test("Thumbnail shared subscription cancellation keeps the remaining observer alive")
    func thumbnailSharedSubscriptionCancellation() async throws {
        let root = fixtureRoot("thumbnail-shared")
        let cache = ThumbnailCache()
        let router = ThumbnailDataLoaderRouter()
        let coordinator = ThumbnailLoadingCoordinator(cache: cache) { url, maxPixel in await router.load(url: url, maxPixel: maxPixel) }
        coordinator.beginSource(rootURL: root)
        let imageData = try #require(Data(base64Encoded: imageBase64))
        let group = makeLoadingGroup(root: root, id: "shared", path: "shared.JPG")
        let gate = LoadingGate<Data?>(); let loads = LockedValue(0); let firstSignal = TestSignal(); let secondSignal = TestSignal()
        var firstImage = false; var secondImage = false
        router.setLoader { url, _ in
            guard url == group.primaryURL else { return imageData }
            loads.update { $0 += 1 }
            let value = await gate.run()
            return Task.isCancelled ? nil : value
        }
        let firstID = coordinator.subscribe(group: group, maxPixel: 120, priority: .visible) { firstImage = $0 != nil; firstSignal.signal() }
        #expect(firstID != nil)
        await gate.waitUntilStarted()
        let secondID = coordinator.subscribe(group: group, maxPixel: 120, priority: .viewerNeighbor) { secondImage = $0 != nil; secondSignal.signal() }
        #expect(secondID != nil)
        if let firstID { coordinator.cancel(firstID) }
        gate.finish(imageData)
        await secondSignal.wait(for: 1)
        #expect(loads.read() == 1)
        #expect(!firstImage && firstSignal.value == 0)
        #expect(secondImage)
        coordinator.cancelAll()
    }

    @Test("Thumbnail source switching rejects stale groups")
    func thumbnailSourceSwitchRejectsStaleGroups() async throws {
        let root = fixtureRoot("thumbnail-source")
        let coordinator = ThumbnailLoadingCoordinator(cache: ThumbnailCache()) { _, _ in nil }
        coordinator.beginSource(rootURL: root)
        let current = makeLoadingGroup(root: root, id: "current", path: "current.JPG")
        #expect(coordinator.subscribe(group: current, maxPixel: 120, priority: .visible) { _ in } != nil)
        coordinator.cancelAll()
        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        coordinator.beginSource(rootURL: otherRoot)
        let oldSignal = TestSignal()
        #expect(coordinator.subscribe(group: current, maxPixel: 120, priority: .visible) { _ in oldSignal.signal() } == nil)
        #expect(oldSignal.value == 0)
    }

    @Test("Thumbnail working sets, cancelAll, and quiesce resume independently")
    func thumbnailWorkingSetCancelAndQuiesce() async throws {
        let root = fixtureRoot("thumbnail-lifecycle")
        let cache = ThumbnailCache()
        let router = ThumbnailDataLoaderRouter()
        let coordinator = ThumbnailLoadingCoordinator(cache: cache) { url, maxPixel in await router.load(url: url, maxPixel: maxPixel) }
        coordinator.beginSource(rootURL: root)
        let imageData = try #require(Data(base64Encoded: imageBase64))
        let first = makeLoadingGroup(root: root, id: "working-a", path: "working-a.JPG")
        let second = makeLoadingGroup(root: root, id: "working-b", path: "working-b.JPG")
        let firstGate = LoadingGate<Data?>(); let secondGate = LoadingGate<Data?>(); let ready = LockedValue<[String]>([]); let readySignal = TestSignal()
        router.setLoader { url, _ in if url == first.primaryURL { return await firstGate.run() }; if url == second.primaryURL { return await secondGate.run() }; return imageData }
        coordinator.updateListWorkingSet(groups: [(first, .visible)], maxPixel: 140) { id, _ in ready.update { $0.append(id) }; readySignal.signal() }
        await firstGate.waitUntilStarted(); firstGate.finish(imageData); await readySignal.wait(for: 1)
        coordinator.updateListWorkingSet(groups: [(second, .visible)], maxPixel: 140) { id, _ in ready.update { $0.append(id) }; readySignal.signal() }
        await secondGate.waitUntilStarted(); secondGate.finish(imageData); await readySignal.wait(for: 2)
        #expect(ready.read() == [first.id, second.id])

        coordinator.cancelAll()
        let cancelA = makeLoadingGroup(root: root, id: "cancel-a", path: "cancel-a.JPG")
        let cancelB = makeLoadingGroup(root: root, id: "cancel-b", path: "cancel-b.JPG")
        let cancelGateA = LoadingGate<Data?>(); let cancelGateB = LoadingGate<Data?>()
        router.setLoader { url, _ in if url == cancelA.primaryURL { return await cancelGateA.run() }; if url == cancelB.primaryURL { return await cancelGateB.run() }; return imageData }
        _ = coordinator.subscribe(group: cancelA, maxPixel: 160, priority: .visible) { _ in }
        await cancelGateA.waitUntilStarted()
        _ = coordinator.subscribe(group: cancelB, maxPixel: 160, priority: .prefetch) { _ in }
        coordinator.cancelAll(); cancelGateA.finish(imageData); await Task.yield()
        #expect(!cancelGateB.hasStarted)

        let quiesce = makeLoadingGroup(root: root, id: "quiesce", path: "quiesce.JPG")
        let quiesceGate = LoadingGate<Data?>()
        router.setLoader { url, _ in if url == quiesce.primaryURL { return await quiesceGate.run() }; return imageData }
        _ = coordinator.subscribe(group: quiesce, maxPixel: 180, priority: .visible) { _ in }
        await quiesceGate.waitUntilStarted()
        let quiesceTask = Task { @MainActor in await coordinator.quiesce() }
        await Task.yield()
        #expect(coordinator.subscribe(group: makeLoadingGroup(root: root, id: "rejected", path: "rejected.JPG"), maxPixel: 180, priority: .visible) { _ in } == nil)
        quiesceGate.finish(imageData); await quiesceTask.value
        coordinator.resumeAfterQuiesce()
        let resumed = makeLoadingGroup(root: root, id: "resumed", path: "resumed.JPG")
        let resumedGate = LoadingGate<Data?>(); let resumedSignal = TestSignal()
        router.setLoader { url, _ in if url == resumed.primaryURL { return await resumedGate.run() }; return imageData }
        _ = coordinator.subscribe(group: resumed, maxPixel: 180, priority: .visible) { if $0 != nil { resumedSignal.signal() } }
        await resumedGate.waitUntilStarted(); resumedGate.finish(imageData); await resumedSignal.wait(for: 1)
    }

    private let imageBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    private func fixtureRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeLoadedMetadata() -> PhotoMetadata {
        PhotoMetadata(captureDate: Date(timeIntervalSince1970: 123), cameraMake: "Canon", cameraModel: "EOS R5", lensModel: nil, focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil, exposureBias: nil, orientation: nil, gps: nil, firmware: nil, pixelWidth: nil, pixelHeight: nil)
    }

    private func makeLoadingGroup(root: URL, id: String, path: String?, isMetadataLoaded: Bool = false, metadata: PhotoMetadata = .empty) -> PhotoGroup {
        PhotoGroup(id: id, basename: path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? id, directory: root, renderedImageURL: path.map { root.appendingPathComponent($0) }, rawURL: nil, movieURL: nil, captureDate: nil, metadata: metadata, importedRenderedImage: false, importedRAW: false, isMetadataLoaded: isMetadataLoaded)
    }
}
