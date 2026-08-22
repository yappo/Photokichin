import Foundation

package enum PhotoGridLayoutMetrics {
    package static let thumbnailHeightRatio = 0.72
    package static let tileTextSpacing = 6.0
    package static let adjacentPrefetchViewportCount = 1

    package static var initialWorkingSetViewportCount: Int {
        1 + adjacentPrefetchViewportCount * 2
    }
}

package enum PhotoGridNavigation {
    /// Keeps the visual column when moving from the first row of one section
    /// to the final row of the preceding section.
    package static func previousSectionIndex(currentColumn: Int, previousCount: Int, columns: Int) -> Int? {
        guard previousCount > 0 else { return nil }
        let safeColumns = max(1, columns)
        let lastRowStart = ((previousCount - 1) / safeColumns) * safeColumns
        return min(lastRowStart + max(0, currentColumn), previousCount - 1)
    }

    package static func pageTargetIndex(current: Int, count: Int, itemOffset: Int) -> Int? {
        guard count > 0, current >= 0, current < count else { return nil }
        return min(max(current + itemOffset, 0), count - 1)
    }
}

package enum AssetVariant: String, CaseIterable, Codable, Sendable {
    case jpeg = "JPG"
    case raw = "CR3"
    case movie = "動画"
}

/// A reference to a file exposed by ImageCaptureCore. The framework objects
/// themselves are deliberately kept out of PhotoGroup because they are not
/// Sendable and cannot be used safely by the scanner or transfer workers.
package struct CameraAssetReference: Hashable, Sendable {
    package let identifier: String
    package let filename: String
    package let variant: AssetVariant
    package let fileSize: Int64
    package let captureDate: Date?

    package init(identifier: String, filename: String, variant: AssetVariant, fileSize: Int64, captureDate: Date?) {
        self.identifier = identifier
        self.filename = filename
        self.variant = variant
        self.fileSize = fileSize
        self.captureDate = captureDate
    }
}

package struct CameraPhotoReference: Hashable, Sendable {
    package let cameraID: String
    package let groupKey: String
    package let assets: [CameraAssetReference]

    package init(cameraID: String, groupKey: String, assets: [CameraAssetReference]) {
        self.cameraID = cameraID
        self.groupKey = groupKey
        self.assets = assets
    }

    package func asset(for variant: AssetVariant) -> CameraAssetReference? {
        assets.first { $0.variant == variant }
    }
}

package enum PhotoImportState: String, CaseIterable, Hashable, Identifiable, Sendable {
    case notImported
    case possible
    case partial
    case imported
    case notApplicable

    package var id: Self { self }

    package var title: String {
        switch self {
        case .notImported: return "未取り込み"
        case .possible: return "取り込み済みかもしれない"
        case .partial: return "一部"
        case .imported: return "取り込み済み"
        case .notApplicable: return "対象外"
        }
    }

    package var systemImage: String {
        switch self {
        case .notImported: return "arrow.down.circle"
        case .possible: return "questionmark.circle"
        case .partial: return "circle.lefthalf.filled"
        case .imported: return "checkmark.circle"
        case .notApplicable: return "minus.circle"
        }
    }

    package var sortOrder: Int {
        switch self {
        case .notImported: return 0
        case .possible: return 1
        case .partial: return 2
        case .imported: return 3
        case .notApplicable: return 4
        }
    }
}

package enum PhotoImportFilter: CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case notImported
    case possible
    case partial
    case imported
    case notApplicable

    package var id: Self { self }

    package var title: String {
        switch self {
        case .all: return "すべて"
        case .notImported: return PhotoImportState.notImported.title
        case .possible: return PhotoImportState.possible.title
        case .partial: return PhotoImportState.partial.title
        case .imported: return PhotoImportState.imported.title
        case .notApplicable: return PhotoImportState.notApplicable.title
        }
    }

    package var systemImage: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .notImported: return PhotoImportState.notImported.systemImage
        case .possible: return PhotoImportState.possible.systemImage
        case .partial: return PhotoImportState.partial.systemImage
        case .imported: return PhotoImportState.imported.systemImage
        case .notApplicable: return PhotoImportState.notApplicable.systemImage
        }
    }

    package var state: PhotoImportState? {
        switch self {
        case .all: return nil
        case .notImported: return .notImported
        case .possible: return .possible
        case .partial: return .partial
        case .imported: return .imported
        case .notApplicable: return .notApplicable
        }
    }
}

package enum PhotoOperationFilter: CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case selected
    case deleteCandidates

    package var id: Self { self }

    package var title: String {
        switch self {
        case .all: return "すべて"
        case .selected: return "通常選択"
        case .deleteCandidates: return "削除候補"
        }
    }

    package var systemImage: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .selected: return "checkmark.circle"
        case .deleteCandidates: return "trash"
        }
    }
}

package enum LibraryAssetStatus: String, Codable, Sendable {
    case notApplicable
    case registered
    case partial
    case unregistered
}

package enum AirDropMode: String, CaseIterable, Identifiable {
    case jpegAndRaw
    case jpegOnly
    case rawOnly

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .jpegAndRaw: return "JPG＋CR3"
        case .jpegOnly: return "JPGのみ"
        case .rawOnly: return "CR3のみ"
        }
    }

    package var systemImage: String {
        switch self {
        case .jpegAndRaw: return "photo.on.rectangle.angled"
        case .jpegOnly: return "photo"
        case .rawOnly: return "camera.aperture"
        }
    }
}

package struct PhotoMetadata: Codable, Hashable, Sendable {
    package var captureDate: Date?
    package var cameraMake: String?
    package var cameraModel: String?
    package var lensModel: String?
    package var focalLength: String?
    package var aperture: String?
    package var shutterSpeed: String?
    package var iso: String?
    package var exposureBias: String?
    package var orientation: String?
    package var gps: String?
    package var firmware: String?
    package var pixelWidth: Int?
    package var pixelHeight: Int?

    package init(
        captureDate: Date?,
        cameraMake: String?,
        cameraModel: String?,
        lensModel: String?,
        focalLength: String?,
        aperture: String?,
        shutterSpeed: String?,
        iso: String?,
        exposureBias: String?,
        orientation: String?,
        gps: String?,
        firmware: String?,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) {
        self.captureDate = captureDate
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.iso = iso
        self.exposureBias = exposureBias
        self.orientation = orientation
        self.gps = gps
        self.firmware = firmware
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    package static let empty = PhotoMetadata(
        captureDate: nil,
        cameraMake: nil,
        cameraModel: nil,
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

    package var cameraDisplayName: String? {
        let values = [cameraMake, cameraModel].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.joined(separator: " ")
    }
}

package struct PhotoGroup: Identifiable, Hashable, Sendable {
    package let id: String
    package let basename: String
    package let directory: URL
    package var jpegURL: URL?
    package var rawURL: URL?
    package var movieURL: URL?
    package var captureDate: Date?
    package var metadata: PhotoMetadata
    package var importedJPEG: Bool
    package var importedRAW: Bool
    /// A metadata-only catalog match. This is deliberately separate from
    /// importedJPEG/importedRAW because filename, size, and variant do not
    /// prove that two files have identical bytes.
    package var possibleImportedJPEG: Bool
    package var possibleImportedRAW: Bool
    package var isMetadataLoaded: Bool
    package var libraryAssetStatus: LibraryAssetStatus = .notApplicable
    /// Persistent catalog identity. Unlike `id`, this value survives a
    /// Finder move and may be shared by an explicit library-to-library copy.
    package var photoID: String?
    package var labels: [PhotoLabel]
    /// Non-filesystem assets reported by a USB camera through
    /// ImageCaptureCore. The live ICCameraFile objects are owned by
    /// CameraMonitor and looked up by the identifiers in this value.
    package var cameraReference: CameraPhotoReference?
    /// Stable order assigned by the lightweight directory scan. Detailed
    /// metadata may update captureDate later, but must not move an already
    /// visible photo within its day.
    package var presentationOrder: Int = 0

    package init(
        id: String,
        basename: String,
        directory: URL,
        jpegURL: URL?,
        rawURL: URL?,
        movieURL: URL?,
        captureDate: Date?,
        metadata: PhotoMetadata,
        importedJPEG: Bool,
        importedRAW: Bool,
        isMetadataLoaded: Bool,
        possibleImportedJPEG: Bool = false,
        possibleImportedRAW: Bool = false,
        libraryAssetStatus: LibraryAssetStatus = .notApplicable,
        photoID: String? = nil,
        labels: [PhotoLabel] = [],
        cameraReference: CameraPhotoReference? = nil,
        presentationOrder: Int = 0
    ) {
        self.id = id
        self.basename = basename
        self.directory = directory
        self.jpegURL = jpegURL
        self.rawURL = rawURL
        self.movieURL = movieURL
        self.captureDate = captureDate
        self.metadata = metadata
        self.importedJPEG = importedJPEG
        self.importedRAW = importedRAW
        self.possibleImportedJPEG = possibleImportedJPEG
        self.possibleImportedRAW = possibleImportedRAW
        self.isMetadataLoaded = isMetadataLoaded
        self.libraryAssetStatus = libraryAssetStatus
        self.photoID = photoID
        self.labels = labels
        self.cameraReference = cameraReference
        self.presentationOrder = presentationOrder
    }

    package static func presentationPrecedes(_ lhs: PhotoGroup, _ rhs: PhotoGroup) -> Bool {
        if lhs.presentationOrder != rhs.presentationOrder {
            return lhs.presentationOrder < rhs.presentationOrder
        }
        let lhsDate = lhs.captureDate ?? .distantFuture
        let rhsDate = rhs.captureDate ?? .distantFuture
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        let basenameOrder = lhs.basename.localizedStandardCompare(rhs.basename)
        if basenameOrder != .orderedSame { return basenameOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    package var primaryURL: URL? { jpegURL ?? rawURL ?? movieURL }

    package var isCameraBacked: Bool { cameraReference != nil }

    package func url(for variant: AssetVariant) -> URL? {
        switch variant {
        case .jpeg: return jpegURL
        case .raw: return rawURL
        case .movie: return movieURL
        }
    }

    package var variants: [AssetVariant] {
        var result: [AssetVariant] = []
        if jpegURL != nil { result.append(.jpeg) }
        if rawURL != nil { result.append(.raw) }
        if movieURL != nil { result.append(.movie) }
        if let cameraReference {
            for variant in AssetVariant.allCases where cameraReference.asset(for: variant) != nil {
                if !result.contains(variant) { result.append(variant) }
            }
        }
        return result
    }

    package var importableVariants: [AssetVariant] {
        variants.filter { $0 == .jpeg || $0 == .raw }
    }

    package var dateKey: String {
        guard let captureDate else { return "撮影日不明" }
        return DateFormatters.day.string(from: captureDate)
    }

    package var cardImportState: PhotoImportState {
        let available = importableVariants.count
        guard available > 0 else { return .notApplicable }

        let imported = importableVariants.filter { variant in
            switch variant {
            case .jpeg: return importedJPEG
            case .raw: return importedRAW
            case .movie: return false
            }
        }.count
        if imported == 0 { return .notImported }
        if imported == available { return .imported }
        return .partial
    }

    package var hasPossibleImport: Bool {
        importableVariants.contains { variant in
            switch variant {
            case .jpeg: return !importedJPEG && possibleImportedJPEG
            case .raw: return !importedRAW && possibleImportedRAW
            case .movie: return false
            }
        }
    }

    /// The visible/filterable state. Exact import state remains unchanged for
    /// SD cards and library files; only a camera candidate adds .possible.
    package var displayImportState: PhotoImportState {
        let exactState = cardImportState
        guard exactState != .imported, hasPossibleImport else { return exactState }
        return .possible
    }

    package func matches(importFilter: PhotoImportFilter, operationFilter: PhotoOperationFilter, selected: Bool, deleteCandidate: Bool) -> Bool {
        let importMatches = importFilter.state.map { displayImportState == $0 } ?? true
        let operationMatches: Bool
        switch operationFilter {
        case .all: operationMatches = true
        case .selected: operationMatches = selected
        case .deleteCandidates: operationMatches = deleteCandidate
        }
        return importMatches && operationMatches
    }

    package var statusLabel: String {
        switch libraryAssetStatus {
        case .registered: return "保存済み"
        case .partial: return "一部保存"
        case .unregistered: return "EXT"
        case .notApplicable: break
        }
        return displayImportState.title
    }
}

package struct PhotoImportCluster: Identifiable, Hashable, Sendable {
    package let id: String
    package let state: PhotoImportState
    package let photos: [PhotoGroup]

    package init(dateKey: String, state: PhotoImportState, photos: [PhotoGroup]) {
        self.id = "\(dateKey)|\(state.rawValue)|\(photos.first?.id ?? "empty")"
        self.state = state
        self.photos = photos
    }

    /// Adds state headers without changing the chronological photo order.
    /// A state may therefore appear in more than one contiguous run.
    package static func preservingOrder(dateKey: String, photos: [PhotoGroup]) -> [PhotoImportCluster] {
        guard let first = photos.first else { return [] }
        var result: [PhotoImportCluster] = []
        var state = first.displayImportState
        var run: [PhotoGroup] = []

        for photo in photos {
            let nextState = photo.displayImportState
            if nextState != state {
                result.append(PhotoImportCluster(dateKey: dateKey, state: state, photos: run))
                run.removeAll(keepingCapacity: true)
                state = nextState
            }
            run.append(photo)
        }
        result.append(PhotoImportCluster(dateKey: dateKey, state: state, photos: run))
        return result
    }
}

package struct MountedVolume: Identifiable, Hashable, Sendable {
    package let id: String
    package let url: URL
    package let name: String
    package let isRemovable: Bool
    package let isEjectable: Bool
    package let volumeUUID: String?

    package init(id: String, url: URL, name: String, isRemovable: Bool, isEjectable: Bool, volumeUUID: String?) {
        self.id = id
        self.url = url
        self.name = name
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.volumeUUID = volumeUUID
    }
}

package struct ImportResult: Identifiable, Sendable {
    package let id = UUID()
    package let groupID: String
    package let message: String
    package let copiedCount: Int
    package let skippedCount: Int
    package let failedCount: Int

    package init(groupID: String, message: String, copiedCount: Int, skippedCount: Int, failedCount: Int) {
        self.groupID = groupID
        self.message = message
        self.copiedCount = copiedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
    }
}

package struct OperationProgress: Equatable, Sendable {
    package let title: String
    package let completedGroups: Int
    package let totalGroups: Int
    package let completedFiles: Int
    package let totalFiles: Int

    package init(title: String, completedGroups: Int, totalGroups: Int, completedFiles: Int, totalFiles: Int) {
        self.title = title
        self.completedGroups = completedGroups
        self.totalGroups = totalGroups
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
    }

    package var fraction: Double {
        guard totalGroups > 0 else { return 0 }
        return Double(completedGroups) / Double(totalGroups)
    }
}

package enum AppError: LocalizedError {
    case noSource
    case noSelectedPhotos
    case noDeleteCandidates
    case noLibrary
    case unsupportedFile(URL)
    case cannotReadMetadata(URL)
    case cannotCreateThumbnail(URL)
    case cannotOpenCatalog(URL)
    case catalogMigrationRequired(URL)
    case invalidLabelName
    case copyConflict(URL)
    case transferFailed(URL, Error)
    case ejectFailed(String)

    package var errorDescription: String? {
        switch self {
        case .noSource: return "読み込むSDカードまたはフォルダが選択されていません。"
        case .noSelectedPhotos: return "写真が選択されていません。"
        case .noDeleteCandidates: return "削除候補が選択されていません。"
        case .noLibrary: return "取り込み先が設定されていません。"
        case .unsupportedFile(let url): return "対応していないファイルです: \(url.lastPathComponent)"
        case .cannotReadMetadata(let url): return "メタデータを読み取れませんでした: \(url.lastPathComponent)"
        case .cannotCreateThumbnail(let url): return "サムネイルを作成できませんでした: \(url.lastPathComponent)"
        case .cannotOpenCatalog(let url): return "カタログを開けませんでした: \(url.path)"
        case .catalogMigrationRequired(let url): return "このカタログはラベル対応前の形式です。一度限りの移行を先に実行してください: \(url.path)"
        case .invalidLabelName: return "ラベル名は1〜64文字で入力してください。"
        case .copyConflict(let url): return "同名で内容の異なるファイルがあります: \(url.path)"
        case .transferFailed(let url, let error): return "ファイル処理に失敗しました（\(url.lastPathComponent)）: \(error.localizedDescription)"
        case .ejectFailed(let message): return "Ejectに失敗しました: \(message)"
        }
    }
}

package enum DateFormatters {
    package static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年MM月dd日"
        return formatter
    }()

    package static let directoryDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    package static let detail: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

package func normalizedExtension(_ url: URL) -> String {
    url.pathExtension.lowercased()
}

package func sanitizedFileComponent(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:\n\r\t")
    let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未設定" : cleaned
}
