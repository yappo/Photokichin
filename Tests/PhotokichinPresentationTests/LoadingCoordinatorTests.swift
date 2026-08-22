import AppKit
import Foundation
import Testing
@testable import PhotokichinDomain
@testable import PhotokichinApplication
@testable import PhotokichinInfrastructure
@testable import PhotokichinPresentation

/// A test-side completion gate. The loader marks itself as started, then
/// remains suspended until the test explicitly supplies its result. No sleep,
/// file size, or ImageIO timing is involved in these tests.
private nonisolated final class LoadingGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var result: Result<Value, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiters: [CheckedContinuation<Value, Never>] = []

    init() {}

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func run() async -> Value {
        markStarted()
        return await waitForResult()
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
        guard result == nil else {
            lock.unlock()
            return
        }
        result = .success(value)
        let waiters = resultWaiters
        resultWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }

    private func markStarted() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForResult() async -> Value {
        await withCheckedContinuation { continuation in
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
}

private nonisolated extension Result where Failure == Never {
    func getSuccess() -> Success {
        switch self {
        case let .success(value): return value
        }
    }
}

private nonisolated final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private nonisolated final class ThumbnailDataLoaderRouter: @unchecked Sendable {
    typealias Loader = @Sendable (URL, Int) async -> Data?

    private let lock = NSLock()
    private var loader: Loader = { _, _ in nil }

    func setLoader(_ loader: @escaping Loader) {
        lock.lock()
        self.loader = loader
        lock.unlock()
    }

    func load(url: URL, maxPixel: Int) async -> Data? {
        let loader = currentLoader()
        return await loader(url, maxPixel)
    }

    private func currentLoader() -> Loader {
        lock.lock()
        defer { lock.unlock() }
        return loader
    }
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
        for (_, waiter) in ready {
            waiter.resume()
        }
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

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private nonisolated struct EmptyMediaReader: MediaReading {
    func readMetadata(url: URL) -> PhotoMetadata? { nil }
    func thumbnailData(url: URL, maxPixel: Int) -> Data? { nil }
}

@MainActor
extension TestSupport {
    static func runLoadingCoordinatorTests() async throws {
        try await runMetadataLoadingCoordinatorTests()
        try runThumbnailCacheTests()
        try await runThumbnailLoadingCoordinatorTests()
        print("PASS: deterministic metadata and thumbnail coordinator scheduling, sharing, cancellation, source boundaries, and quiesce")
    }

    static func runMetadataLoadingCoordinatorTests() async throws {
        let coordinator = MetadataLoadingCoordinator(mediaReader: EmptyMediaReader())

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-loading-metadata-\(UUID().uuidString)", isDirectory: true)
        let loadedMetadata = PhotoMetadata(
            captureDate: Date(timeIntervalSince1970: 123),
            cameraMake: "Canon",
            cameraModel: "EOS R5",
            lensModel: nil,
            focalLength: nil,
            aperture: nil,
            shutterSpeed: nil,
            iso: nil,
            exposureBias: nil,
            orientation: nil,
            gps: nil,
            firmware: nil,
            pixelWidth: nil,
            pixelHeight: nil
        )

        let alreadyLoaded = makeLoadingGroup(
            root: root,
            id: "metadata-loaded",
            path: "loaded.JPG",
            isMetadataLoaded: true,
            metadata: loadedMetadata
        )
        var immediateResult: PhotoMetadata?
        let immediateID = coordinator.enqueue(
            group: alreadyLoaded,
            priority: .visible,
            onMetadata: { immediateResult = $0 }
        )
        #expect(immediateID == nil, "already loaded metadata must not create an observation")
        #expect(immediateResult == loadedMetadata, "already loaded metadata must be delivered immediately")

        let noPrimaryURL = makeLoadingGroup(
            root: root,
            id: "metadata-no-primary",
            path: nil,
            isMetadataLoaded: false
        )
        var missingResultWasDelivered = false
        let missingID = coordinator.enqueue(
            group: noPrimaryURL,
            priority: .background,
            onMetadata: { missingResultWasDelivered = $0 == nil }
        )
        #expect(missingID == nil, "a group without a primary URL must not create an observation")
        #expect(missingResultWasDelivered, "a group without a primary URL must deliver a nil result")

        // Background work stays queued during the initial scan. Visible and
        // viewer work bypass that pause, and a queued request can be promoted.
        let background = makeLoadingGroup(root: root, id: "metadata-background", path: "background.JPG")
        let visible = makeLoadingGroup(root: root, id: "metadata-visible", path: "visible.JPG")
        let viewer = makeLoadingGroup(root: root, id: "metadata-viewer", path: "viewer.JPG")
        let promoted = makeLoadingGroup(root: root, id: "metadata-promoted", path: "promoted.JPG")
        let backgroundGate = LoadingGate<PhotoMetadata?>()
        let visibleGate = LoadingGate<PhotoMetadata?>()
        let viewerGate = LoadingGate<PhotoMetadata?>()
        let promotedGate = LoadingGate<PhotoMetadata?>()
        let starts = LockedValue<[String]>([])
        let callbacks = LockedValue<[String: PhotoMetadata]>([:])
        let callbackSignals = [
            "background": TestSignal(),
            "visible": TestSignal(),
            "viewer": TestSignal(),
            "promoted": TestSignal()
        ]

        coordinator.suspendBackgroundReads()
        _ = coordinator.enqueue(
            group: background,
            priority: .background,
            loader: { _ in
                starts.update { $0.append("background") }
                return await backgroundGate.run()
            },
            onMetadata: { value in
                if let value { callbacks.update { $0["background"] = value } }
                callbackSignals["background"]?.signal()
            }
        )
        #expect(!backgroundGate.hasStarted, "background metadata must wait while background reads are suspended")

        _ = coordinator.enqueue(
            group: visible,
            priority: .visible,
            loader: { _ in
                starts.update { $0.append("visible") }
                return await visibleGate.run()
            },
            onMetadata: { value in
                if let value { callbacks.update { $0["visible"] = value } }
                callbackSignals["visible"]?.signal()
            }
        )
        await visibleGate.waitUntilStarted()

        _ = coordinator.enqueue(
            group: viewer,
            priority: .viewerCurrent,
            loader: { _ in
                starts.update { $0.append("viewer") }
                return await viewerGate.run()
            },
            onMetadata: { value in
                if let value { callbacks.update { $0["viewer"] = value } }
                callbackSignals["viewer"]?.signal()
            }
        )
        await viewerGate.waitUntilStarted()
        #expect(starts.read() == ["visible", "viewer"], "visible and viewer metadata must bypass the background pause in priority order")

        _ = coordinator.enqueue(
            group: promoted,
            priority: .prefetch,
            loader: { _ in
                starts.update { $0.append("promoted") }
                return await promotedGate.run()
            },
            onMetadata: { value in
                if let value { callbacks.update { $0["promoted"] = value } }
                callbackSignals["promoted"]?.signal()
            }
        )
        coordinator.prioritize(groupID: promoted.id, priority: .viewerNeighbor)
        visibleGate.finish(loadedMetadata)
        await callbackSignals["visible"]!.wait(for: 1)
        await promotedGate.waitUntilStarted()
        #expect(starts.read().last == "promoted", "prioritize must move a queued metadata request ahead of background work")
        promotedGate.finish(loadedMetadata)
        viewerGate.finish(loadedMetadata)
        await callbackSignals["promoted"]!.wait(for: 1)
        await callbackSignals["viewer"]!.wait(for: 1)
        coordinator.resumeBackgroundReads()
        await backgroundGate.waitUntilStarted()
        backgroundGate.finish(loadedMetadata)
        await callbackSignals["background"]!.wait(for: 1)
        #expect(callbacks.read().count == 4, "all controlled metadata requests must deliver their result")

        // Two observers share one read. Cancelling the first observer must not
        // cancel the read that the second observer still needs.
        coordinator.cancelAll()
        let sharedGroup = makeLoadingGroup(root: root, id: "metadata-shared", path: "shared.JPG")
        let sharedGate = LoadingGate<PhotoMetadata?>()
        let loadCount = LockedValue(0)
        let firstSignal = TestSignal()
        let secondSignal = TestSignal()
        var firstCallbackValue: PhotoMetadata??
        var secondCallbackValue: PhotoMetadata??
        let sharedLoader: @Sendable (TaskPriority) async -> PhotoMetadata? = { _ in
            loadCount.update { $0 += 1 }
            let value = await sharedGate.run()
            return Task.isCancelled ? nil : value
        }
        let firstID = coordinator.enqueue(
            group: sharedGroup,
            priority: .visible,
            loader: sharedLoader,
            onMetadata: { value in
                firstCallbackValue = value
                firstSignal.signal()
            }
        )
        #expect(firstID != nil, "the first metadata observer must be registered")
        await sharedGate.waitUntilStarted()
        let secondID = coordinator.enqueue(
            group: sharedGroup,
            priority: .viewerNeighbor,
            loader: sharedLoader,
            onMetadata: { value in
                secondCallbackValue = value
                secondSignal.signal()
            }
        )
        #expect(secondID != nil, "the second metadata observer must join the shared request")
        if let firstID { coordinator.cancel(firstID) }
        sharedGate.finish(loadedMetadata)
        await secondSignal.wait(for: 1)
        #expect(loadCount.read() == 1, "observers for one metadata group must share one loader")
        #expect(firstSignal.value == 0, "a cancelled metadata observer must not receive a callback")
        #expect(secondCallbackValue == loadedMetadata, "the remaining metadata observer must receive the shared result")
        #expect(firstCallbackValue == nil, "the cancelled metadata observer must remain untouched")

        // cancelAll removes queued work, while quiesce rejects new work until
        // the current read has been allowed to finish.
        coordinator.cancelAll()
        let cancelled = makeLoadingGroup(root: root, id: "metadata-cancelled", path: "cancelled.JPG")
        let cancelledGate = LoadingGate<PhotoMetadata?>()
        var cancelledCallback = false
        coordinator.suspendBackgroundReads()
        _ = coordinator.enqueue(
            group: cancelled,
            priority: .background,
            loader: { _ in await cancelledGate.run() },
            onMetadata: { _ in cancelledCallback = true }
        )
        coordinator.cancelAll()
        coordinator.resumeBackgroundReads()
        #expect(!cancelledGate.hasStarted, "cancelAll must remove queued metadata work")
        #expect(!cancelledCallback, "cancelAll must not call a removed metadata observer")

        let quiesceGroup = makeLoadingGroup(root: root, id: "metadata-quiesce", path: "quiesce.JPG")
        let quiesceGate = LoadingGate<PhotoMetadata?>()
        let quiesceSignal = TestSignal()
        _ = coordinator.enqueue(
            group: quiesceGroup,
            priority: .visible,
            loader: { _ in await quiesceGate.run() },
            onMetadata: { _ in quiesceSignal.signal() }
        )
        await quiesceGate.waitUntilStarted()
        let quiesceTask = Task { @MainActor in
            await coordinator.quiesce()
        }
        await Task.yield()
        let rejectedDuringQuiesce = coordinator.enqueue(
            group: makeLoadingGroup(root: root, id: "metadata-rejected", path: "rejected.JPG"),
            priority: .visible,
            onMetadata: { _ in }
        )
        #expect(rejectedDuringQuiesce == nil, "metadata enqueue must be rejected during quiesce")
        quiesceGate.finish(loadedMetadata)
        await quiesceTask.value
        #expect(quiesceSignal.value == 0, "quiesce must discard the completion of the stopped read")

        coordinator.resumeAfterQuiesce()
        let resumedGroup = makeLoadingGroup(root: root, id: "metadata-resumed", path: "resumed.JPG")
        let resumedGate = LoadingGate<PhotoMetadata?>()
        let resumedSignal = TestSignal()
        _ = coordinator.enqueue(
            group: resumedGroup,
            priority: .visible,
            loader: { _ in await resumedGate.run() },
            onMetadata: { _ in resumedSignal.signal() }
        )
        await resumedGate.waitUntilStarted()
        resumedGate.finish(loadedMetadata)
        await resumedSignal.wait(for: 1)
    }

    static func runThumbnailCacheTests() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-loading-cache-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("cache.JPG")
        guard let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="),
              let image = NSImage(data: data) else {
            throw NSError(domain: "PhotokichinTests", code: 51, userInfo: [NSLocalizedDescriptionKey: "could not construct the cache test image"])
        }
        let small = NSImage(data: data)!
        let large = NSImage(data: data)!
        let cache = ThumbnailCache()
        cache.store(small, for: url, maxPixel: 100)
        cache.store(large, for: url, maxPixel: 300)
        #expect(cache.image(for: url, maxPixel: 100) === small, "thumbnail cache must return the exact requested size")
        #expect(cache.bestImage(for: url, maxPixel: 250) === small, "bestImage must choose the largest cached image not exceeding the requested size")
        #expect(cache.bestImage(for: url, maxPixel: 400) === large, "bestImage must choose the largest available cached image")
        #expect(image.size.width > 0 && image.size.height > 0, "the cache fixture must decode as an image")
    }

    static func runThumbnailLoadingCoordinatorTests() async throws {
        let cache = ThumbnailCache()
        let dataLoader = ThumbnailDataLoaderRouter()
        let coordinator = ThumbnailLoadingCoordinator(
            cache: cache,
            dataLoader: { url, maxPixel in
                await dataLoader.load(url: url, maxPixel: maxPixel)
            }
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-loading-thumbnail-\(UUID().uuidString)", isDirectory: true)
        coordinator.beginSource(rootURL: root)

        guard let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=") else {
            throw NSError(domain: "PhotokichinTests", code: 52, userInfo: [NSLocalizedDescriptionKey: "could not construct the thumbnail test data"])
        }

        let groupA = makeLoadingGroup(root: root, id: "thumbnail-a", path: "A.JPG")
        let groupB = makeLoadingGroup(root: root, id: "thumbnail-b", path: "B.JPG")
        let groupC = makeLoadingGroup(root: root, id: "thumbnail-c", path: "C.JPG")
        let gateA = LoadingGate<Data?>()
        let gateB = LoadingGate<Data?>()
        let gateC = LoadingGate<Data?>()
        let starts = LockedValue<[String]>([])
        let signalA = TestSignal()
        let signalB = TestSignal()
        let signalC = TestSignal()

        dataLoader.setLoader { url, _ in
            starts.update { $0.append(url.lastPathComponent) }
            if url == groupA.primaryURL { return await gateA.run() }
            if url == groupB.primaryURL { return await gateB.run() }
            if url == groupC.primaryURL { return await gateC.run() }
            return nil
        }
        defer {
            coordinator.cancelAll()
        }

        let firstID = coordinator.subscribe(group: groupA, maxPixel: 100, priority: .visible) { image in
            if image != nil { signalA.signal() }
        }
        #expect(firstID != nil, "the first thumbnail observer must be registered")
        await gateA.waitUntilStarted()

        _ = coordinator.subscribe(group: groupB, maxPixel: 100, priority: .prefetch) { image in
            if image != nil { signalB.signal() }
        }
        _ = coordinator.subscribe(group: groupC, maxPixel: 100, priority: .viewerCurrent) { image in
            if image != nil { signalC.signal() }
        }
        gateA.finish(imageData)
        await signalA.wait(for: 1)
        await gateC.waitUntilStarted()
        #expect(starts.read() == ["A.JPG", "C.JPG"], "viewer thumbnail requests must outrank prefetch requests")
        gateC.finish(imageData)
        await signalC.wait(for: 1)
        await gateB.waitUntilStarted()
        gateB.finish(imageData)
        await signalB.wait(for: 1)

        // A second observer joins the same URL and size. Cancelling one
        // observer must leave the shared request and the other callback alive.
        coordinator.cancelAll()
        let sharedGroup = makeLoadingGroup(root: root, id: "thumbnail-shared", path: "shared.JPG")
        let sharedGate = LoadingGate<Data?>()
        let sharedLoads = LockedValue(0)
        let sharedFirstSignal = TestSignal()
        let sharedSecondSignal = TestSignal()
        var sharedFirstImage = false
        var sharedSecondImage = false
        dataLoader.setLoader { url, _ in
            if url == sharedGroup.primaryURL {
                sharedLoads.update { $0 += 1 }
                let value = await sharedGate.run()
                return Task.isCancelled ? nil : value
            }
            return imageData
        }
        let sharedFirstID = coordinator.subscribe(group: sharedGroup, maxPixel: 120, priority: .visible) { image in
            sharedFirstImage = image != nil
            sharedFirstSignal.signal()
        }
        #expect(sharedFirstID != nil, "the first shared thumbnail observer must be registered")
        await sharedGate.waitUntilStarted()
        let sharedSecondID = coordinator.subscribe(group: sharedGroup, maxPixel: 120, priority: .viewerNeighbor) { image in
            sharedSecondImage = image != nil
            sharedSecondSignal.signal()
        }
        #expect(sharedSecondID != nil, "the second shared thumbnail observer must be registered")
        if let sharedFirstID { coordinator.cancel(sharedFirstID) }
        sharedGate.finish(imageData)
        await sharedSecondSignal.wait(for: 1)
        #expect(sharedLoads.read() == 1, "same URL and size thumbnail observers must share one load")
        #expect(!sharedFirstImage && sharedFirstSignal.value == 0, "a cancelled thumbnail observer must not receive a callback")
        #expect(sharedSecondImage, "the remaining thumbnail observer must receive the shared image")

        coordinator.cancelAll()
        coordinator.beginSource(rootURL: root)
        let currentSourceGroup = makeLoadingGroup(root: root, id: "thumbnail-current-source", path: "current-source.JPG")
        let currentSourceResult = coordinator.subscribe(group: currentSourceGroup, maxPixel: 120, priority: .visible) { _ in }
        #expect(currentSourceResult != nil, "the current source must accept its own thumbnail URL")
        coordinator.cancelAll()
        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        coordinator.beginSource(rootURL: otherRoot)
        let oldSourceSignal = TestSignal()
        let rejectedOldSource = coordinator.subscribe(group: currentSourceGroup, maxPixel: 120, priority: .visible) { _ in
            oldSourceSignal.signal()
        }
        #expect(rejectedOldSource == nil, "beginSource must reject requests for the previous source")
        #expect(oldSourceSignal.value == 0, "an old-source thumbnail must not call its observer")

        let workingA = makeLoadingGroup(root: otherRoot, id: "thumbnail-working-a", path: "working-a.JPG")
        let workingB = makeLoadingGroup(root: otherRoot, id: "thumbnail-working-b", path: "working-b.JPG")
        let workingGateA = LoadingGate<Data?>()
        let workingGateB = LoadingGate<Data?>()
        let workingReady = LockedValue<[String]>([])
        let workingSignal = TestSignal()
        dataLoader.setLoader { url, _ in
            if url == workingA.primaryURL { return await workingGateA.run() }
            if url == workingB.primaryURL { return await workingGateB.run() }
            return imageData
        }
        coordinator.updateListWorkingSet(groups: [(workingA, .visible)], maxPixel: 140) { id, _ in
            workingReady.update { $0.append(id) }
            workingSignal.signal()
        }
        await workingGateA.waitUntilStarted()
        workingGateA.finish(imageData)
        await workingSignal.wait(for: 1)
        coordinator.updateListWorkingSet(groups: [(workingB, .visible)], maxPixel: 140) { id, _ in
            workingReady.update { $0.append(id) }
            workingSignal.signal()
        }
        await workingGateB.waitUntilStarted()
        workingGateB.finish(imageData)
        await workingSignal.wait(for: 2)
        #expect(workingReady.read() == [workingA.id, workingB.id], "working set updates must remove obsolete thumbnails and deliver the new set")

        // cancelAll removes queued requests. The active request is released by
        // the explicit gate completion, so the test never relies on timing.
        coordinator.cancelAll()
        let cancelA = makeLoadingGroup(root: otherRoot, id: "thumbnail-cancel-a", path: "cancel-a.JPG")
        let cancelB = makeLoadingGroup(root: otherRoot, id: "thumbnail-cancel-b", path: "cancel-b.JPG")
        let cancelGateA = LoadingGate<Data?>()
        let cancelGateB = LoadingGate<Data?>()
        dataLoader.setLoader { url, _ in
            if url == cancelA.primaryURL { return await cancelGateA.run() }
            if url == cancelB.primaryURL { return await cancelGateB.run() }
            return imageData
        }
        _ = coordinator.subscribe(group: cancelA, maxPixel: 160, priority: .visible) { _ in }
        await cancelGateA.waitUntilStarted()
        _ = coordinator.subscribe(group: cancelB, maxPixel: 160, priority: .prefetch) { _ in }
        coordinator.cancelAll()
        cancelGateA.finish(imageData)
        await Task.yield()
        #expect(!cancelGateB.hasStarted, "cancelAll must remove queued thumbnail requests")

        let quiesceGroup = makeLoadingGroup(root: otherRoot, id: "thumbnail-quiesce", path: "thumbnail-quiesce.JPG")
        let quiesceGate = LoadingGate<Data?>()
        dataLoader.setLoader { url, _ in
            if url == quiesceGroup.primaryURL { return await quiesceGate.run() }
            return imageData
        }
        _ = coordinator.subscribe(group: quiesceGroup, maxPixel: 180, priority: .visible) { _ in }
        await quiesceGate.waitUntilStarted()
        let quiesceTask = Task { @MainActor in
            await coordinator.quiesce()
        }
        await Task.yield()
        let rejected = coordinator.subscribe(group: makeLoadingGroup(root: otherRoot, id: "thumbnail-rejected", path: "rejected.JPG"), maxPixel: 180, priority: .visible) { _ in }
        #expect(rejected == nil, "thumbnail subscribe must be rejected during quiesce")
        quiesceGate.finish(imageData)
        await quiesceTask.value
        coordinator.resumeAfterQuiesce()
        let resumed = makeLoadingGroup(root: otherRoot, id: "thumbnail-resumed", path: "resumed.JPG")
        let resumedGate = LoadingGate<Data?>()
        let resumedSignal = TestSignal()
        dataLoader.setLoader { url, _ in
            if url == resumed.primaryURL { return await resumedGate.run() }
            return imageData
        }
        _ = coordinator.subscribe(group: resumed, maxPixel: 180, priority: .visible) { image in
            if image != nil { resumedSignal.signal() }
        }
        await resumedGate.waitUntilStarted()
        resumedGate.finish(imageData)
        await resumedSignal.wait(for: 1)
    }

    private static func makeLoadingGroup(
        root: URL,
        id: String,
        path: String?,
        isMetadataLoaded: Bool = false,
        metadata: PhotoMetadata = .empty
    ) -> PhotoGroup {
        PhotoGroup(
            id: id,
            basename: path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? id,
            directory: root,
            jpegURL: path.map { root.appendingPathComponent($0) },
            rawURL: nil,
            movieURL: nil,
            captureDate: nil,
            metadata: metadata,
            importedJPEG: false,
            importedRAW: false,
            isMetadataLoaded: isMetadataLoaded
        )
    }
}
