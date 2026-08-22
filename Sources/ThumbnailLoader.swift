import AppKit
import Foundation
import SwiftUI

enum ThumbnailRequestPriority: Int, Sendable {
    case viewerCurrent = 0
    case viewerNeighbor = 1
    case visible = 10
    case prefetch = 20
}

private struct ThumbnailKey: Hashable, Sendable {
    let path: String
    let maxPixel: Int
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, NSImage>()
    private var cachedPixelSizes: [String: Set<Int>] = [:]

    func image(for url: URL, maxPixel: Int) -> NSImage? {
        memory.object(forKey: cacheKey(url: url, maxPixel: maxPixel) as NSString)
    }

    /// Returns a previously decoded image that can be shown immediately while
    /// a larger version is being prepared for the viewer.
    func bestImage(for url: URL, maxPixel: Int) -> NSImage? {
        guard let sizes = cachedPixelSizes[url.path], !sizes.isEmpty else { return nil }
        let candidate = sizes.filter { $0 <= maxPixel }.max() ?? sizes.min()
        guard let candidate else { return nil }
        return image(for: url, maxPixel: candidate)
    }

    func store(_ image: NSImage, for url: URL, maxPixel: Int) {
        memory.setObject(image, forKey: cacheKey(url: url, maxPixel: maxPixel) as NSString)
        cachedPixelSizes[url.path, default: []].insert(maxPixel)
    }

    private func cacheKey(url: URL, maxPixel: Int) -> String {
        url.path + ":" + String(maxPixel)
    }
}

@MainActor
final class ThumbnailLoadingCoordinator {
    static let shared = ThumbnailLoadingCoordinator()

#if PHOTOKICHIN_TESTING
    /// Replaces ImageIO only in the deterministic test binary. The release
    /// build keeps the detached ImageIO read and its normal performance path.
    static var testDataLoader: (@Sendable (URL, Int) async -> Data?)?
#endif

    private final class Request {
        let id = UUID()
        let key: ThumbnailKey
        let url: URL
        var priority: ThumbnailRequestPriority
        var sequence: UInt64
        var observers: [UUID: (NSImage?) -> Void] = [:]
        var task: Task<Data?, Never>?

        init(key: ThumbnailKey, url: URL, priority: ThumbnailRequestPriority, sequence: UInt64) {
            self.key = key
            self.url = url
            self.priority = priority
            self.sequence = sequence
        }
    }

    private struct Observation {
        let key: ThumbnailKey
        let requestID: UUID
    }

    // ImageIO parallelizes one JPEG decode internally. Running a second
    // request concurrently keeps the process around 130-150% CPU while a
    // library opens and delays AppKit input. One coordinator request at a
    // time still uses ImageIO's internal parallelism, while the priority queue
    // keeps the currently visible rows ahead of both prefetch viewports.
    private let maxConcurrentLoads = 1
    private var nextSequence: UInt64 = 0
    private var queued: [Request] = []
    private var queueNeedsSort = false
    private var active: [ThumbnailKey: Request] = [:]
    private var observations: [UUID: Observation] = [:]
    private var viewerPrefetchIDs: Set<UUID> = []
    private var listWorkingSetIDs: [ThumbnailKey: (id: UUID, priority: ThumbnailRequestPriority)] = [:]
    private var activeSourceRootPath: String?
    private var quiescing = false

    @discardableResult
    func subscribe(
        group: PhotoGroup,
        maxPixel: Int,
        priority: ThumbnailRequestPriority,
        onImage: @escaping (NSImage?) -> Void
    ) -> UUID? {
        guard !quiescing else {
            return nil
        }
        guard let url = group.primaryURL else {
            onImage(nil)
            return nil
        }
        guard belongsToActiveSource(url) else {
            return nil
        }

        let key = ThumbnailKey(path: url.path, maxPixel: maxPixel)
        let observationID = UUID()
        if let image = ThumbnailCache.shared.image(for: url, maxPixel: maxPixel) {
            onImage(image)
            return nil
        }

        nextSequence &+= 1
        if let request = active[key] {
            request.observers[observationID] = onImage
            promote(request, priority: priority)
        } else if let request = queued.first(where: { $0.key == key }) {
            request.observers[observationID] = onImage
            promote(request, priority: priority)
            queueNeedsSort = true
        } else {
            let request = Request(key: key, url: url, priority: priority, sequence: nextSequence)
            request.observers[observationID] = onImage
            queued.append(request)
            queueNeedsSort = true
        }

        observations[observationID] = Observation(key: key, requestID: requestID(for: key, observationID: observationID))
        pump()
        return observationID
    }

    /// Queues the current viewer's adjacent photos without making them block
    /// the current image. The next call replaces the previous neighbor set.
    func updateViewerPrefetch(groups: [PhotoGroup], maxPixel: Int) {
        for id in viewerPrefetchIDs {
            cancel(id)
        }
        viewerPrefetchIDs.removeAll()

        for group in groups {
            if let id = subscribe(group: group, maxPixel: maxPixel, priority: .viewerNeighbor, onImage: { _ in }) {
                viewerPrefetchIDs.insert(id)
            }
        }
    }

    func clearViewerPrefetch() {
        for id in viewerPrefetchIDs {
            cancel(id)
        }
        viewerPrefetchIDs.removeAll()
    }

    /// Replaces the list's three-viewport thumbnail working set. Requests are
    /// registered directly with the coordinator, so rows one screen outside
    /// the viewport are prepared even if SwiftUI has not instantiated their
    /// tile views yet. A tile subscription joins the same keyed request.
    func updateListWorkingSet(
        groups: [(PhotoGroup, ThumbnailRequestPriority)],
        maxPixel: Int,
        onThumbnailReady: @escaping (String, ThumbnailRequestPriority) -> Void
    ) {
        let desired: [(ThumbnailKey, PhotoGroup, ThumbnailRequestPriority)] = groups.compactMap { group, priority in
            guard let url = group.primaryURL, belongsToActiveSource(url) else { return nil }
            return (ThumbnailKey(path: url.path, maxPixel: maxPixel), group, priority)
        }
        // A disappearing source view may publish one last visibility update
        // after the new source has started. Ignore it instead of replacing
        // the new source's working set with an empty one.
        guard groups.isEmpty || !desired.isEmpty else { return }
        let desiredKeys = Set(desired.map(\.0))

        let obsoleteKeys = listWorkingSetIDs.keys.filter { !desiredKeys.contains($0) }
        for key in obsoleteKeys {
            guard let observation = listWorkingSetIDs.removeValue(forKey: key) else { continue }
            cancel(observation.id)
        }

        for (key, group, priority) in desired {
            if let existing = listWorkingSetIDs[key], existing.priority != priority {
                cancel(existing.id)
                listWorkingSetIDs.removeValue(forKey: key)
            }
            guard listWorkingSetIDs[key] == nil else { continue }

            let observationID = subscribe(
                group: group,
                maxPixel: maxPixel,
                priority: priority
            ) { _ in
                onThumbnailReady(group.id, priority)
            }
            if let observationID {
                listWorkingSetIDs[key] = (observationID, priority)
            }
        }
    }

    func cancelAll() {
        quiescing = false
        for observationID in Array(observations.keys) {
            cancel(observationID)
        }
        viewerPrefetchIDs.removeAll()
        listWorkingSetIDs.removeAll()
        queueNeedsSort = false
    }

    /// Stops accepting new thumbnail reads and waits for every synchronous
    /// Data/ImageIO read already in progress to return. Cancellation alone is
    /// not enough for a removable volume because the detached read may keep a
    /// file descriptor open until Data(contentsOf:) finishes.
    func quiesce() async {
        quiescing = true
        let tasks = active.values.compactMap { $0.task }
        for request in queued { request.task?.cancel() }
        for request in active.values {
            request.task?.cancel()
        }

        for task in tasks {
            _ = await task.value
        }

        queued.removeAll()
        active.removeAll()
        observations.removeAll()
        viewerPrefetchIDs.removeAll()
        listWorkingSetIDs.removeAll()
        queueNeedsSort = false
    }

    func resumeAfterQuiesce() {
        quiescing = false
        queueNeedsSort = true
        pump()
    }

    func beginSource(rootURL: URL) {
        activeSourceRootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        quiescing = false
        queueNeedsSort = true
        pump()
    }

    private func belongsToActiveSource(_ url: URL) -> Bool {
        guard let activeSourceRootPath else { return true }
        return url.path.hasPrefix(activeSourceRootPath)
    }

    func cancel(_ observationID: UUID) {
        guard let observation = observations.removeValue(forKey: observationID) else { return }

        if let request = active[observation.key], request.id == observation.requestID {
            request.observers.removeValue(forKey: observationID)
            if request.observers.isEmpty {
                request.task?.cancel()
            }
        } else if let index = queued.firstIndex(where: { $0.id == observation.requestID }) {
            let request = queued[index]
            request.observers.removeValue(forKey: observationID)
            if request.observers.isEmpty {
                queued.remove(at: index)
            }
        }
        pump()
    }

    private func promote(_ request: Request, priority: ThumbnailRequestPriority) {
        if priority.rawValue < request.priority.rawValue {
            request.priority = priority
        }
        nextSequence &+= 1
        request.sequence = nextSequence
    }

    private func requestID(for key: ThumbnailKey, observationID: UUID) -> UUID {
        if let activeRequest = active[key], activeRequest.observers[observationID] != nil {
            return activeRequest.id
        }
        if let queuedRequest = queued.first(where: { $0.key == key && $0.observers[observationID] != nil }) {
            return queuedRequest.id
        }
        // This is only reachable for an exact cache hit, which is returned
        // before an observation is registered.
        return UUID()
    }

    private func pump() {
        while active.count < maxConcurrentLoads, !queued.isEmpty {
            if queueNeedsSort {
                queued.sort {
                    if $0.priority.rawValue != $1.priority.rawValue {
                        // Keep the highest-priority request at the end so
                        // dequeuing never shifts the whole Array on the main
                        // actor while the user is scrolling quickly.
                        return $0.priority.rawValue > $1.priority.rawValue
                    }
                    return $0.sequence < $1.sequence
                }
                queueNeedsSort = false
            }
            let request = queued.removeLast()
            guard !request.observers.isEmpty else { continue }
            active[request.key] = request

#if PHOTOKICHIN_TESTING
            let testDataLoader = Self.testDataLoader
            let task = Task.detached(priority: .utility) {
                if let testDataLoader {
                    return await testDataLoader(request.url, request.key.maxPixel)
                }
                return ImageIOReader.thumbnailData(url: request.url, maxPixel: request.key.maxPixel)
            }
#else
            let task = Task.detached(priority: .utility) {
                ImageIOReader.thumbnailData(url: request.url, maxPixel: request.key.maxPixel)
            }
#endif
            request.task = task
            let requestID = request.id
            let key = request.key
            Task { [weak self] in
                let data = await task.value
                guard let self else { return }
                self.finish(requestID: requestID, key: key, data: data)
            }
        }
    }

    private func finish(requestID: UUID, key: ThumbnailKey, data: Data?) {
        guard let request = active[key], request.id == requestID else { return }
        active.removeValue(forKey: key)

        if quiescing {
            for observationID in request.observers.keys {
                observations.removeValue(forKey: observationID)
            }
            return
        }

        for observationID in request.observers.keys {
            observations.removeValue(forKey: observationID)
        }

        var image: NSImage?
        if let data, let decoded = NSImage(data: data) {
            image = decoded
            ThumbnailCache.shared.store(decoded, for: request.url, maxPixel: request.key.maxPixel)
        }
        let callbacks = Array(request.observers.values)
        for callback in callbacks {
            callback(image)
        }
        pump()
    }
}

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var isLoading = false

    private var observationID: UUID?
    private var cameraObservationID: UUID?
    private var loadedKey: String?

    func load(
        for group: PhotoGroup,
        maxPixel: Int,
        priority: ThumbnailRequestPriority = .visible,
        onFinished: @escaping () -> Void = {}
    ) {
        if group.isCameraBacked {
            let key = "camera:\(group.id):\(maxPixel)"
            if loadedKey == key {
                if !isLoading { onFinished() }
                return
            }

            cancel()
            loadedKey = key
            image = nil
            isLoading = true
            cameraObservationID = CameraThumbnailCoordinator.shared.subscribe(
                group: group,
                maxPixel: maxPixel,
                priority: priority
            ) { [weak self] image in
                guard let self else { return }
                if let image { self.image = image }
                self.isLoading = false
                self.cameraObservationID = nil
                onFinished()
            }
            if cameraObservationID == nil {
                isLoading = false
                onFinished()
            }
            return
        }

        guard let url = group.primaryURL else { return }
        let key = url.path + ":" + String(maxPixel)
        if loadedKey == key {
            if !isLoading { onFinished() }
            return
        }

        cancel()
        loadedKey = key
        let exactImage = ThumbnailCache.shared.image(for: url, maxPixel: maxPixel)
        image = exactImage ?? ThumbnailCache.shared.bestImage(for: url, maxPixel: maxPixel)
        isLoading = exactImage == nil

        if exactImage != nil {
            onFinished()
            return
        }

        observationID = ThumbnailLoadingCoordinator.shared.subscribe(
            group: group,
            maxPixel: maxPixel,
            priority: priority
        ) { [weak self] image in
            guard let self else { return }
            if let image {
                self.image = image
            }
            self.isLoading = false
            self.observationID = nil
            onFinished()
        }
        if observationID == nil {
            isLoading = false
            onFinished()
        }
    }

    func cancel() {
        if let observationID {
            ThumbnailLoadingCoordinator.shared.cancel(observationID)
        }
        if let cameraObservationID {
            CameraThumbnailCoordinator.shared.cancel(cameraObservationID)
        }
        observationID = nil
        cameraObservationID = nil
        loadedKey = nil
        isLoading = false
    }
}
