import AppKit
import CryptoKit
import Darwin
import Foundation

final class ImportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

final class FileTransferService {
    typealias CopyFileOperation = @Sendable (
        URL,
        URL,
        ImportCancellationToken?,
        Bool
    ) throws -> Bool

    static let shared = FileTransferService()
    private let copyFileOperation: CopyFileOperation?

    init(copyFileOperation: CopyFileOperation? = nil) {
        self.copyFileOperation = copyFileOperation
    }

    final class AirDropSession: NSObject, NSSharingServiceDelegate {
        let service: NSSharingService
        private let completion: (Error?) -> Void
        private let lock = NSLock()
        private var finished = false

        init(service: NSSharingService, completion: @escaping (Error?) -> Void) {
            self.service = service
            self.completion = completion
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finish(with: nil)
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            finish(with: error)
        }

        private func finish(with error: Error?) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            completion(error)
        }
    }

    struct TrashBatchResult: Sendable {
        let completedGroupIDs: Set<String>
        let movedFileCount: Int
        let failedFileCount: Int
        let errorMessage: String?
    }

    private struct RecycleResult: Sendable {
        let movedPaths: Set<String>
        let errorMessage: String?
    }

    func importGroup(
        _ group: PhotoGroup,
        to libraryRoot: URL,
        template: String,
        catalog: CatalogStore,
        cancellation: ImportCancellationToken? = nil,
        sourceRoot: URL? = nil,
        volumeUUID: String? = nil
    ) throws -> ImportResult {
        try cancellation?.check()
        let date = group.metadata.captureDate ?? group.captureDate ?? Date()
        let camera = sanitizedFileComponent(group.metadata.cameraModel ?? "EOS R")
        let folderName = makeFolderName(template: template, date: date, camera: camera)
        let destinationDirectory = libraryRoot.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var copied = 0
        var skipped = 0
        var failed = 0
        var messages: [String] = []
        var catalogRecords: [CatalogImportRecord] = []

        for (variant, sourceURL) in [(AssetVariant.jpeg, group.jpegURL), (AssetVariant.raw, group.rawURL)].compactMap({ variant, url in url.map { (variant, $0) } }) {
            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            do {
                try cancellation?.check()
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    if try fileSize(sourceURL) != fileSize(destinationURL) {
                        throw AppError.copyConflict(destinationURL)
                    }
                    let sourceHash = try sha256(sourceURL, cancellation: cancellation)
                    let destinationHash = try sha256(destinationURL, cancellation: cancellation)
                    if sourceHash == destinationHash {
                        // The data is already identical. Refresh the destination's
                        // filesystem metadata without needlessly rewriting the photo.
                        try copyFileMetadata(from: sourceURL, to: destinationURL, cancellation: cancellation)
                        try restoreFileTimestamps(from: sourceURL, to: destinationURL)
                        catalogRecords.append(catalogRecord(
                            group: group,
                            sourceURL: sourceURL,
                            variant: variant,
                            destinationURL: destinationURL,
                            sha256: sourceHash,
                            fileSize: try fileSize(sourceURL),
                            sourceRoot: sourceRoot,
                            volumeUUID: volumeUUID
                        ))
                        skipped += 1
                        continue
                    }
                    throw AppError.copyConflict(destinationURL)
                }

                let partialURL = destinationDirectory.appendingPathComponent(".photokichin-partial-\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
                defer { try? FileManager.default.removeItem(at: partialURL) }
                // Hash the source before the system copy so the destination can
                // be verified after COPYFILE_ALL has copied both data and metadata.
                let sourceHash = try sha256(sourceURL, cancellation: cancellation)
                _ = try copyFileAll(from: sourceURL, to: partialURL, cancellation: cancellation)
                // Some removable filesystems do not expose a creation date that
                // copyfile can restore on the destination filesystem. Set the two
                // user-visible dates explicitly after COPYFILE_ALL.
                try restoreFileTimestamps(from: sourceURL, to: partialURL)
                guard try sha256(partialURL, cancellation: cancellation) == sourceHash else {
                    throw AppError.transferFailed(sourceURL, NSError(domain: "Photokichin", code: 1, userInfo: [NSLocalizedDescriptionKey: "SHA-256検証に失敗しました"]))
                }
                try cancellation?.check()
                try FileManager.default.moveItem(at: partialURL, to: destinationURL)
                catalogRecords.append(catalogRecord(
                    group: group,
                    sourceURL: sourceURL,
                    variant: variant,
                    destinationURL: destinationURL,
                    sha256: sourceHash,
                    fileSize: try fileSize(sourceURL),
                    sourceRoot: sourceRoot,
                    volumeUUID: volumeUUID
                ))
                copied += 1
            } catch {
                if error is CancellationError {
                    if !catalogRecords.isEmpty { try? catalog.recordImports(catalogRecords) }
                    throw error
                }
                failed += 1
                messages.append(error.localizedDescription)
            }
        }

        do {
            try catalog.recordImports(catalogRecords)
        } catch {
            failed += catalogRecords.count
            messages.append(error.localizedDescription)
        }

        let message = messages.isEmpty ? "\(group.basename): \(copied)件コピー、\(skipped)件スキップ" : "\(group.basename): \(messages.joined(separator: " / "))"
        return ImportResult(groupID: group.id, message: message, copiedCount: copied, skippedCount: skipped, failedCount: failed)
    }

    /// Verifies and installs a camera download that was written directly into
    /// the destination library directory under a hidden partial filename.
    /// Moving within that directory avoids a second full-file copy. This is
    /// intentionally separate from the removable-volume import path.
    func installCameraDownloadedFile(
        partialURL: URL,
        destinationURL: URL,
        variant: AssetVariant,
        sourceKey: String,
        sourceFilename: String?,
        catalog: CatalogStore,
        expectedFileSize: Int64,
        cancellation: ImportCancellationToken?
    ) throws -> Bool {
        try cancellation?.check()
        guard FileManager.default.fileExists(atPath: partialURL.path) else {
            throw AppError.transferFailed(partialURL, NSError(
                domain: "Photokichin.Camera",
                code: 40,
                userInfo: [NSLocalizedDescriptionKey: "カメラからダウンロードした一時ファイルが見つかりません"]
            ))
        }
        guard try fileSize(partialURL) == expectedFileSize else {
            throw AppError.transferFailed(partialURL, NSError(
                domain: "Photokichin.Camera",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "カメラからのダウンロードサイズを検証できません"]
            ))
        }

        let partialHash = try sha256(partialURL, cancellation: cancellation)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard try fileSize(destinationURL) == expectedFileSize,
                  try sha256(destinationURL, cancellation: cancellation) == partialHash else {
                throw AppError.copyConflict(destinationURL)
            }
            try FileManager.default.removeItem(at: partialURL)
            try catalog.recordImports([CatalogImportRecord(
                sourceKey: sourceKey,
                variant: variant,
                destinationURL: destinationURL,
                sha256: partialHash,
                fileSize: expectedFileSize,
                sourceFilename: sourceFilename
            )])
            return false
        }

        if let existingURL = catalog.existingContentDestination(
            sha256: partialHash,
            variant: variant,
            fileSize: expectedFileSize
        ) {
            try cancellation?.check()
            try FileManager.default.removeItem(at: partialURL)
            try catalog.recordImports([CatalogImportRecord(
                sourceKey: sourceKey,
                variant: variant,
                destinationURL: existingURL,
                sha256: partialHash,
                fileSize: expectedFileSize,
                sourceFilename: sourceFilename
            )])
            return false
        }

        try cancellation?.check()
        try FileManager.default.moveItem(at: partialURL, to: destinationURL)
        try catalog.recordImports([CatalogImportRecord(
            sourceKey: sourceKey,
            variant: variant,
            destinationURL: destinationURL,
            sha256: partialHash,
            fileSize: expectedFileSize,
            sourceFilename: sourceFilename
        )])
        return true
    }

    func copyLibraryGroup(
        _ group: PhotoGroup,
        from sourceLibrary: URL,
        to destinationLibrary: URL,
        sourceCatalog: CatalogStore?,
        destinationCatalog: CatalogStore,
        copyLabels: Bool = true,
        cancellation: ImportCancellationToken? = nil
    ) throws -> ImportResult {
        try cancellation?.check()
        let relativeDirectory = relativeDirectoryPath(group.directory, from: sourceLibrary)
        let destinationDirectory = relativeDirectory.isEmpty
            ? destinationLibrary
            : destinationLibrary.appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let sourceURLForCapabilities = group.jpegURL ?? group.rawURL
        let capabilities = sourceURLForCapabilities.map {
            copyCapabilities(sourceURL: $0, destinationRoot: destinationLibrary)
        } ?? CopyCapabilities(sameVolume: false, supportsCloning: false)
        let preferClone = capabilities.sameVolume && capabilities.supportsCloning
        let verifyWithSHA256 = !capabilities.sameVolume
        let transferablePhotoID = group.photoID ?? group.primaryURL.flatMap { sourceCatalog?.photoID(for: $0) }

        var copied = 0
        var skipped = 0
        var failed = 0
        var cloneCount = 0
        var messages: [String] = []

        for (variant, sourceURL) in [(AssetVariant.jpeg, group.jpegURL), (AssetVariant.raw, group.rawURL)].compactMap({ variant, url in url.map { (variant, $0) } }) {
            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            do {
                try cancellation?.check()
                let sourceRecord = sourceCatalog?.contentRecord(for: sourceURL, variant: variant)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    let expectedHash: String
                    if let hash = sourceRecord?.sha256, !hash.isEmpty {
                        expectedHash = hash
                    } else {
                        expectedHash = try sha256(sourceURL, cancellation: cancellation)
                    }
                    let destinationHash = try sha256(destinationURL, cancellation: cancellation)
                    guard destinationHash == expectedHash else { throw AppError.copyConflict(destinationURL) }
                    try destinationCatalog.recordLibraryAsset(
                        url: destinationURL,
                        variant: variant,
                        sha256: expectedHash,
                        fileSize: try fileSize(sourceURL),
                        preferredPhotoID: transferablePhotoID
                    )
                    skipped += 1
                    continue
                }

                let partialURL = destinationDirectory.appendingPathComponent(".photokichin-partial-\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
                defer { try? FileManager.default.removeItem(at: partialURL) }
                let usedClone = try copyFileAll(from: sourceURL, to: partialURL, cancellation: cancellation, preferClone: preferClone)
                try restoreFileTimestamps(from: sourceURL, to: partialURL)

                var storedHash = sourceRecord?.sha256 ?? ""
                if verifyWithSHA256 {
                    let expectedHash = storedHash.isEmpty
                        ? try sha256(sourceURL, cancellation: cancellation)
                        : storedHash
                    guard try sha256(partialURL, cancellation: cancellation) == expectedHash else {
                        throw AppError.transferFailed(sourceURL, NSError(domain: "Photokichin", code: 11, userInfo: [NSLocalizedDescriptionKey: "ライブラリ間コピーのSHA-256検証に失敗しました"]))
                    }
                    storedHash = expectedHash
                }
                try cancellation?.check()
                try FileManager.default.moveItem(at: partialURL, to: destinationURL)
                try destinationCatalog.recordLibraryAsset(
                    url: destinationURL,
                    variant: variant,
                    sha256: storedHash,
                    fileSize: try fileSize(sourceURL),
                    preferredPhotoID: transferablePhotoID
                )
                copied += 1
                if usedClone { cloneCount += 1 }
            } catch {
                if error is CancellationError { throw error }
                failed += 1
                messages.append(error.localizedDescription)
            }
        }

        if copyLabels, failed == 0,
           let sourceCatalog,
           let sourcePhotoID = transferablePhotoID,
           let destinationURL = group.primaryURL.map({ sourceURL in
               destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
           }),
           let destinationPhotoID = destinationCatalog.photoID(for: destinationURL) {
            // The transfer descriptor contains no source label UUID. The
            // destination catalog resolves names to its own UUID namespace.
            let transferredLabels = sourceCatalog.transferredLabels(for: sourcePhotoID)
            do {
                try destinationCatalog.applyTransferredLabels(transferredLabels, to: destinationPhotoID)
            } catch {
                failed += 1
                messages.append("写真コピー済み・ラベル未反映: \(error.localizedDescription)")
            }
        }

        let mode = cloneCount > 0 ? "（APFSクローン\(cloneCount)件）" : ""
        let message = messages.isEmpty
            ? "\(group.basename): \(copied)件コピー、\(skipped)件スキップ\(mode)"
            : "\(group.basename): \(messages.joined(separator: " / "))"
        return ImportResult(groupID: group.id, message: message, copiedCount: copied, skippedCount: skipped, failedCount: failed)
    }

    func moveGroupToTrash(_ group: PhotoGroup) throws {
        let urls = [group.jpegURL, group.rawURL].compactMap { $0 }
        guard !urls.isEmpty else { throw AppError.noSelectedPhotos }
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                throw AppError.transferFailed(url, error)
            }
        }
    }

    func moveGroupsToTrash(
        _ groups: [PhotoGroup],
        onProgress: (@Sendable (Int, Int, Int, Int) -> Void)? = nil
    ) async -> TrashBatchResult {
        let totalFileCount = groups.reduce(0) { count, group in
            count + [group.jpegURL, group.rawURL].compactMap { $0 }.count
        }
        guard totalFileCount > 0 else {
            return TrashBatchResult(completedGroupIDs: [], movedFileCount: 0, failedFileCount: 0, errorMessage: nil)
        }

        var movedPaths = Set<String>()
        var completedGroupIDs = Set<String>()
        var errorMessages: [String] = []

        // NSWorkspace reports only one completion for a recycle request. Recycle
        // one JPG+CR3 group at a time so the UI can show real completed counts
        // while still making one OS call instead of one call per file.
        for (index, group) in groups.enumerated() {
            let groupURLs = [group.jpegURL, group.rawURL].compactMap { $0 }
            if groupURLs.isEmpty {
                errorMessages.append("\(group.basename): ゴミ箱へ移動できる写真ファイルがありません")
                onProgress?(index + 1, groups.count, movedPaths.count, totalFileCount)
                continue
            }

            let result = await recycle(groupURLs)
            movedPaths.formUnion(result.movedPaths)
            if groupURLs.allSatisfy({ movedPaths.contains($0.standardizedFileURL.path) }) {
                completedGroupIDs.insert(group.id)
            }
            if let errorMessage = result.errorMessage {
                errorMessages.append("\(group.basename): \(errorMessage)")
            }
            onProgress?(index + 1, groups.count, movedPaths.count, totalFileCount)
        }

        return TrashBatchResult(
            completedGroupIDs: completedGroupIDs,
            movedFileCount: movedPaths.count,
            failedFileCount: max(0, totalFileCount - movedPaths.count),
            errorMessage: errorMessages.isEmpty ? nil : errorMessages.joined(separator: " / ")
        )
    }

    private func recycle(_ urls: [URL]) async -> RecycleResult {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { newURLs, error in
                continuation.resume(returning: RecycleResult(
                    movedPaths: Set(newURLs.keys.map { $0.standardizedFileURL.path }),
                    errorMessage: error?.localizedDescription
                ))
            }
        }
    }

    @discardableResult
    func airDrop(
        _ groups: [PhotoGroup],
        mode: AirDropMode,
        onCompletion: @escaping (Error?) -> Void = { _ in }
    ) throws -> AirDropSession {
        let urls = urlsForAirDrop(groups, mode: mode)
        guard !urls.isEmpty else { throw AppError.noSelectedPhotos }
        guard let unavailableURL = urls.first(where: { !FileManager.default.isReadableFile(atPath: $0.path) }) else {
            return try performAirDrop(urls: urls, onCompletion: onCompletion)
        }
        throw AppError.transferFailed(
            unavailableURL,
            NSError(
                domain: "Photokichin",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "AirDropする元ファイルを読み取れません。一覧を更新してから再試行してください"]
            )
        )
    }

    private func performAirDrop(
        urls: [URL],
        onCompletion: @escaping (Error?) -> Void
    ) throws -> AirDropSession {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            throw AppError.transferFailed(urls[0], NSError(domain: "Photokichin", code: 2, userInfo: [NSLocalizedDescriptionKey: "AirDropを利用できません"]))
        }
        let session = AirDropSession(service: service, completion: onCompletion)
        service.delegate = session
        service.perform(withItems: urls)
        return session
    }

    func urlsForAirDrop(_ groups: [PhotoGroup], mode: AirDropMode) -> [URL] {
        groups.flatMap { group -> [URL] in
            switch mode {
            case .jpegAndRaw: return [group.jpegURL, group.rawURL].compactMap { $0 }
            case .jpegOnly: return [group.jpegURL].compactMap { $0 }
            case .rawOnly: return [group.rawURL].compactMap { $0 }
            }
        }
    }

    func sourceKey(
        for group: PhotoGroup,
        variant: AssetVariant,
        sourceRoot: URL? = nil,
        volumeUUID: String? = nil
    ) -> String {
        let url: URL?
        switch variant {
        case .jpeg: url = group.jpegURL
        case .raw: url = group.rawURL
        case .movie: url = group.movieURL
        }
        guard let url else { return "\(group.id):\(variant.rawValue)" }
        return SourceIdentity.key(url: url, variant: variant, sourceRoot: sourceRoot, volumeUUID: volumeUUID)
    }

    private func catalogRecord(
        group: PhotoGroup,
        sourceURL: URL,
        variant: AssetVariant,
        destinationURL: URL,
        sha256: String,
        fileSize: Int64,
        sourceRoot: URL?,
        volumeUUID: String?
    ) -> CatalogImportRecord {
        let newKey = sourceKey(for: group, variant: variant, sourceRoot: sourceRoot, volumeUUID: volumeUUID)
        let legacyKey = SourceIdentity.legacyKey(url: sourceURL, variant: variant)
        let components = SourceIdentity.components(url: sourceURL, sourceRoot: sourceRoot, volumeUUID: volumeUUID)
        return CatalogImportRecord(
            sourceKey: newKey,
            variant: variant,
            destinationURL: destinationURL,
            sha256: sha256,
            fileSize: fileSize,
            sourceFilename: FilenameIdentity.rawFilename(for: sourceURL),
            legacySourceKey: newKey == legacyKey ? nil : legacyKey,
            sourceVolumeUUID: components?.volumeUUID,
            sourceRelativePath: components?.relativePath
        )
    }

    func makeFolderName(template: String, date: Date, camera: String) -> String {
        var name = template
        name = name.replacingOccurrences(of: "{date}", with: DateFormatters.directoryDay.string(from: date))
        name = name.replacingOccurrences(of: "{camera}", with: camera)
        return sanitizedFileComponent(name)
    }

    private func sha256(_ url: URL, cancellation: ImportCancellationToken? = nil) throws -> String {
        guard let stream = InputStream(url: url) else { throw AppError.transferFailed(url, NSError(domain: "Photokichin", code: 3, userInfo: [NSLocalizedDescriptionKey: "ファイルを開けません"])) }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            try cancellation?.check()
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { throw stream.streamError ?? AppError.transferFailed(url, NSError(domain: "Photokichin", code: 4)) }
            if count == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            throw AppError.transferFailed(url, NSError(domain: "Photokichin", code: 5, userInfo: [NSLocalizedDescriptionKey: "ファイルサイズを取得できません"]))
        }
        return Int64(fileSize)
    }

    private func copyFileAll(
        from sourceURL: URL,
        to destinationURL: URL,
        cancellation: ImportCancellationToken?,
        preferClone: Bool = false
    ) throws -> Bool {
        if let copyFileOperation {
            return try copyFileOperation(sourceURL, destinationURL, cancellation, preferClone)
        }
        try cancellation?.check()
        let state = copyfile_state_alloc()
        guard let state else {
            throw AppError.transferFailed(sourceURL, NSError(domain: "Photokichin", code: 9, userInfo: [NSLocalizedDescriptionKey: "COPYFILEの状態を初期化できませんでした"]))
        }
        defer { copyfile_state_free(state) }

        if let cancellation {
            let callback: copyfile_callback_t = { _, _, _, _, _, context in
                guard let context else { return Int32(COPYFILE_CONTINUE) }
                let token = Unmanaged<ImportCancellationToken>.fromOpaque(context).takeUnretainedValue()
                return token.isCancelled ? Int32(COPYFILE_QUIT) : Int32(COPYFILE_CONTINUE)
            }
            let callbackContext = Unmanaged.passUnretained(cancellation).toOpaque()
            // copyfile_state_set expects the callback function pointer value.
            // Passing the address of this local variable makes libcopyfile treat
            // a stack address as executable code and can crash during the copy.
            let callbackPointer = unsafeBitCast(callback, to: UnsafeRawPointer.self)
            let callbackResult = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPointer)
            let contextResult = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), callbackContext)
            guard callbackResult == 0, contextResult == 0 else {
                throw AppError.transferFailed(sourceURL, NSError(domain: "Photokichin", code: 10, userInfo: [NSLocalizedDescriptionKey: "COPYFILEの中断コールバックを設定できませんでした"]))
            }
        }
        let runCopy: (copyfile_flags_t) -> Int32 = { flags in
            sourceURL.path.withCString { sourcePath in
                destinationURL.path.withCString { destinationPath in
                    copyfile(sourcePath, destinationPath, state, flags)
                }
            }
        }
        var usedClone = false
        var flags = copyfile_flags_t(COPYFILE_ALL)
        if preferClone {
            flags |= copyfile_flags_t(COPYFILE_CLONE)
        }
        var result = runCopy(flags)
        if result != 0, preferClone, [EINVAL, ENOTSUP, EXDEV].contains(Darwin.errno) {
            try cancellation?.check()
            result = runCopy(copyfile_flags_t(COPYFILE_ALL))
        } else if result == 0, preferClone {
            usedClone = true
        }
        // COPYFILE_QUIT is reported as a failed copy. Translate that result
        // back into CancellationError so importGroup stops instead of treating
        // a user cancellation as an ordinary per-file failure.
        try cancellation?.check()
        guard result == 0 else {
            let errorCode = Darwin.errno
            throw AppError.transferFailed(
                sourceURL,
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errorCode),
                    userInfo: [NSLocalizedDescriptionKey: "COPYFILE_ALLでコピーできませんでした"]
                )
            )
        }
        try cancellation?.check()
        return usedClone
    }

    private struct CopyCapabilities {
        let sameVolume: Bool
        let supportsCloning: Bool
    }

    private func copyCapabilities(sourceURL: URL, destinationRoot: URL) -> CopyCapabilities {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeSupportsFileCloningKey]
        let sourceValues = try? sourceURL.resourceValues(forKeys: keys)
        let destinationValues = try? destinationRoot.resourceValues(forKeys: keys)
        let sourceUUID = sourceValues?.volumeUUIDString
        let destinationUUID = destinationValues?.volumeUUIDString
        let sameVolume = sourceUUID != nil && sourceUUID == destinationUUID
        let supportsCloning = sourceValues?.volumeSupportsFileCloning == true && destinationValues?.volumeSupportsFileCloning == true
        return CopyCapabilities(sameVolume: sameVolume, supportsCloning: supportsCloning)
    }

    private func relativeDirectoryPath(_ directory: URL, from root: URL) -> String {
        let directoryPath = directory.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard directoryPath != rootPath else { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard directoryPath.hasPrefix(prefix) else { return directory.lastPathComponent }
        return String(directoryPath.dropFirst(prefix.count))
    }

    private func copyFileMetadata(from sourceURL: URL, to destinationURL: URL, cancellation: ImportCancellationToken?) throws {
        try cancellation?.check()
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, copyfile_flags_t(COPYFILE_METADATA))
            }
        }
        guard result == 0 else {
            let errorCode = Darwin.errno
            throw AppError.transferFailed(
                sourceURL,
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errorCode),
                    userInfo: [NSLocalizedDescriptionKey: "ファイル属性をコピーできませんでした"]
                )
            )
        }
        try cancellation?.check()
    }

    private func restoreFileTimestamps(from sourceURL: URL, to destinationURL: URL) throws {
        let values = try sourceURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        var attributes: [FileAttributeKey: Any] = [:]
        if let creationDate = values.creationDate {
            attributes[.creationDate] = creationDate
        }
        if let modificationDate = values.contentModificationDate {
            attributes[.modificationDate] = modificationDate
        }
        guard !attributes.isEmpty else { return }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: destinationURL.path)
    }
}
