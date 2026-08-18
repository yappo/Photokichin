import AppKit
import Foundation
import os
@preconcurrency import ImageCaptureCore

/// Tracks whether ImageCaptureCore asked for work that Photokichin did not
/// explicitly request. The counters are intentionally observable in the
/// unified log so a camera run can verify that preflight work was skipped.
private final class CameraRequestGate: @unchecked Sendable {
    static let shared = CameraRequestGate()

    private enum RequestKind {
        case thumbnail
        case metadata
    }

    private let lock = NSLock()
    private let logger = Logger(subsystem: "jp.yappo.Photokichin", category: "camera-io")
    private var explicitThumbnailRequests = 0
    private var explicitMetadataRequests = 0
    private var allowedThumbnails = 0
    private var deniedThumbnails = 0
    private var allowedMetadata = 0
    private var deniedMetadata = 0

    private var thumbnailRequests: [ObjectIdentifier: Int] = [:]
    private var metadataRequests: [ObjectIdentifier: Int] = [:]

    func beginThumbnail(_ item: ICCameraItem) {
        lock.lock()
        let id = ObjectIdentifier(item)
        thumbnailRequests[id, default: 0] += 1
        explicitThumbnailRequests += 1
        let explicitCount = explicitThumbnailRequests
        lock.unlock()
        logger.info("camera_io explicit_thumbnail_begin count=\(explicitCount, privacy: .public)")
    }

    func endThumbnail(_ item: ICCameraItem) {
        lock.lock()
        decrement(ObjectIdentifier(item), in: &thumbnailRequests)
        lock.unlock()
    }

    func beginMetadata(_ item: ICCameraItem) {
        lock.lock()
        let id = ObjectIdentifier(item)
        metadataRequests[id, default: 0] += 1
        explicitMetadataRequests += 1
        let explicitCount = explicitMetadataRequests
        lock.unlock()
        logger.info("camera_io explicit_metadata_begin count=\(explicitCount, privacy: .public)")
    }

    func endMetadata(_ item: ICCameraItem) {
        lock.lock()
        decrement(ObjectIdentifier(item), in: &metadataRequests)
        lock.unlock()
    }

    func allowsThumbnail(_ item: ICCameraItem) -> Bool {
        let (allowed, allowedCount, deniedCount, explicitCount) = recordDecision(item: item, kind: .thumbnail)
        if allowed || deniedCount <= 3 || deniedCount.isMultiple(of: 1000) {
            let decision = allowed ? 1 : 0
            logger.notice("camera_io delegate_thumbnail decision=\(decision, privacy: .public) allowed=\(allowedCount, privacy: .public) denied=\(deniedCount, privacy: .public) explicit=\(explicitCount, privacy: .public)")
        }
        return allowed
    }

    func allowsMetadata(_ item: ICCameraItem) -> Bool {
        let (allowed, allowedCount, deniedCount, explicitCount) = recordDecision(item: item, kind: .metadata)
        if allowed || deniedCount <= 3 || deniedCount.isMultiple(of: 1000) {
            let decision = allowed ? 1 : 0
            logger.notice("camera_io delegate_metadata decision=\(decision, privacy: .public) allowed=\(allowedCount, privacy: .public) denied=\(deniedCount, privacy: .public) explicit=\(explicitCount, privacy: .public)")
        }
        return allowed
    }

    func logSessionReady(elapsed: TimeInterval, mediaFileCount: Int, catalogPercent: Int) {
        logger.notice("camera_io session_ready elapsed_seconds=\(elapsed, privacy: .public) media_files=\(mediaFileCount, privacy: .public) catalog_percent=\(catalogPercent, privacy: .public)")
    }

    private func recordDecision(
        item: ICCameraItem,
        kind: RequestKind
    ) -> (Bool, Int, Int, Int) {
        lock.lock()
        let itemID = ObjectIdentifier(item)
        let allowed: Bool
        let allowedCount: Int
        let deniedCount: Int
        let explicitCount: Int
        switch kind {
        case .thumbnail:
            allowed = thumbnailRequests[itemID, default: 0] > 0
            if allowed { allowedThumbnails += 1 } else { deniedThumbnails += 1 }
            allowedCount = allowedThumbnails
            deniedCount = deniedThumbnails
            explicitCount = explicitThumbnailRequests
        case .metadata:
            allowed = metadataRequests[itemID, default: 0] > 0
            if allowed { allowedMetadata += 1 } else { deniedMetadata += 1 }
            allowedCount = allowedMetadata
            deniedCount = deniedMetadata
            explicitCount = explicitMetadataRequests
        }
        lock.unlock()
        return (allowed, allowedCount, deniedCount, explicitCount)
    }

    private func decrement(_ id: ObjectIdentifier, in counts: inout [ObjectIdentifier: Int]) {
        guard let count = counts[id] else { return }
        if count <= 1 {
            counts.removeValue(forKey: id)
        } else {
            counts[id] = count - 1
        }
    }
}

enum CameraConnectionState: Hashable, Sendable {
    case detected
    case openingSession
    case cataloging(percent: Int)
    case ready
    case ejecting
    case ejected
    case disconnected
    case failed(String)

    var title: String {
        switch self {
        case .detected: return "検出済み"
        case .openingSession: return "接続中…"
        case .cataloging: return "写真一覧を作成中…"
        case .ready: return "接続済み"
        case .ejecting: return "取り出し中…"
        case .ejected: return "取り出し済み"
        case .disconnected: return "未接続"
        case .failed(let message): return "接続エラー: " + message
        }
    }

    var isBrowsable: Bool {
        switch self {
        case .cataloging, .ready:
            return true
        default:
            return false
        }
    }
}

struct CameraDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let serialNumber: String?
    let isReady: Bool
    let groupCount: Int
    let canDeleteFiles: Bool
    let canEject: Bool
    let connectionState: CameraConnectionState

    var statusText: String {
        switch connectionState {
        case .ready: return "\(groupCount)組"
        case .cataloging:
            return groupCount == 0
                ? "写真一覧を準備中…"
                : "\(groupCount)組を表示中・追加読み込み中"
        default: return connectionState.title
        }
    }

    var isCataloging: Bool {
        if case .cataloging = connectionState { return true }
        return false
    }
}

/// Owns the ImageCaptureCore browser and the live ICCameraFile objects. A
/// camera is a PTP device, not a filesystem volume, so this is intentionally
/// separate from VolumeMonitor and PhotoScanner.
@MainActor
final class CameraMonitor: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICDeviceDelegate, ICCameraDeviceDelegate {
    static let shared = CameraMonitor()

    @Published private(set) var cameras: [CameraDescriptor] = []
    private let browser = ICDeviceBrowser()
    private let logger = Logger(subsystem: "jp.yappo.Photokichin", category: "camera-io")
    private var records: [String: CameraRecord] = [:]
    private var didStart = false

    var onCameraReady: ((CameraDescriptor, [PhotoGroup]) -> Void)?
    var onCameraCatalogUpdate: ((CameraDescriptor, [PhotoGroup]) -> Void)?
    var onCameraRemoved: ((String) -> Void)?
    var onCamerasChanged: (([CameraDescriptor]) -> Void)?
    var onError: ((String) -> Void)?

    private final class CameraRecord {
        let device: ICCameraDevice
        let sessionRequestedAt: Date
        var descriptor: CameraDescriptor
        var filesByIdentifier: [String: ICCameraFile] = [:]
        var groups: [PhotoGroup] = []
        var catalogProgressTask: Task<Void, Never>?
        var catalogRefreshTask: Task<Void, Never>?

        init(device: ICCameraDevice, descriptor: CameraDescriptor) {
            self.device = device
            self.sessionRequestedAt = Date()
            self.descriptor = descriptor
        }
    }

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        ) ?? .camera
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        browser.start()
        // ImageCaptureCore normally reports already-connected devices via
        // the delegate. Some macOS camera-service states only populate the
        // browser's device list after start, so reconcile it once as well.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.didStart else { return }
            for device in self.browser.devices ?? [] {
                self.add(device)
            }
        }
    }

    func stop() {
        guard didStart else { return }
        didStart = false
        browser.stop()
        for record in records.values {
            record.catalogProgressTask?.cancel()
            record.catalogRefreshTask?.cancel()
        }
        for record in records.values where record.device.hasOpenSession {
            record.device.requestCloseSession()
        }
        records.removeAll()
        cameras.removeAll()
        onCamerasChanged?(cameras)
    }

    func descriptor(for id: String) -> CameraDescriptor? {
        records[id]?.descriptor
    }

    func groups(for id: String) -> [PhotoGroup]? {
        records[id]?.groups
    }

    func file(for reference: CameraPhotoReference, variant: AssetVariant) -> ICCameraFile? {
        guard let asset = reference.asset(for: variant) else { return nil }
        return records[reference.cameraID]?.filesByIdentifier[asset.identifier]
    }

    func catalogIdentity(for cameraID: String) -> String {
        "camera:\(cameraID)"
    }

    func catalogSourceKey(for group: PhotoGroup, variant: AssetVariant) -> String {
        guard let reference = group.cameraReference else {
            return "camera:unknown:\(group.id):\(variant.rawValue)"
        }
        return Self.catalogSourceKey(cameraID: reference.cameraID, groupKey: reference.groupKey, variant: variant)
    }

    nonisolated static func catalogSourceKey(cameraID: String, groupKey: String, variant: AssetVariant) -> String {
        "camera:\(cameraID):\(groupKey):\(variant.rawValue)"
    }

    static func sourceURL(for cameraID: String) -> URL {
        URL(fileURLWithPath: "/__photokichin_camera__")
            .appendingPathComponent(safePathComponent(cameraID), isDirectory: true)
    }

    func eject(id: String) async throws {
        guard let record = records[id] else {
            throw AppError.ejectFailed("カメラが接続されていません")
        }
        guard record.descriptor.canEject, record.device.isEjectable else {
            throw AppError.ejectFailed("このカメラは安全な取り出しに対応していません")
        }

        let cameraID = cameraIdentifier(record.device)
        updateState(for: record, state: .ejecting)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            record.device.requestEject { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    guard let record = self.records[cameraID] else {
                        continuation.resume(throwing: AppError.ejectFailed("カメラが切断されました"))
                        return
                    }
                    if let error {
                        self.updateState(for: record, state: .failed(error.localizedDescription))
                        continuation.resume(throwing: error)
                    } else {
                        self.updateState(for: record, state: .ejected)
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }

    /// Downloads one original file into the caller-provided directory. Camera
    /// imports pass a hidden partial filename in the final library directory
    /// and rename it only after verification.
    func download(
        group: PhotoGroup,
        variant: AssetVariant,
        to directory: URL,
        filename requestedFilename: String? = nil
    ) async throws -> URL {
        guard let reference = group.cameraReference,
              let asset = reference.asset(for: variant),
              let file = file(for: reference, variant: variant) else {
            throw NSError(
                domain: "Photokichin.Camera",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "カメラ上のファイルが見つかりません: \(group.basename)"]
            )
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = URL(fileURLWithPath: requestedFilename ?? asset.filename).lastPathComponent
        let expectedURL = directory.appendingPathComponent(filename)

        return try await withCheckedThrowingContinuation { continuation in
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: directory,
                .saveAsFilename: filename,
                .overwrite: true
            ]
            file.requestDownload(options: options) { returnedFilename, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let returnedName = returnedFilename.map { URL(fileURLWithPath: $0).lastPathComponent }
                let returnedURL = returnedName.map { directory.appendingPathComponent($0) }
                if let returnedURL, FileManager.default.fileExists(atPath: returnedURL.path) {
                    continuation.resume(returning: returnedURL)
                } else if FileManager.default.fileExists(atPath: expectedURL.path) {
                    continuation.resume(returning: expectedURL)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "Photokichin.Camera",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "カメラからのダウンロード後にファイルが見つかりません: \(filename)"]
                    ))
                }
            }
        }
    }

    /// Deletes one camera file. Callers use this operation for every selected
    /// JPG/CR3 asset after one explicit group-level confirmation.
    func delete(group: PhotoGroup, variant: AssetVariant) async throws {
        guard let reference = group.cameraReference,
              let file = file(for: reference, variant: variant),
              let record = records[reference.cameraID] else {
            throw NSError(
                domain: "Photokichin.Camera",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "カメラ上のファイルが見つかりません: \(group.basename)"]
            )
        }
        let device = record.device
        guard device.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue) else {
            throw NSError(
                domain: "Photokichin.Camera",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "このカメラはファイル削除に対応していません"]
            )
        }
        guard !device.isLocked, !file.isLocked else {
            throw NSError(
                domain: "Photokichin.Camera",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "カメラまたはSDカードがロックされているため削除できません"]
            )
        }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let progress = device.requestDeleteFiles(
                    [file],
                    deleteFailed: { _ in },
                    completion: { result, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let failedItems = result[.failed], !failedItems.isEmpty {
                            continuation.resume(throwing: NSError(
                                domain: "Photokichin.Camera",
                                code: 6,
                                userInfo: [NSLocalizedDescriptionKey: "カメラ上の\(variant.rawValue)を削除できませんでした"]
                            ))
                        } else {
                            continuation.resume(returning: ())
                        }
                    }
                )
                if progress == nil {
                    continuation.resume(throwing: NSError(
                        domain: "Photokichin.Camera",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "カメラが削除処理を開始できませんでした"]
                    ))
                }
            }
        }, onCancel: {
            device.cancelDelete()
        })
    }

    // MARK: ICDeviceBrowserDelegate

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor [weak self] in
            self?.add(device)
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor [weak self] in
            self?.remove(device)
        }
    }

    // MARK: ICDeviceDelegate

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                if let record = self.record(for: device) {
                    self.updateState(for: record, state: .failed(error.localizedDescription))
                }
                self.onError?("カメラを開けませんでした: \(error.localizedDescription)")
            } else if let camera = device as? ICCameraDevice,
                      let record = self.record(for: device) {
                self.updateState(for: record, state: .cataloging(percent: Int(camera.contentCatalogPercentCompleted)))
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            guard let self, let record = self.record(for: device) else { return }
            self.updateState(for: record, state: .failed(error.localizedDescription))
        }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor [weak self] in
            self?.remove(device)
        }
    }

    nonisolated func device(_ device: ICDevice, didEjectWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, let record = self.record(for: device) else { return }
            if let error {
                self.updateState(for: record, state: .failed(error.localizedDescription))
            } else {
                self.updateState(for: record, state: .ejected)
            }
        }
    }

    // MARK: ICCameraDeviceDelegate

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor [weak self] in
            guard let self, let record = self.record(for: device) else { return }
            CameraRequestGate.shared.logSessionReady(
                elapsed: Date().timeIntervalSince(record.sessionRequestedAt),
                mediaFileCount: device.mediaFiles?.count ?? 0,
                catalogPercent: Int(device.contentCatalogPercentCompleted)
            )
            self.catalogReady(device)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor [weak self] in
            guard let self, let record = self.record(for: camera) else { return }
            // Initial enumeration is published atomically from
            // deviceDidBecomeReady. Publishing each didAdd batch makes the
            // first row stay in place while later batches are inserted ahead
            // of it, which repeatedly moves the rest of the grid and causes
            // duplicate thumbnail work.
            guard record.descriptor.connectionState == .ready else { return }
            self.scheduleCatalogRefresh(for: camera)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        Task { @MainActor [weak self] in
            guard let self, let record = self.record(for: camera) else { return }
            guard record.descriptor.connectionState == .ready else { return }
            self.scheduleCatalogRefresh(for: camera)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        Task { @MainActor [weak self] in
            guard let self, let record = self.record(for: camera) else { return }
            if record.descriptor.connectionState == .ready {
                self.scheduleCatalogRefresh(for: camera)
            }
        }
    }
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        Task { @MainActor [weak self] in
            guard let self, let record = self.record(for: camera) else { return }
            self.refreshDescriptor(for: record)
        }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDevice(_ cameraDevice: ICCameraDevice, shouldGetThumbnailOf item: ICCameraItem) -> Bool {
        CameraRequestGate.shared.allowsThumbnail(item)
    }
    nonisolated func cameraDevice(_ cameraDevice: ICCameraDevice, shouldGetMetadataOf item: ICCameraItem) -> Bool {
        CameraRequestGate.shared.allowsMetadata(item)
    }

    private func add(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice else { return }
        let id = cameraIdentifier(camera)
        if let existing = records[id] {
            // ImageCaptureCore can repost one physical camera with the same
            // UUID but a new ICCameraDevice instance while ptpcamerad
            // reconnects. Keeping the old object here leaves its session in
            // openingSession forever and drops the new object's ready event.
            guard existing.device !== camera else { return }
            existing.catalogProgressTask?.cancel()
            existing.catalogRefreshTask?.cancel()
            CameraThumbnailCoordinator.shared.removeCamera(id: id)
            logger.notice("camera_io device_replaced same_uuid=1")
        }

        let descriptor = CameraDescriptor(
            id: id,
            name: camera.name ?? camera.productKind ?? "USBカメラ",
            serialNumber: camera.serialNumberString,
            isReady: false,
            groupCount: 0,
            canDeleteFiles: canDeleteFiles(camera),
            canEject: canEject(camera),
            connectionState: .openingSession
        )
        let record = CameraRecord(device: camera, descriptor: descriptor)
        records[id] = record
        camera.delegate = self
        publishDescriptors()
        startCatalogProgress(for: id)
        camera.requestOpenSession()
    }

    private func startCatalogProgress(for id: String) {
        records[id]?.catalogProgressTask?.cancel()
        records[id]?.catalogProgressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, let record = self.records[id] else { return }
                guard record.device.hasOpenSession else { continue }
                guard record.descriptor.connectionState != .ready else { return }
                let percent = Int(record.device.contentCatalogPercentCompleted)
                self.updateState(for: record, state: .cataloging(percent: percent))
            }
        }
    }

    private func remove(_ device: ICDevice) {
        let id: String
        if let camera = device as? ICCameraDevice {
            id = cameraIdentifier(camera)
            // A delayed removal for the old object must not remove a newly
            // registered object with the same camera UUID.
            guard let current = records[id], current.device === camera else { return }
        } else {
            guard let matchingID = records.first(where: { $0.value.device === device })?.key else { return }
            id = matchingID
        }
        guard let record = records.removeValue(forKey: id) else { return }
        record.catalogProgressTask?.cancel()
        record.catalogRefreshTask?.cancel()
        CameraThumbnailCoordinator.shared.removeCamera(id: id)
        publishDescriptors()
        onCameraRemoved?(id)
    }

    private func catalogReady(_ camera: ICCameraDevice) {
        let id = cameraIdentifier(camera)
        records[id]?.catalogRefreshTask?.cancel()
        records[id]?.catalogRefreshTask = nil
        updateCatalog(for: camera, isComplete: true)
    }

    private func scheduleCatalogRefresh(for camera: ICCameraDevice) {
        let id = cameraIdentifier(camera)
        guard let record = records[id] else { return }
        record.catalogRefreshTask?.cancel()
        record.catalogRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, let record = self.records[id] else { return }
            record.catalogRefreshTask = nil
            self.catalogReady(record.device)
        }
    }

    private func updateCatalog(for camera: ICCameraDevice, isComplete: Bool) {
        let id = cameraIdentifier(camera)
        guard let record = records[id] else { return }

        var files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        // ImageCaptureCore exposes the JPG/CR3 relationship through
        // pairedRawImage. Keep a paired RAW in the catalog even if a camera
        // driver omitted it from the flat mediaFiles array.
        var knownIdentifiers = Set<String>()
        let catalogFiles = files
        for file in catalogFiles {
            guard let filename = file.originalFilename ?? file.name else { continue }
            knownIdentifiers.insert(assetIdentifier(for: file, remotePath: remotePath(for: file, filename: filename)))
        }
        for file in catalogFiles {
            guard let raw = file.pairedRawImage,
                  let filename = raw.originalFilename ?? raw.name else { continue }
            let identifier = assetIdentifier(for: raw, remotePath: remotePath(for: raw, filename: filename))
            if knownIdentifiers.insert(identifier).inserted {
                files.append(raw)
            }
        }

        var pairedGroupKeys: [String: String] = [:]
        for file in files {
            guard let filename = file.originalFilename ?? file.name,
                  variant(for: filename) == .jpeg,
                  let raw = file.pairedRawImage,
                  let rawFilename = raw.originalFilename ?? raw.name else { continue }
            let jpegPath = remotePath(for: file, filename: filename)
            let rawPath = remotePath(for: raw, filename: rawFilename)
            let groupKey = remotePathWithoutExtension(jpegPath)
            pairedGroupKeys[assetIdentifier(for: file, remotePath: jpegPath)] = groupKey
            pairedGroupKeys[assetIdentifier(for: raw, remotePath: rawPath)] = groupKey
        }

        var groupsByKey: [String: PhotoGroup] = [:]
        var fileIndex: [String: ICCameraFile] = [:]
        let previousGroups = Dictionary(uniqueKeysWithValues: record.groups.map { ($0.id, $0) })

        for file in files {
            guard let filename = file.originalFilename ?? file.name,
                  let variant = variant(for: filename) else { continue }
            let remotePath = remotePath(for: file, filename: filename)
            let assetIdentifier = assetIdentifier(for: file, remotePath: remotePath)
            let groupKey = pairedGroupKeys[assetIdentifier] ?? remotePathWithoutExtension(remotePath)
            let asset = CameraAssetReference(
                identifier: assetIdentifier,
                filename: URL(fileURLWithPath: filename).lastPathComponent,
                variant: variant,
                fileSize: Int64(file.fileSize),
                captureDate: file.creationDate as Date?
            )
            fileIndex[assetIdentifier] = file

            let groupID = "camera:\(id):\(groupKey)"
            var group = groupsByKey[groupKey] ?? previousGroups[groupID] ?? PhotoGroup(
                id: groupID,
                basename: URL(fileURLWithPath: groupKey).lastPathComponent,
                directory: cameraDirectoryURL(cameraID: id, remotePath: remotePath),
                jpegURL: nil,
                rawURL: nil,
                movieURL: nil,
                captureDate: asset.captureDate,
                metadata: PhotoMetadata(
                    captureDate: asset.captureDate,
                    cameraMake: nil,
                    cameraModel: camera.name,
                    lensModel: nil,
                    focalLength: nil,
                    aperture: nil,
                    shutterSpeed: nil,
                    iso: nil,
                    exposureBias: nil,
                    orientation: nil,
                    gps: nil,
                    firmware: nil,
                    pixelWidth: file.width > 0 ? file.width : nil,
                    pixelHeight: file.height > 0 ? file.height : nil
                ),
                importedJPEG: false,
                importedRAW: false,
                isMetadataLoaded: false,
                cameraReference: CameraPhotoReference(cameraID: id, groupKey: groupKey, assets: [])
            )

            let existingAssets = group.cameraReference?.assets ?? []
            var assets = existingAssets.filter { $0.variant != variant }
            assets.append(asset)
            group.cameraReference = CameraPhotoReference(cameraID: id, groupKey: groupKey, assets: assets)
            if let date = asset.captureDate,
               group.captureDate == nil || date < group.captureDate! {
                group.captureDate = date
                group.metadata.captureDate = date
            }
            groupsByKey[groupKey] = group
        }

        // Assign fixed slots once. Existing camera groups keep their original
        // slot; only groups that were not in the previous catalog are sorted
        // among themselves and appended after the existing slots. Thumbnail
        // and metadata callbacks never enter this path, so they cannot move
        // already-rendered rows or trigger an O(n log n) resort.
        let previousOrderByID = Dictionary(
            uniqueKeysWithValues: previousGroups.values.map { ($0.id, $0.presentationOrder) }
        )
        var nextPresentationOrder = (previousOrderByID.values.max() ?? -1) + 1
        var existingGroups = groupsByKey.values.filter { previousOrderByID[$0.id] != nil }
        existingGroups.sort {
            previousOrderByID[$0.id, default: Int.max]
                < previousOrderByID[$1.id, default: Int.max]
        }
        var newGroups = groupsByKey.values.filter { previousOrderByID[$0.id] == nil }
        newGroups.sort {
            let lhsDate = $0.captureDate ?? .distantFuture
            let rhsDate = $1.captureDate ?? .distantFuture
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            let basenameOrder = $0.basename.localizedStandardCompare($1.basename)
            if basenameOrder != .orderedSame { return basenameOrder == .orderedAscending }
            return $0.id < $1.id
        }
        for index in newGroups.indices {
            newGroups[index].presentationOrder = nextPresentationOrder
            nextPresentationOrder += 1
        }
        let groups = existingGroups + newGroups
        if isComplete {
            record.catalogProgressTask?.cancel()
            record.catalogProgressTask = nil
        }
        record.filesByIdentifier = fileIndex
        record.groups = groups
        record.descriptor = CameraDescriptor(
            id: id,
            name: camera.name ?? camera.productKind ?? "USBカメラ",
            serialNumber: camera.serialNumberString,
            isReady: true,
            groupCount: groups.count,
            canDeleteFiles: canDeleteFiles(camera),
            canEject: canEject(camera),
            connectionState: isComplete
                ? .ready
                : .cataloging(percent: Int(camera.contentCatalogPercentCompleted))
        )
        publishDescriptors()
        if isComplete {
            onCameraReady?(record.descriptor, groups)
        } else {
            onCameraCatalogUpdate?(record.descriptor, groups)
        }
    }

    func requestMetadata(for group: PhotoGroup) async -> PhotoMetadata? {
        guard let reference = group.cameraReference,
              let record = records[reference.cameraID],
              let asset = reference.asset(for: .jpeg) ?? reference.assets.first,
              let file = record.filesByIdentifier[asset.identifier] else { return nil }

        let gate = CameraRequestGate.shared
        gate.beginMetadata(file)
        return await withCheckedContinuation { continuation in
            file.requestMetadataDictionary(options: nil) { dictionary, _ in
                gate.endMetadata(file)
                continuation.resume(returning: dictionary.flatMap { ImageIOReader.readMetadata(properties: $0) })
            }
        }
    }

    private func publishDescriptors() {
        cameras = records.values.map(\.descriptor).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        onCamerasChanged?(cameras)
    }

    private func record(for device: ICDevice) -> CameraRecord? {
        records.values.first { $0.device === device }
    }

    private func canDeleteFiles(_ camera: ICCameraDevice) -> Bool {
        camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
    }

    private func canEject(_ camera: ICCameraDevice) -> Bool {
        camera.isEjectable
            && camera.capabilities.contains(ICDeviceCapability.canEjectOrDisconnect.rawValue)
    }

    private func refreshDescriptor(for record: CameraRecord) {
        let camera = record.device
        record.descriptor = CameraDescriptor(
            id: cameraIdentifier(camera),
            name: camera.name ?? camera.productKind ?? "USBカメラ",
            serialNumber: camera.serialNumberString,
            isReady: record.descriptor.isReady,
            groupCount: record.groups.count,
            canDeleteFiles: canDeleteFiles(camera),
            canEject: canEject(camera),
            connectionState: record.descriptor.connectionState
        )
        publishDescriptors()
    }

    private func updateState(for record: CameraRecord, state: CameraConnectionState) {
        let camera = record.device
        record.descriptor = CameraDescriptor(
            id: cameraIdentifier(camera),
            name: camera.name ?? camera.productKind ?? "USBカメラ",
            serialNumber: camera.serialNumberString,
            isReady: state.isBrowsable,
            groupCount: record.groups.count,
            canDeleteFiles: canDeleteFiles(camera),
            canEject: canEject(camera),
            connectionState: state
        )
        publishDescriptors()
    }

    private func cameraIdentifier(_ camera: ICCameraDevice) -> String {
        camera.uuidString
            ?? "usb-\(camera.usbVendorID)-\(camera.usbProductID)-\(camera.usbLocationID)-\(camera.name ?? "camera")"
    }

    private func variant(for filename: String) -> AssetVariant? {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "cr3": return .raw
        case "mov", "mp4": return .movie
        default: return nil
        }
    }

    private func remotePath(for file: ICCameraFile, filename: String) -> String {
        var components = [URL(fileURLWithPath: filename).lastPathComponent]
        var folder = file.parentFolder
        while let current = folder {
            if let name = current.name, !name.isEmpty {
                components.insert(name, at: 0)
            }
            folder = current.parentFolder
        }
        return components.joined(separator: "/")
    }

    private func remotePathWithoutExtension(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingPathExtension().path
    }

    private func assetIdentifier(for file: ICCameraFile, remotePath: String) -> String {
        if file.ptpObjectHandle != 0 {
            return "handle:\(file.ptpObjectHandle)"
        }
        return "path:\(remotePath)"
    }

    private func cameraDirectoryURL(cameraID: String, remotePath: String) -> URL {
        let directoryComponents = URL(fileURLWithPath: remotePath)
            .deletingLastPathComponent()
            .pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
        var result = URL(fileURLWithPath: "/__photokichin_camera__")
            .appendingPathComponent(CameraMonitor.safePathComponent(cameraID), isDirectory: true)
        for component in directoryComponents {
            result.appendPathComponent(component, isDirectory: true)
        }
        return result
    }

    private static func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }
}

private func safePathComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
}

/// Requests JPEG thumbnails from the camera without downloading CR3/JPEG
/// originals. The queue mirrors the file-backed thumbnail coordinator:
/// visible photos take priority, one camera request runs at a time, and the
/// list/viewer working sets can prefetch without blocking the current photo.
@MainActor
final class CameraThumbnailCoordinator {
    static let shared = CameraThumbnailCoordinator()

    private struct Key: Hashable {
        let cameraID: String
        let assetIdentifier: String
        let maxPixel: Int
    }

    private final class Request {
        let id = UUID()
        let key: Key
        let file: ICCameraFile
        var priority: ThumbnailRequestPriority
        var sequence: UInt64
        var observers: [UUID: (NSImage?) -> Void] = [:]

        init(key: Key, file: ICCameraFile, priority: ThumbnailRequestPriority, sequence: UInt64) {
            self.key = key
            self.file = file
            self.priority = priority
            self.sequence = sequence
        }
    }

    private struct Observation {
        let key: Key
        let requestID: UUID
    }

    private let maxConcurrentLoads = 1
    private var nextSequence: UInt64 = 0
    private var cache: [Key: NSImage] = [:]
    private var queued: [Request] = []
    private var active: [Key: Request] = [:]
    private var observations: [UUID: Observation] = [:]
    private var viewerPrefetchIDs: Set<UUID> = []
    private var listWorkingSetIDs: [Key: (id: UUID, priority: ThumbnailRequestPriority)] = [:]

    @discardableResult
    func subscribe(
        group: PhotoGroup,
        maxPixel: Int,
        priority: ThumbnailRequestPriority,
        onImage: @escaping (NSImage?) -> Void
    ) -> UUID? {
        guard let reference = group.cameraReference,
              let asset = reference.asset(for: .jpeg) ?? reference.asset(for: .raw),
              let file = CameraMonitor.shared.file(for: reference, variant: asset.variant) else {
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
            let request = Request(key: key, file: file, priority: priority, sequence: nextSequence)
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
        } else if let index = queued.firstIndex(where: { $0.id == observation.requestID }) {
            let request = queued[index]
            request.observers.removeValue(forKey: observationID)
            if request.observers.isEmpty {
                queued.remove(at: index)
            }
        }
        pump()
    }

    func cancelAll() {
        for request in active.values { request.observers.removeAll() }
        queued.removeAll()
        observations.removeAll()
        viewerPrefetchIDs.removeAll()
        listWorkingSetIDs.removeAll()
    }

    func updateViewerPrefetch(groups: [PhotoGroup], maxPixel: Int) {
        for observationID in viewerPrefetchIDs { cancel(observationID) }
        viewerPrefetchIDs.removeAll()
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
                  let asset = reference.asset(for: .jpeg) ?? reference.asset(for: .raw) else {
                return nil
            }
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
        let keys = cache.keys.filter { $0.cameraID == id }
        for key in keys { cache.removeValue(forKey: key) }
        for request in active.values where request.key.cameraID == id {
            request.observers.removeAll()
        }
        for key in queued.filter({ $0.key.cameraID == id }).map(\.key) {
            guard let index = queued.firstIndex(where: { $0.key == key }) else { continue }
            let request = queued.remove(at: index)
            for observationID in request.observers.keys {
                observations.removeValue(forKey: observationID)
            }
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
            let key = request.key
            let requestID = request.id
            let file = request.file
            let gate = CameraRequestGate.shared
            gate.beginThumbnail(file)
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: key.maxPixel]) { [weak self] data, _ in
                gate.endThumbnail(file)
                Task { @MainActor [weak self] in
                    self?.finish(requestID: requestID, key: key, data: data)
                }
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
