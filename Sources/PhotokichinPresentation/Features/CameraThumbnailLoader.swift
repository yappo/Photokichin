import AppKit
import Foundation
import PhotokichinApplication
import PhotokichinDomain

@MainActor
final class CameraThumbnailCoordinator {
    private struct Key: Hashable {
        let cameraID: String
        let assetIdentifier: String
        let maxPixel: Int
    }

    private final class Request {
        let id = UUID()
        let key: Key
        let group: PhotoGroup
        var priority: ThumbnailRequestPriority
        var sequence: UInt64
        var observers: [UUID: (NSImage?) -> Void] = [:]
        var task: Task<Data?, Never>?

        init(key: Key, group: PhotoGroup, priority: ThumbnailRequestPriority, sequence: UInt64) {
            self.key = key
            self.group = group
            self.priority = priority
            self.sequence = sequence
        }
    }

    private struct Observation {
        let key: Key
        let requestID: UUID
    }

    private let cameraMonitor: any CameraMonitoring
    private let maxConcurrentLoads = 1
    private var nextSequence: UInt64 = 0
    private var cache: [Key: NSImage] = [:]
    private var queued: [Request] = []
    private var active: [Key: Request] = [:]
    private var observations: [UUID: Observation] = [:]
    private var viewerPrefetchIDs: Set<UUID> = []
    private var listWorkingSetIDs: [Key: (id: UUID, priority: ThumbnailRequestPriority)] = [:]

    init(cameraMonitor: any CameraMonitoring) {
        self.cameraMonitor = cameraMonitor
    }

    @discardableResult
    func subscribe(
        group: PhotoGroup,
        maxPixel: Int,
        priority: ThumbnailRequestPriority,
        onImage: @escaping (NSImage?) -> Void
    ) -> UUID? {
        guard let reference = group.cameraReference,
              let asset = reference.asset(for: .renderedImage) ?? reference.asset(for: .raw) else {
            onImage(nil)
            return nil
        }

        let key = Key(cameraID: reference.cameraID, assetIdentifier: asset.identifier, maxPixel: maxPixel)
        if let image = cache[key] {
            onImage(image)
            return nil
        }

        nextSequence &+= 1
        let observationID = UUID()
        if let request = active[key] {
            request.observers[observationID] = onImage
            promote(request, priority: priority)
        } else if let request = queued.first(where: { $0.key == key }) {
            request.observers[observationID] = onImage
            promote(request, priority: priority)
        } else {
            let request = Request(key: key, group: group, priority: priority, sequence: nextSequence)
            request.observers[observationID] = onImage
            queued.append(request)
        }
        let requestID = active[key]?.id ?? queued.first(where: { $0.key == key })?.id ?? UUID()
        observations[observationID] = Observation(key: key, requestID: requestID)
        pump()
        return observationID
    }

    func cancel(_ observationID: UUID) {
        guard let observation = observations.removeValue(forKey: observationID) else { return }
        if let request = active[observation.key], request.id == observation.requestID {
            request.observers.removeValue(forKey: observationID)
            if request.observers.isEmpty { request.task?.cancel() }
        } else if let index = queued.firstIndex(where: { $0.id == observation.requestID }) {
            let request = queued[index]
            request.observers.removeValue(forKey: observationID)
            if request.observers.isEmpty { queued.remove(at: index) }
        }
        pump()
    }

    func cancelAll() {
        for request in active.values {
            request.observers.removeAll()
            request.task?.cancel()
        }
        queued.removeAll()
        observations.removeAll()
        viewerPrefetchIDs.removeAll()
        listWorkingSetIDs.removeAll()
    }

    func updateViewerPrefetch(groups: [PhotoGroup], maxPixel: Int) {
        clearViewerPrefetch()
        for group in groups {
            if let observationID = subscribe(
                group: group,
                maxPixel: maxPixel,
                priority: .viewerNeighbor,
                onImage: { _ in }
            ) {
                viewerPrefetchIDs.insert(observationID)
            }
        }
    }

    func clearViewerPrefetch() {
        for observationID in viewerPrefetchIDs { cancel(observationID) }
        viewerPrefetchIDs.removeAll()
    }

    func updateListWorkingSet(
        groups: [(PhotoGroup, ThumbnailRequestPriority)],
        maxPixel: Int,
        onThumbnailReady: @escaping (String, ThumbnailRequestPriority) -> Void
    ) {
        let desired: [(Key, PhotoGroup, ThumbnailRequestPriority)] = groups.compactMap { group, priority in
            guard let reference = group.cameraReference,
                  let asset = reference.asset(for: .renderedImage) ?? reference.asset(for: .raw) else { return nil }
            return (
                Key(cameraID: reference.cameraID, assetIdentifier: asset.identifier, maxPixel: maxPixel),
                group,
                priority
            )
        }
        let desiredKeys = Set(desired.map(\.0))
        for key in listWorkingSetIDs.keys.filter({ !desiredKeys.contains($0) }) {
            if let observation = listWorkingSetIDs.removeValue(forKey: key) { cancel(observation.id) }
        }
        for (key, group, priority) in desired {
            if let existing = listWorkingSetIDs[key], existing.priority != priority {
                cancel(existing.id)
                listWorkingSetIDs.removeValue(forKey: key)
            }
            guard listWorkingSetIDs[key] == nil else { continue }
            if let observationID = subscribe(
                group: group,
                maxPixel: maxPixel,
                priority: priority,
                onImage: { _ in onThumbnailReady(group.id, priority) }
            ) {
                listWorkingSetIDs[key] = (observationID, priority)
            }
        }
    }

    func removeCamera(id: String) {
        for key in cache.keys.filter({ $0.cameraID == id }) { cache.removeValue(forKey: key) }
        for request in active.values where request.key.cameraID == id {
            request.observers.removeAll()
            request.task?.cancel()
        }
        for key in queued.filter({ $0.key.cameraID == id }).map(\.key) {
            guard let index = queued.firstIndex(where: { $0.key == key }) else { continue }
            let request = queued.remove(at: index)
            for observationID in request.observers.keys { observations.removeValue(forKey: observationID) }
        }
        for key in listWorkingSetIDs.keys.filter({ $0.cameraID == id }) {
            if let observation = listWorkingSetIDs.removeValue(forKey: key) { cancel(observation.id) }
        }
    }

    private func promote(_ request: Request, priority: ThumbnailRequestPriority) {
        if priority.rawValue < request.priority.rawValue { request.priority = priority }
        nextSequence &+= 1
        request.sequence = nextSequence
    }

    private func pump() {
        while active.count < maxConcurrentLoads, !queued.isEmpty {
            queued.sort {
                if $0.priority.rawValue != $1.priority.rawValue {
                    return $0.priority.rawValue > $1.priority.rawValue
                }
                return $0.sequence < $1.sequence
            }
            let request = queued.removeLast()
            guard !request.observers.isEmpty else { continue }
            active[request.key] = request
            let requestID = request.id
            let key = request.key
            let group = request.group
            let cameraMonitor = self.cameraMonitor
            let task = Task { await cameraMonitor.requestThumbnailData(for: group, maxPixel: key.maxPixel) }
            request.task = task
            Task { [weak self] in
                let data = await task.value
                self?.finish(requestID: requestID, key: key, data: data)
            }
        }
    }

    private func finish(requestID: UUID, key: Key, data: Data?) {
        guard let request = active[key], request.id == requestID else { return }
        active.removeValue(forKey: key)
        for observationID in request.observers.keys { observations.removeValue(forKey: observationID) }
        let image = data.flatMap(NSImage.init(data:))
        if let image { cache[key] = image }
        let callbacks = Array(request.observers.values)
        for callback in callbacks { callback(image) }
        pump()
    }
}

@MainActor
package final class ThumbnailServices {
    let cache: ThumbnailCache
    let file: ThumbnailLoadingCoordinator
    let camera: CameraThumbnailCoordinator

    package init(mediaReader: any MediaReading, cameraMonitor: any CameraMonitoring) {
        let cache = ThumbnailCache()
        self.cache = cache
        file = ThumbnailLoadingCoordinator(
            cache: cache,
            dataLoader: { url, maxPixel in
                mediaReader.thumbnailData(url: url, maxPixel: maxPixel)
            }
        )
        camera = CameraThumbnailCoordinator(cameraMonitor: cameraMonitor)
    }
}
