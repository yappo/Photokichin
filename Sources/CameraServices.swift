import AppKit
import Foundation
import IOKit
import IOKit.usb
import os
@preconcurrency import ImageCaptureCore

/// A point-in-time summary of the files that ImageCaptureCore has exposed.
/// File sizes are catalog metadata; no photo bytes are read here.
private struct CameraCatalogSummary: Sendable {
    var fileCount = 0
    var totalBytes: Int64 = 0
    var minimumBytes: Int64?
    var maximumBytes: Int64 = 0
    var jpegCount = 0
    var rawCount = 0
    var movieCount = 0
    var otherCount = 0
    var jpegBytes: Int64 = 0
    var rawBytes: Int64 = 0
    var movieBytes: Int64 = 0

    mutating func add(_ file: ICCameraFile) {
        let size = Int64(file.fileSize)
        fileCount += 1
        totalBytes += size
        minimumBytes = minimumBytes.map { min($0, size) } ?? size
        maximumBytes = max(maximumBytes, size)

        switch URL(fileURLWithPath: file.originalFilename ?? file.name ?? "")
            .pathExtension.lowercased() {
        case "jpg", "jpeg":
            jpegCount += 1
            jpegBytes += size
        case "cr3":
            rawCount += 1
            rawBytes += size
        case "mov", "mp4":
            movieCount += 1
            movieBytes += size
        default: otherCount += 1
        }
    }

    static func fileBytes(in items: [ICCameraItem]) -> Int64 {
        items.reduce(into: Int64(0)) { total, item in
            if let file = item as? ICCameraFile {
                total += Int64(file.fileSize)
            }
        }
    }

    var averageBytes: Double {
        guard fileCount > 0 else { return 0 }
        return Double(totalBytes) / Double(fileCount)
    }

    var minimumBytesForLog: Int64 { minimumBytes ?? 0 }
}

private struct CameraUSBInfo: Sendable {
    let speed: String
    let probeElapsed: TimeInterval

    static func read(for camera: ICCameraDevice) -> CameraUSBInfo {
        let startedAt = Date()
        let speed = findSpeed(
            vendorID: UInt64(max(0, camera.usbVendorID)),
            productID: UInt64(max(0, camera.usbProductID)),
            locationID: UInt64(max(0, camera.usbLocationID))
        ) ?? "unknown"
        return CameraUSBInfo(speed: speed, probeElapsed: Date().timeIntervalSince(startedAt))
    }

    private static func findSpeed(vendorID: UInt64, productID: UInt64, locationID: UInt64) -> String? {
        let classNames = [kIOUSBHostDeviceClassName, kIOUSBDeviceClassName]
        for className in classNames {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard let properties = properties(for: service),
                      number(properties["idVendor"]) == vendorID,
                      number(properties["idProduct"]) == productID,
                      number(properties["locationID"]) == locationID else {
                    continue
                }

                if let raw = number(properties["USBSpeed"]) {
                    return speedName(raw, host: true)
                }
                if let raw = number(properties["Device Speed"]) {
                    return speedName(raw, host: false)
                }
                if let raw = number(properties["UsbLinkSpeed"]) {
                    return "\(raw)bps"
                }
            }
        }
        return nil
    }

    private static func properties(for service: io_service_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
        let properties else { return nil }
        return properties.takeRetainedValue() as? [String: Any]
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        return nil
    }

    private static func speedName(_ raw: UInt64, host: Bool) -> String {
        if host {
            switch raw {
            case 1: return "full"
            case 2: return "low"
            case 3: return "high"
            case 4: return "super"
            case 5: return "super_plus"
            case 6: return "super_plus_by2"
            default: return "raw_\(raw)"
            }
        }
        switch raw {
        case 0: return "low"
        case 1: return "full"
        case 2: return "high"
        case 3: return "super"
        case 4: return "super_plus"
        case 5: return "super_plus_by2"
        default: return "raw_\(raw)"
        }
    }
}

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

    func logSessionReady(
        elapsed: TimeInterval,
        mediaFileCount: Int,
        catalogPercent: Int,
        summary: CameraCatalogSummary,
        usb: CameraUSBInfo,
        summaryScanElapsed: TimeInterval
    ) {
        logger.notice(
            "camera_io session_ready elapsed_seconds=\(elapsed, privacy: .public) files_per_second=\(elapsed > 0 ? Double(mediaFileCount) / elapsed : 0, privacy: .public) total_file_bytes=\(summary.totalBytes, privacy: .public) bytes_per_second=\(elapsed > 0 ? Double(summary.totalBytes) / elapsed : 0, privacy: .public) media_files=\(mediaFileCount, privacy: .public) catalog_percent=\(catalogPercent, privacy: .public) average_file_bytes=\(summary.averageBytes, privacy: .public) minimum_file_bytes=\(summary.minimumBytesForLog, privacy: .public) maximum_file_bytes=\(summary.maximumBytes, privacy: .public) jpeg_files=\(summary.jpegCount, privacy: .public) jpeg_bytes=\(summary.jpegBytes, privacy: .public) raw_files=\(summary.rawCount, privacy: .public) raw_bytes=\(summary.rawBytes, privacy: .public) movie_files=\(summary.movieCount, privacy: .public) movie_bytes=\(summary.movieBytes, privacy: .public) other_files=\(summary.otherCount, privacy: .public) summary_scan_elapsed_ms=\(summaryScanElapsed * 1000, privacy: .public) usb_speed=\(usb.speed, privacy: .public) usb_probe_elapsed_ms=\(usb.probeElapsed * 1000, privacy: .public)"
        )
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

/// The values needed to build a camera catalog, separated from the live
/// ImageCaptureCore objects.  ICCameraFile is kept in CameraMonitor, while
/// these values can be used by deterministic tests and catalog construction.
struct CameraCatalogAsset: Hashable, Sendable {
    let identifier: String
    let filename: String
    let remotePath: String
    let variant: AssetVariant
    let fileSize: Int64
    let captureDate: Date?
    let width: Int
    let height: Int
}

struct CameraCatalogEntry: Hashable, Sendable {
    let asset: CameraCatalogAsset
    let pairedRaw: CameraCatalogAsset?
}

enum CameraCatalogRefreshDecision: Equatable {
    case accepted
    case ignored(String)
}

/// Pure part of the leading-edge catalog refresh gate.  The clock and the
/// catalog update remain owned by CameraMonitor; this type only decides
/// whether a received notification is allowed to start an update.
struct CameraCatalogRefreshGate {
    static let interval: TimeInterval = 5

    static func decision(
        receivedAt: Date,
        completionEventAt: Date?,
        updateInFlight: Bool,
        updateStartedAt: Date?,
        updateFinishedAt: Date?,
        nextAllowedAt: Date?
    ) -> CameraCatalogRefreshDecision {
        if let completionEventAt, receivedAt <= completionEventAt {
            return .ignored("before_completion_event")
        }
        if updateInFlight,
           let updateStartedAt,
           receivedAt >= updateStartedAt {
            return .ignored("catalog_update_in_flight")
        }
        if let updateStartedAt,
           let updateFinishedAt,
           receivedAt >= updateStartedAt,
           receivedAt <= updateFinishedAt {
            return .ignored("catalog_update_in_flight")
        }
        if let nextAllowedAt, receivedAt < nextAllowedAt {
            return .ignored("five_second_interval")
        }
        return .accepted
    }
}

/// Builds the complete catalog snapshot from values read from
/// ImageCaptureCore.  It deliberately replaces the previous snapshot: a
/// group absent from the current camera input is not carried forward.
enum CameraCatalogBuilder {
    static func variant(for filename: String) -> AssetVariant? {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "cr3": return .raw
        case "mov", "mp4": return .movie
        default: return nil
        }
    }

    static func groups(
        cameraID: String,
        cameraName: String?,
        entries: [CameraCatalogEntry],
        previousGroups: [PhotoGroup]
    ) -> [PhotoGroup] {
        var uniqueEntries: [CameraCatalogEntry] = []
        var indexByIdentifier: [String: Int] = [:]
        for entry in entries {
            if let index = indexByIdentifier[entry.asset.identifier] {
                // Duplicate notifications for one asset must not create a
                // second asset, but a later notification may carry the
                // paired RAW relation that the first one did not carry.
                if uniqueEntries[index].pairedRaw == nil, let pairedRaw = entry.pairedRaw {
                    uniqueEntries[index] = CameraCatalogEntry(
                        asset: uniqueEntries[index].asset,
                        pairedRaw: pairedRaw
                    )
                }
                continue
            }
            indexByIdentifier[entry.asset.identifier] = uniqueEntries.count
            uniqueEntries.append(entry)
        }

        var allAssets: [CameraCatalogAsset] = uniqueEntries.map(\.asset)
        var knownIdentifiers = Set(allAssets.map(\.identifier))
        for entry in uniqueEntries {
            if let pairedRaw = entry.pairedRaw,
               knownIdentifiers.insert(pairedRaw.identifier).inserted {
                allAssets.append(pairedRaw)
            }
        }

        var pairedGroupKeys: [String: String] = [:]
        for entry in uniqueEntries {
            guard entry.asset.variant == .jpeg, let raw = entry.pairedRaw else { continue }
            let groupKey = remotePathWithoutExtension(entry.asset.remotePath)
            pairedGroupKeys[entry.asset.identifier] = groupKey
            pairedGroupKeys[raw.identifier] = groupKey
        }

        let previousByID = Dictionary(uniqueKeysWithValues: previousGroups.map { ($0.id, $0) })
        var groupsByKey: [String: PhotoGroup] = [:]
        for asset in allAssets {
            let groupKey = pairedGroupKeys[asset.identifier] ?? remotePathWithoutExtension(asset.remotePath)
            let groupID = "camera:\(cameraID):\(groupKey)"
            var group = groupsByKey[groupKey] ?? previousByID[groupID] ?? PhotoGroup(
                id: groupID,
                basename: URL(fileURLWithPath: groupKey).lastPathComponent,
                directory: cameraDirectoryURL(cameraID: cameraID, remotePath: asset.remotePath),
                jpegURL: nil,
                rawURL: nil,
                movieURL: nil,
                captureDate: asset.captureDate,
                metadata: PhotoMetadata(
                    captureDate: asset.captureDate,
                    cameraMake: nil,
                    cameraModel: cameraName,
                    lensModel: nil,
                    focalLength: nil,
                    aperture: nil,
                    shutterSpeed: nil,
                    iso: nil,
                    exposureBias: nil,
                    orientation: nil,
                    gps: nil,
                    firmware: nil,
                    pixelWidth: asset.width > 0 ? asset.width : nil,
                    pixelHeight: asset.height > 0 ? asset.height : nil
                ),
                importedJPEG: false,
                importedRAW: false,
                isMetadataLoaded: false,
                cameraReference: CameraPhotoReference(cameraID: cameraID, groupKey: groupKey, assets: [])
            )

            let cameraAsset = CameraAssetReference(
                identifier: asset.identifier,
                filename: URL(fileURLWithPath: asset.filename).lastPathComponent,
                variant: asset.variant,
                fileSize: asset.fileSize,
                captureDate: asset.captureDate
            )
            let existingAssets = group.cameraReference?.assets ?? []
            var assets = existingAssets.filter { $0.variant != asset.variant }
            assets.append(cameraAsset)
            group.cameraReference = CameraPhotoReference(cameraID: cameraID, groupKey: groupKey, assets: assets)
            if let date = asset.captureDate,
               group.captureDate == nil || date < group.captureDate! {
                group.captureDate = date
                group.metadata.captureDate = date
            }
            groupsByKey[groupKey] = group
        }

        var result = groupsByKey.values.sorted {
            let lhsDate = $0.captureDate ?? .distantFuture
            let rhsDate = $1.captureDate ?? .distantFuture
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            let basenameOrder = $0.basename.localizedStandardCompare($1.basename)
            if basenameOrder != .orderedSame { return basenameOrder == .orderedAscending }
            return $0.id < $1.id
        }
        for index in result.indices {
            result[index].presentationOrder = index
        }
        return result
    }

    private static func remotePathWithoutExtension(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().path
    }

    private static func cameraDirectoryURL(cameraID: String, remotePath: String) -> URL {
        let directoryComponents = URL(fileURLWithPath: remotePath)
            .deletingLastPathComponent()
            .pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
        var result = URL(fileURLWithPath: "/__photokichin_camera__")
            .appendingPathComponent(safePathComponent(cameraID), isDirectory: true)
        for component in directoryComponents {
            result.appendPathComponent(component, isDirectory: true)
        }
        return result
    }
}

/// Owns the ImageCaptureCore browser and the live ICCameraFile objects. A
/// camera is a PTP device, not a filesystem volume, so this is intentionally
/// separate from VolumeMonitor and PhotoScanner.
@MainActor
final class CameraMonitor: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICDeviceDelegate, ICCameraDeviceDelegate {
    static let shared = CameraMonitor()
    private static let catalogRefreshInterval = CameraCatalogRefreshGate.interval

    @Published private(set) var cameras: [CameraDescriptor] = []
    private let browser = ICDeviceBrowser()
    private let logger = Logger(subsystem: "jp.yappo.Photokichin", category: "camera-io")
    private var records: [String: CameraRecord] = [:]
    private var catalogTraces: [String: CatalogTrace] = [:]
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
        var usbInfo: CameraUSBInfo
        var catalogProgressTask: Task<Void, Never>?
        var catalogRefreshNextAllowedAt: Date?
        var catalogRefreshInFlight = false
        var catalogUpdateStartedAt: Date?
        var catalogUpdateFinishedAt: Date?
        var catalogCompletionEventAt: Date?
        var catalogRefreshAcceptedCount = 0
        var catalogRefreshIgnoredCount = 0

        init(device: ICCameraDevice, descriptor: CameraDescriptor) {
            self.device = device
            self.sessionRequestedAt = Date()
            self.descriptor = descriptor
            self.usbInfo = CameraUSBInfo.read(for: device)
        }
    }

    private struct CatalogTrace {
        var totalCallbacks = 0
        var totalItems = 0
        var totalFileBytes: Int64 = 0
        var windowCallbacks = 0
        var windowItems = 0
        var windowFileBytes: Int64 = 0
        var windowStartedAt: Date?
        var lastReportedAt: Date?
        var firstInputAt: Date?
        var lastInputAt: Date?
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
        }
        for record in records.values where record.device.hasOpenSession {
            record.device.requestCloseSession()
        }
        records.removeAll()
        catalogTraces.removeAll()
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
                    self.logger.notice(
                        "camera_io session_open_error elapsed_seconds=\(Date().timeIntervalSince(record.sessionRequestedAt), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.updateState(for: record, state: .failed(error.localizedDescription))
                }
                self.onError?("カメラを開けませんでした: \(error.localizedDescription)")
            } else if let camera = device as? ICCameraDevice,
                      let record = self.record(for: device) {
                self.logger.notice(
                    "camera_io session_opened elapsed_seconds=\(Date().timeIntervalSince(record.sessionRequestedAt), privacy: .public) has_open_session=\(camera.hasOpenSession ? 1 : 0, privacy: .public) catalog_percent=\(Int(camera.contentCatalogPercentCompleted), privacy: .public)"
                )
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
        let receivedAt = Date()
        Task { @MainActor [weak self] in
            guard let self, let record = self.record(for: device) else { return }
            self.flushCatalogInput(for: device)
            let summaryStartedAt = Date()
            var summary = CameraCatalogSummary()
            for file in (device.mediaFiles ?? []).compactMap({ $0 as? ICCameraFile }) {
                summary.add(file)
            }
            let summaryScanElapsed = Date().timeIntervalSince(summaryStartedAt)
            CameraRequestGate.shared.logSessionReady(
                elapsed: receivedAt.timeIntervalSince(record.sessionRequestedAt),
                mediaFileCount: device.mediaFiles?.count ?? 0,
                catalogPercent: Int(device.contentCatalogPercentCompleted),
                summary: summary,
                usb: record.usbInfo,
                summaryScanElapsed: summaryScanElapsed
            )
            self.catalogReady(device, eventReceivedAt: receivedAt)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        let receivedAt = Date()
        Task { @MainActor [weak self] in
            guard let self, self.record(for: camera) != nil else { return }
            self.traceCatalogInput(for: camera, items: items, receivedAt: receivedAt)
            self.handleCatalogRefreshTrigger(
                for: camera,
                receivedAt: receivedAt,
                kind: "did_add"
            )
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        let receivedAt = Date()
        Task { @MainActor [weak self] in
            guard let self, let record = self.record(for: camera),
                  record.descriptor.connectionState == .ready else { return }
            self.handleCatalogRefreshTrigger(
                for: camera,
                receivedAt: receivedAt,
                kind: "did_remove"
            )
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        let receivedAt = Date()
        Task { @MainActor [weak self] in
            guard let self, let record = self.record(for: camera),
                  record.descriptor.connectionState == .ready else { return }
            self.handleCatalogRefreshTrigger(
                for: camera,
                receivedAt: receivedAt,
                kind: "did_rename"
            )
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
        catalogTraces[id] = CatalogTrace()
        logger.notice(
            "camera_io session_requested camera_id=\(id, privacy: .public) usb_vendor_id=\(camera.usbVendorID, privacy: .public) usb_product_id=\(camera.usbProductID, privacy: .public) usb_location_id=\(camera.usbLocationID, privacy: .public) usb_speed=\(record.usbInfo.speed, privacy: .public) usb_probe_elapsed_ms=\(record.usbInfo.probeElapsed * 1000, privacy: .public)"
        )
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
        catalogTraces.removeValue(forKey: id)
        record.catalogProgressTask?.cancel()
        CameraThumbnailCoordinator.shared.removeCamera(id: id)
        publishDescriptors()
        onCameraRemoved?(id)
    }

    private func catalogReady(_ camera: ICCameraDevice, eventReceivedAt: Date) {
        let id = cameraIdentifier(camera)
        guard let record = records[id] else { return }
        guard record.descriptor.connectionState != .ready else { return }
        record.catalogCompletionEventAt = eventReceivedAt
        record.catalogRefreshNextAllowedAt = Date().addingTimeInterval(Self.catalogRefreshInterval)
        record.catalogRefreshInFlight = true
        logger.notice(
            "camera_io catalog_refresh kind=complete action=accepted final=1 accepted=\(record.catalogRefreshAcceptedCount, privacy: .public) ignored=\(record.catalogRefreshIgnoredCount, privacy: .public) interval_seconds=\(Self.catalogRefreshInterval, privacy: .public)"
        )
        updateCatalog(for: camera, isComplete: true, triggerReceivedAt: eventReceivedAt)
        record.catalogRefreshInFlight = false
    }

    private func handleCatalogRefreshTrigger(
        for camera: ICCameraDevice,
        receivedAt: Date,
        kind: String
    ) {
        // This is a leading-edge event gate: accept one trigger, then ignore
        // triggers for five seconds. There is deliberately no timer that
        // performs a refresh by itself. A trigger received while the current
        // catalog/list replacement is running is also discarded, even when
        // the five-second interval has already elapsed.
        let id = cameraIdentifier(camera)
        guard let record = records[id] else { return }

        switch record.descriptor.connectionState {
        case .openingSession, .cataloging, .ready:
            break
        default:
            return
        }

        switch CameraCatalogRefreshGate.decision(
            receivedAt: receivedAt,
            completionEventAt: record.catalogCompletionEventAt,
            updateInFlight: record.catalogRefreshInFlight,
            updateStartedAt: record.catalogUpdateStartedAt,
            updateFinishedAt: record.catalogUpdateFinishedAt,
            nextAllowedAt: record.catalogRefreshNextAllowedAt
        ) {
        case .accepted:
            break
        case let .ignored(reason):
            logIgnoredCatalogRefresh(record: record, kind: kind, reason: reason)
            return
        }

        record.catalogRefreshAcceptedCount += 1
        let acceptedAt = Date()
        record.catalogRefreshNextAllowedAt = acceptedAt.addingTimeInterval(Self.catalogRefreshInterval)
        record.catalogRefreshInFlight = true
        logger.notice(
            "camera_io catalog_refresh kind=\(kind, privacy: .public) action=accepted accepted=\(record.catalogRefreshAcceptedCount, privacy: .public) ignored=\(record.catalogRefreshIgnoredCount, privacy: .public) interval_seconds=\(Self.catalogRefreshInterval, privacy: .public)"
        )
        updateCatalog(for: camera, isComplete: false, triggerReceivedAt: receivedAt)
        record.catalogRefreshInFlight = false
    }

    private func logIgnoredCatalogRefresh(
        record: CameraRecord,
        kind: String,
        reason: String
    ) {
        record.catalogRefreshIgnoredCount += 1
        let ignoredCount = record.catalogRefreshIgnoredCount
        guard ignoredCount <= 3 || ignoredCount.isMultiple(of: 1000) else { return }
        logger.notice(
            "camera_io catalog_refresh kind=\(kind, privacy: .public) action=ignored reason=\(reason, privacy: .public) accepted=\(record.catalogRefreshAcceptedCount, privacy: .public) ignored=\(ignoredCount, privacy: .public)"
        )
    }

    private func updateCatalog(
        for camera: ICCameraDevice,
        isComplete: Bool,
        triggerReceivedAt: Date
    ) {
        let id = cameraIdentifier(camera)
        guard let record = records[id] else { return }
        let startedAt = Date()
        record.catalogUpdateStartedAt = startedAt
        record.catalogUpdateFinishedAt = nil
        logger.notice(
            "camera_io catalog_update_begin complete=\(isComplete ? 1 : 0, privacy: .public) trigger_to_begin_ms=\(startedAt.timeIntervalSince(triggerReceivedAt) * 1000, privacy: .public) media_files=\(camera.mediaFiles?.count ?? 0, privacy: .public) previous_groups=\(record.groups.count, privacy: .public)"
        )

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

        let announcedFileBytes = catalogTraces[id]?.totalFileBytes ?? 0
        logger.notice(
            "camera_io catalog_update_input complete=\(isComplete ? 1 : 0, privacy: .public) media_files=\(files.count, privacy: .public) announced_file_bytes=\(announcedFileBytes, privacy: .public)"
        )

        var fileIndex: [String: ICCameraFile] = [:]
        for file in files {
            guard let filename = file.originalFilename ?? file.name,
                  variant(for: filename) != nil else { continue }
            let remotePath = remotePath(for: file, filename: filename)
            let assetIdentifier = assetIdentifier(for: file, remotePath: remotePath)
            fileIndex[assetIdentifier] = file
        }

        let entries = files.compactMap { file -> CameraCatalogEntry? in
            guard let filename = file.originalFilename ?? file.name,
                  let assetVariant = variant(for: filename) else { return nil }
            let assetRemotePath = remotePath(for: file, filename: filename)
            let assetID = assetIdentifier(for: file, remotePath: assetRemotePath)
            let asset = CameraCatalogAsset(
                identifier: assetID,
                filename: filename,
                remotePath: assetRemotePath,
                variant: assetVariant,
                fileSize: Int64(file.fileSize),
                captureDate: file.creationDate as Date?,
                width: file.width,
                height: file.height
            )
            let pairedRaw = file.pairedRawImage.flatMap { raw -> CameraCatalogAsset? in
                guard let rawFilename = raw.originalFilename ?? raw.name,
                      let rawVariant = variant(for: rawFilename) else { return nil }
                let rawPath = self.remotePath(for: raw, filename: rawFilename)
                return CameraCatalogAsset(
                    identifier: assetIdentifier(for: raw, remotePath: rawPath),
                    filename: rawFilename,
                    remotePath: rawPath,
                    variant: rawVariant,
                    fileSize: Int64(raw.fileSize),
                    captureDate: raw.creationDate as Date?,
                    width: raw.width,
                    height: raw.height
                )
            }
            return CameraCatalogEntry(asset: asset, pairedRaw: pairedRaw)
        }

        // Each accepted trigger publishes a complete replacement snapshot.
        // CameraCatalogBuilder also recomputes the stable order and removes
        // groups absent from this current mediaFiles snapshot.
        let groups = CameraCatalogBuilder.groups(
            cameraID: id,
            cameraName: camera.name,
            entries: entries,
            previousGroups: record.groups
        )
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
        let finishedAt = Date()
        record.catalogUpdateFinishedAt = finishedAt
        logger.notice(
            "camera_io catalog_update_end complete=\(isComplete ? 1 : 0, privacy: .public) trigger_to_end_ms=\(finishedAt.timeIntervalSince(triggerReceivedAt) * 1000, privacy: .public) groups=\(groups.count, privacy: .public) files=\(files.count, privacy: .public) announced_file_bytes=\(announcedFileBytes, privacy: .public) elapsed_ms=\(finishedAt.timeIntervalSince(startedAt) * 1000, privacy: .public)"
        )
    }

    private func traceCatalogInput(for camera: ICCameraDevice, items: [ICCameraItem], receivedAt: Date) {
        let id = cameraIdentifier(camera)
        var trace = catalogTraces[id, default: CatalogTrace()]
        let now = receivedAt
        if trace.windowStartedAt == nil { trace.windowStartedAt = receivedAt }
        if trace.firstInputAt == nil { trace.firstInputAt = receivedAt }
        trace.lastInputAt = receivedAt
        let inputFileBytes = CameraCatalogSummary.fileBytes(in: items)
        trace.totalCallbacks += 1
        trace.totalItems += items.count
        trace.totalFileBytes += inputFileBytes
        trace.windowCallbacks += 1
        trace.windowItems += items.count
        trace.windowFileBytes += inputFileBytes

        let shouldReport = trace.lastReportedAt == nil
            || now.timeIntervalSince(trace.lastReportedAt!) >= 1
        if shouldReport {
            let windowSeconds = now.timeIntervalSince(trace.windowStartedAt ?? now)
            let sessionSeconds = record(for: camera).map { now.timeIntervalSince($0.sessionRequestedAt) } ?? 0
            let firstInputSeconds = now.timeIntervalSince(trace.firstInputAt ?? now)
            let windowBytesPerSecond = windowSeconds > 0 ? Double(trace.windowFileBytes) / windowSeconds : 0
            let sessionBytesPerSecond = sessionSeconds > 0 ? Double(trace.totalFileBytes) / sessionSeconds : 0
            let streamBytesPerSecond = firstInputSeconds > 0 ? Double(trace.totalFileBytes) / firstInputSeconds : 0
            logger.notice(
                "camera_io catalog_input session_elapsed_seconds=\(sessionSeconds, privacy: .public) stream_elapsed_seconds=\(firstInputSeconds, privacy: .public) window_callbacks=\(trace.windowCallbacks, privacy: .public) window_items=\(trace.windowItems, privacy: .public) window_file_bytes=\(trace.windowFileBytes, privacy: .public) window_bytes_per_second=\(windowBytesPerSecond, privacy: .public) total_callbacks=\(trace.totalCallbacks, privacy: .public) total_items=\(trace.totalItems, privacy: .public) total_file_bytes=\(trace.totalFileBytes, privacy: .public) session_bytes_per_second=\(sessionBytesPerSecond, privacy: .public) stream_bytes_per_second=\(streamBytesPerSecond, privacy: .public) window_seconds=\(windowSeconds, privacy: .public) percent=\(Int(camera.contentCatalogPercentCompleted), privacy: .public)"
            )
            trace.windowCallbacks = 0
            trace.windowItems = 0
            trace.windowFileBytes = 0
            trace.windowStartedAt = now
            trace.lastReportedAt = now
        }
        catalogTraces[id] = trace
    }

    private func flushCatalogInput(for camera: ICCameraDevice) {
        let id = cameraIdentifier(camera)
        guard var trace = catalogTraces[id], trace.windowCallbacks > 0 else { return }
        let now = Date()
        let lastInputAt = trace.lastInputAt ?? now
        let windowSeconds = now.timeIntervalSince(trace.windowStartedAt ?? now)
        let sessionSeconds = record(for: camera).map { lastInputAt.timeIntervalSince($0.sessionRequestedAt) } ?? 0
        let firstInputSeconds = lastInputAt.timeIntervalSince(trace.firstInputAt ?? lastInputAt)
        let inputToFlushMilliseconds = now.timeIntervalSince(lastInputAt) * 1000
        let windowBytesPerSecond = windowSeconds > 0 ? Double(trace.windowFileBytes) / windowSeconds : 0
        let sessionBytesPerSecond = sessionSeconds > 0 ? Double(trace.totalFileBytes) / sessionSeconds : 0
        let streamBytesPerSecond = firstInputSeconds > 0 ? Double(trace.totalFileBytes) / firstInputSeconds : 0
        logger.notice(
            "camera_io catalog_input_final session_elapsed_seconds=\(sessionSeconds, privacy: .public) stream_elapsed_seconds=\(firstInputSeconds, privacy: .public) input_to_flush_ms=\(inputToFlushMilliseconds, privacy: .public) window_callbacks=\(trace.windowCallbacks, privacy: .public) window_items=\(trace.windowItems, privacy: .public) window_file_bytes=\(trace.windowFileBytes, privacy: .public) window_bytes_per_second=\(windowBytesPerSecond, privacy: .public) total_callbacks=\(trace.totalCallbacks, privacy: .public) total_items=\(trace.totalItems, privacy: .public) total_file_bytes=\(trace.totalFileBytes, privacy: .public) session_bytes_per_second=\(sessionBytesPerSecond, privacy: .public) stream_bytes_per_second=\(streamBytesPerSecond, privacy: .public) window_seconds=\(windowSeconds, privacy: .public) percent=\(Int(camera.contentCatalogPercentCompleted), privacy: .public)"
        )
        trace.windowCallbacks = 0
        trace.windowItems = 0
        trace.windowFileBytes = 0
        trace.windowStartedAt = now
        trace.lastReportedAt = now
        catalogTraces[id] = trace
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
        CameraCatalogBuilder.variant(for: filename)
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

    private func assetIdentifier(for file: ICCameraFile, remotePath: String) -> String {
        if file.ptpObjectHandle != 0 {
            return "handle:\(file.ptpObjectHandle)"
        }
        return "path:\(remotePath)"
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
