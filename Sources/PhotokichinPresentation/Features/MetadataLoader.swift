import Foundation
import PhotokichinApplication
import PhotokichinDomain

/// Schedules metadata reads in the same visibility-driven way as thumbnails.
/// The initial scan queues every group at background priority, while visible
/// tiles and the viewer promote their groups without creating duplicate reads.
@MainActor
final class MetadataLoadingCoordinator {
    private let mediaReader: any MediaReading

    private final class Request {
        let id = UUID()
        let group: PhotoGroup
        let loader: @Sendable (TaskPriority) async -> PhotoMetadata?
        var priority: MetadataRequestPriority
        var sequence: UInt64
        var observers: [UUID: (PhotoMetadata?) -> Void] = [:]
        var task: Task<PhotoMetadata?, Never>?

        init(group: PhotoGroup, priority: MetadataRequestPriority, sequence: UInt64, loader: @escaping @Sendable (TaskPriority) async -> PhotoMetadata?) {
            self.group = group
            self.loader = loader
            self.priority = priority
            self.sequence = sequence
        }
    }

    private struct Observation {
        let groupID: String
        let requestID: UUID
    }

    private let maxConcurrentForegroundReads = 2
    private let maxConcurrentBackgroundReads = 1
    private var nextSequence: UInt64 = 0
    private var queued: [Request] = []
    private var queuedByGroupID: [String: Request] = [:]
    private var queueNeedsSort = false
    private var active: [String: Request] = [:]
    private var observations: [UUID: Observation] = [:]
    private var requestedPriorities: [String: MetadataRequestPriority] = [:]
    private var backgroundSuspended = false
    private var quiescing = false

    init(mediaReader: any MediaReading) {
        self.mediaReader = mediaReader
    }

    /// Queue the complete scan without starting low-priority reads yet. This
    /// gives the first visible tiles a chance to promote their requests.
    func suspendBackgroundReads() {
        backgroundSuspended = true
    }

    func resumeBackgroundReads() {
        backgroundSuspended = false
        queueNeedsSort = true
        pump()
    }

    @discardableResult
    func enqueue(
        group: PhotoGroup,
        priority: MetadataRequestPriority,
        loader: (@Sendable (TaskPriority) async -> PhotoMetadata?)? = nil,
        onMetadata: @escaping (PhotoMetadata?) -> Void
    ) -> UUID? {
        guard !quiescing else { return nil }
        if group.isMetadataLoaded {
            onMetadata(group.metadata)
            return nil
        }

        guard loader != nil || group.primaryURL != nil else {
            onMetadata(nil)
            return nil
        }

        let mediaReader = self.mediaReader
        let metadataLoader: @Sendable (TaskPriority) async -> PhotoMetadata? = loader ?? { taskPriority in
            let urls = [group.renderedImageURL, group.rawURL].compactMap { $0 }
            return await Task.detached(priority: taskPriority) {
                urls.lazy.compactMap { mediaReader.readMetadata(url: $0) }.first
            }.value
        }

        let observationID = UUID()
        nextSequence &+= 1
        let requestedPriority = requestedPriorities.removeValue(forKey: group.id)
        let effectivePriority = [priority, requestedPriority]
            .compactMap { $0 }
            .min { $0.rawValue < $1.rawValue } ?? priority

        let request: Request
        if let activeRequest = active[group.id] {
            request = activeRequest
            promote(request, priority: effectivePriority)
        } else if let queuedRequest = queuedByGroupID[group.id] {
            request = queuedRequest
            promote(request, priority: effectivePriority)
            queueNeedsSort = true
        } else {
            request = Request(group: group, priority: effectivePriority, sequence: nextSequence, loader: metadataLoader)
            queued.append(request)
            queuedByGroupID[group.id] = request
            queueNeedsSort = true
        }

        request.observers[observationID] = onMetadata
        observations[observationID] = Observation(groupID: group.id, requestID: request.id)
        // During the initial card scan all requests are intentionally queued
        // at background priority. Do not sort the entire queue once per
        // photo; a 3,456-group card would otherwise make registration itself
        // an O(n²) main-actor operation and stall AppKit input.
        if !(backgroundSuspended && priority == .background) {
            pump()
        }
        return observationID
    }

    /// Promotes an already queued read. This is intentionally separate from
    /// enqueue so every group receives only one completion callback from the
    /// AppModel's background scan.
    func prioritize(groupID: String, priority: MetadataRequestPriority) {
        if let request = queuedByGroupID[groupID] {
            promote(request, priority: priority)
            queueNeedsSort = true
            pump()
        } else if let request = active[groupID] {
            // An active ImageIO read cannot be reprioritized, but recording the
            // new priority keeps the request state correct for diagnostics and
            // future scheduling changes.
            promote(request, priority: priority)
        } else {
            let current = requestedPriorities[groupID]
            if current == nil || priority.rawValue < current!.rawValue {
                requestedPriorities[groupID] = priority
            }
        }
    }

    func cancelAll() {
        quiescing = false
        for request in queued { request.task?.cancel() }
        for request in active.values { request.task?.cancel() }
        queued.removeAll()
        queuedByGroupID.removeAll()
        queueNeedsSort = false
        active.removeAll()
        observations.removeAll()
        requestedPriorities.removeAll()
        backgroundSuspended = false
    }

    /// Stops accepting new metadata reads and waits for every synchronous
    /// Data/ImageIO read already in progress to return before a removable
    /// volume is handed to Disk Arbitration.
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
        queuedByGroupID.removeAll()
        active.removeAll()
        observations.removeAll()
        requestedPriorities.removeAll()
        queueNeedsSort = false
        backgroundSuspended = false
    }

    func resumeAfterQuiesce() {
        quiescing = false
        queueNeedsSort = true
        pump()
    }

    func cancel(_ observationID: UUID) {
        guard let observation = observations.removeValue(forKey: observationID) else { return }

        if let request = active[observation.groupID], request.id == observation.requestID {
            request.observers.removeValue(forKey: observationID)
            // A keyed request may be shared by several tiles. Cancelling one
            // tile must not stop the read needed by the other observers.
            if request.observers.isEmpty {
                request.task?.cancel()
            }
        } else if let index = queued.firstIndex(where: { $0.id == observation.requestID }) {
            let request = queued[index]
            request.observers.removeValue(forKey: observationID)
            if request.observers.isEmpty {
                queued.remove(at: index)
                queuedByGroupID.removeValue(forKey: request.group.id)
            }
        }
        pump()
    }

    private func promote(_ request: Request, priority: MetadataRequestPriority) {
        if priority.rawValue < request.priority.rawValue {
            request.priority = priority
        }
        nextSequence &+= 1
        request.sequence = nextSequence
    }

    private func pump() {
        while !queued.isEmpty {
            if queueNeedsSort {
                queued.sort {
                    if $0.priority.rawValue != $1.priority.rawValue {
                        // Keep the highest-priority request at the end so it
                        // can be removed in O(1). Removing index zero from a
                        // 3,000+ item Array shifts every remaining element on
                        // the main actor for every completed metadata read.
                        return $0.priority.rawValue > $1.priority.rawValue
                    }
                    return $0.sequence < $1.sequence
                }
                queueNeedsSort = false
            }

            if backgroundSuspended,
               queued.last?.priority == .background {
                return
            }

            guard let next = queued.last else { return }
            if next.priority == .background {
                let backgroundActive = active.values.reduce(into: 0) { count, request in
                    if request.priority == .background { count += 1 }
                }
                guard backgroundActive < maxConcurrentBackgroundReads, active.isEmpty else { return }
            } else {
                guard active.count < maxConcurrentForegroundReads else { return }
            }

            let request = queued.removeLast()
            queuedByGroupID.removeValue(forKey: request.group.id)
            guard !request.observers.isEmpty else { continue }
            active[request.group.id] = request

            let task = Task { await request.loader(request.priority.taskPriority) }
            request.task = task
            let requestID = request.id
            let groupID = request.group.id
            Task { [weak self] in
                let metadata = await task.value
                guard let self else { return }
                self.finish(groupID: groupID, requestID: requestID, metadata: metadata)
            }
        }
    }

    private func finish(groupID: String, requestID: UUID, metadata: PhotoMetadata?) {
        guard let request = active[groupID], request.id == requestID else { return }
        active.removeValue(forKey: groupID)

        if quiescing {
            for observationID in request.observers.keys {
                observations.removeValue(forKey: observationID)
            }
            return
        }

        for observationID in request.observers.keys {
            observations.removeValue(forKey: observationID)
        }
        let callbacks = Array(request.observers.values)
        for callback in callbacks {
            callback(metadata)
        }
        pump()
    }
}
