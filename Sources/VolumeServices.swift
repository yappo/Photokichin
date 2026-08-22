import AppKit
import DiskArbitration
import Foundation

@MainActor
protocol VolumeMonitoring: AnyObject {
    var volumes: [MountedVolume] { get }
    var onMount: ((MountedVolume) -> Void)? { get set }
    var onUnmount: ((URL) -> Void)? { get set }

    func refresh()
}

@MainActor
final class VolumeMonitor: ObservableObject, VolumeMonitoring {
    @Published private(set) var volumes: [MountedVolume] = []
    var onMount: ((MountedVolume) -> Void)?
    var onUnmount: ((URL) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                guard let volume = self.volumes.first(where: { $0.name == "EOS_DIGITAL" }) else { return }
                self.onMount?(volume)
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] notification in
            guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
                Task { @MainActor in self?.refresh() }
                return
            }
            Task { @MainActor in
                self?.refresh()
                self?.onUnmount?(volumeURL)
            }
        })
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        volumes = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsRemovable == true || values?.volumeIsEjectable == true else { return nil }
            return MountedVolume(
                id: url.path,
                url: url,
                name: values?.volumeName ?? url.lastPathComponent,
                isRemovable: values?.volumeIsRemovable ?? false,
                isEjectable: values?.volumeIsEjectable ?? false,
                volumeUUID: VolumeIdentityReader.volumeUUID(for: url)
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum VolumeIdentityReader {
    static func volumeUUID(for volumeURL: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let value = description[kDADiskDescriptionVolumeUUIDKey as String] else {
            return nil
        }

        if let uuid = value as? UUID { return uuid.uuidString.lowercased() }
        if let uuid = value as? NSUUID { return uuid.uuidString.lowercased() }
        if let uuid = value as? String { return uuid.lowercased() }
        if CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() {
            let uuid = unsafeBitCast(value as CFTypeRef, to: CFUUID.self)
            return (CFUUIDCreateString(nil, uuid) as String).lowercased()
        }
        return nil
    }
}

private final class DiskOperationResult {
    var error: Error?
}

private func diskOperationError(_ dissenter: DADissenter, operation: String) -> Error {
    let status = DADissenterGetStatus(dissenter)
    let statusCode = String(format: "0x%08X", UInt32(bitPattern: status))
    let statusString = (DADissenterGetStatusString(dissenter) as String?) ?? "理由不明"
    return AppError.ejectFailed("\(operation)がDisk Arbitrationに拒否されました（\(statusCode): \(statusString)）")
}

private func diskUnmountCallback(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let result = Unmanaged<DiskOperationResult>.fromOpaque(context).takeRetainedValue()
    if let dissenter {
        result.error = diskOperationError(dissenter, operation: "アンマウント")
    }
    CFRunLoopStop(CFRunLoopGetCurrent())
}

private func diskEjectCallback(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let result = Unmanaged<DiskOperationResult>.fromOpaque(context).takeRetainedValue()
    if let dissenter {
        result.error = diskOperationError(dissenter, operation: "Eject")
    }
    CFRunLoopStop(CFRunLoopGetCurrent())
}

enum VolumeEjector {
    static func eject(volumeURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try performEject(volumeURL: volumeURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func performEject(volumeURL: URL) throws {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL) else {
            throw AppError.ejectFailed("ボリュームを取得できませんでした")
        }

        // The volume path resolves to the mounted partition (for example
        // diskXsY). Unmount that partition explicitly first, then eject the
        // associated physical disk. This is important for removable volumes
        // whose filesystem driver does not complete the implicit unmount made
        // by DADiskEject.
        let ejectDisk = DADiskCopyWholeDisk(disk) ?? disk

        DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let unmountResult = DiskOperationResult()
        let unmountContext = Unmanaged.passRetained(unmountResult).toOpaque()
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), diskUnmountCallback, unmountContext)
        CFRunLoopRun()
        if let error = unmountResult.error {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            throw error
        }

        let ejectResult = DiskOperationResult()
        let ejectContext = Unmanaged.passRetained(ejectResult).toOpaque()
        DADiskEject(ejectDisk, DADiskEjectOptions(kDADiskEjectOptionDefault), diskEjectCallback, ejectContext)
        CFRunLoopRun()
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        if let error = ejectResult.error { throw error }
    }
}
