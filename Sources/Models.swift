import Foundation

enum PhotoGridLayoutMetrics {
    static let thumbnailHeightRatio = 0.72
    static let tileTextSpacing = 6.0
    static let adjacentPrefetchViewportCount = 1

    static var initialWorkingSetViewportCount: Int {
        1 + adjacentPrefetchViewportCount * 2
    }
}

enum PhotoGridNavigation {
    /// Keeps the visual column when moving from the first row of one section
    /// to the final row of the preceding section.
    static func previousSectionIndex(currentColumn: Int, previousCount: Int, columns: Int) -> Int? {
        guard previousCount > 0 else { return nil }
        let safeColumns = max(1, columns)
        let lastRowStart = ((previousCount - 1) / safeColumns) * safeColumns
        return min(lastRowStart + max(0, currentColumn), previousCount - 1)
    }

    static func pageTargetIndex(current: Int, count: Int, itemOffset: Int) -> Int? {
        guard count > 0, current >= 0, current < count else { return nil }
        return min(max(current + itemOffset, 0), count - 1)
    }
}

enum AssetVariant: String, CaseIterable, Codable, Sendable {
    case jpeg = "JPG"
    case raw = "CR3"
    case movie = "動画"
}

enum PhotoImportState: String, CaseIterable, Hashable, Identifiable, Sendable {
    case notImported
    case partial
    case imported
    case notApplicable

    var id: Self { self }

    var title: String {
        switch self {
        case .notImported: return "未取り込み"
        case .partial: return "一部"
        case .imported: return "取り込み済み"
        case .notApplicable: return "対象外"
        }
    }

    var systemImage: String {
        switch self {
        case .notImported: return "arrow.down.circle"
        case .partial: return "circle.lefthalf.filled"
        case .imported: return "checkmark.circle"
        case .notApplicable: return "minus.circle"
        }
    }

    var sortOrder: Int {
        switch self {
        case .notImported: return 0
        case .partial: return 1
        case .imported: return 2
        case .notApplicable: return 3
        }
    }
}

enum PhotoImportFilter: CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case notImported
    case partial
    case imported
    case notApplicable

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "すべて"
        case .notImported: return PhotoImportState.notImported.title
        case .partial: return PhotoImportState.partial.title
        case .imported: return PhotoImportState.imported.title
        case .notApplicable: return PhotoImportState.notApplicable.title
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .notImported: return PhotoImportState.notImported.systemImage
        case .partial: return PhotoImportState.partial.systemImage
        case .imported: return PhotoImportState.imported.systemImage
        case .notApplicable: return PhotoImportState.notApplicable.systemImage
        }
    }

    var state: PhotoImportState? {
        switch self {
        case .all: return nil
        case .notImported: return .notImported
        case .partial: return .partial
        case .imported: return .imported
        case .notApplicable: return .notApplicable
        }
    }
}

enum PhotoOperationFilter: CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case selected
    case deleteCandidates

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "すべて"
        case .selected: return "通常選択"
        case .deleteCandidates: return "削除候補"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .selected: return "checkmark.circle"
        case .deleteCandidates: return "trash"
        }
    }
}

enum LibraryAssetStatus: String, Codable, Sendable {
    case notApplicable
    case registered
    case partial
    case unregistered
}

enum AirDropMode: String, CaseIterable, Identifiable {
    case jpegAndRaw
    case jpegOnly
    case rawOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpegAndRaw: return "JPG＋CR3"
        case .jpegOnly: return "JPGのみ"
        case .rawOnly: return "CR3のみ"
        }
    }

    var systemImage: String {
        switch self {
        case .jpegAndRaw: return "photo.on.rectangle.angled"
        case .jpegOnly: return "photo"
        case .rawOnly: return "camera.aperture"
        }
    }
}

struct PhotoMetadata: Codable, Hashable, Sendable {
    var captureDate: Date?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var focalLength: String?
    var aperture: String?
    var shutterSpeed: String?
    var iso: String?
    var exposureBias: String?
    var orientation: String?
    var gps: String?
    var firmware: String?
    var pixelWidth: Int?
    var pixelHeight: Int?

    static let empty = PhotoMetadata(
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

    var cameraDisplayName: String? {
        let values = [cameraMake, cameraModel].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.joined(separator: " ")
    }
}

struct PhotoGroup: Identifiable, Hashable, Sendable {
    let id: String
    let basename: String
    let directory: URL
    var jpegURL: URL?
    var rawURL: URL?
    var movieURL: URL?
    var captureDate: Date?
    var metadata: PhotoMetadata
    var importedJPEG: Bool
    var importedRAW: Bool
    var isMetadataLoaded: Bool
    var libraryAssetStatus: LibraryAssetStatus = .notApplicable
    /// Persistent catalog identity. Unlike `id`, this value survives a
    /// Finder move and may be shared by an explicit library-to-library copy.
    var photoID: String?
    var labels: [PhotoLabel]
    /// Stable order assigned by the lightweight directory scan. Detailed
    /// metadata may update captureDate later, but must not move an already
    /// visible photo within its day.
    var presentationOrder: Int = 0

    init(
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
        libraryAssetStatus: LibraryAssetStatus = .notApplicable,
        photoID: String? = nil,
        labels: [PhotoLabel] = [],
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
        self.isMetadataLoaded = isMetadataLoaded
        self.libraryAssetStatus = libraryAssetStatus
        self.photoID = photoID
        self.labels = labels
        self.presentationOrder = presentationOrder
    }

    static func presentationPrecedes(_ lhs: PhotoGroup, _ rhs: PhotoGroup) -> Bool {
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

    var primaryURL: URL? { jpegURL ?? rawURL ?? movieURL }

    func url(for variant: AssetVariant) -> URL? {
        switch variant {
        case .jpeg: return jpegURL
        case .raw: return rawURL
        case .movie: return movieURL
        }
    }

    var variants: [AssetVariant] {
        var result: [AssetVariant] = []
        if jpegURL != nil { result.append(.jpeg) }
        if rawURL != nil { result.append(.raw) }
        if movieURL != nil { result.append(.movie) }
        return result
    }

    var dateKey: String {
        guard let captureDate else { return "撮影日不明" }
        return DateFormatters.day.string(from: captureDate)
    }

    var cardImportState: PhotoImportState {
        let available = [jpegURL, rawURL].compactMap { $0 }.count
        guard available > 0 else { return .notApplicable }

        let imported = [
            jpegURL != nil && importedJPEG,
            rawURL != nil && importedRAW
        ].filter { $0 }.count
        if imported == 0 { return .notImported }
        if imported == available { return .imported }
        return .partial
    }

    func matches(importFilter: PhotoImportFilter, operationFilter: PhotoOperationFilter, selected: Bool, deleteCandidate: Bool) -> Bool {
        let importMatches = importFilter.state.map { cardImportState == $0 } ?? true
        let operationMatches: Bool
        switch operationFilter {
        case .all: operationMatches = true
        case .selected: operationMatches = selected
        case .deleteCandidates: operationMatches = deleteCandidate
        }
        return importMatches && operationMatches
    }

    var statusLabel: String {
        switch libraryAssetStatus {
        case .registered: return "保存済み"
        case .partial: return "一部保存"
        case .unregistered: return "EXT"
        case .notApplicable: break
        }
        return cardImportState.title
    }
}

struct PhotoImportCluster: Identifiable, Hashable, Sendable {
    let id: String
    let state: PhotoImportState
    let photos: [PhotoGroup]

    init(dateKey: String, state: PhotoImportState, photos: [PhotoGroup]) {
        self.id = "\(dateKey)|\(state.rawValue)|\(photos.first?.id ?? "empty")"
        self.state = state
        self.photos = photos
    }

    /// Adds state headers without changing the chronological photo order.
    /// A state may therefore appear in more than one contiguous run.
    static func preservingOrder(dateKey: String, photos: [PhotoGroup]) -> [PhotoImportCluster] {
        guard let first = photos.first else { return [] }
        var result: [PhotoImportCluster] = []
        var state = first.cardImportState
        var run: [PhotoGroup] = []

        for photo in photos {
            let nextState = photo.cardImportState
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

struct MountedVolume: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isRemovable: Bool
    let isEjectable: Bool
    let volumeUUID: String?
}

struct ImportResult: Identifiable, Sendable {
    let id = UUID()
    let groupID: String
    let message: String
    let copiedCount: Int
    let skippedCount: Int
    let failedCount: Int
}

struct OperationProgress: Equatable, Sendable {
    let title: String
    let completedGroups: Int
    let totalGroups: Int
    let completedFiles: Int
    let totalFiles: Int

    var fraction: Double {
        guard totalGroups > 0 else { return 0 }
        return Double(completedGroups) / Double(totalGroups)
    }
}

enum AppError: LocalizedError {
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

    var errorDescription: String? {
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

enum DateFormatters {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年MM月dd日"
        return formatter
    }()

    static let directoryDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let detail: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

func normalizedExtension(_ url: URL) -> String {
    url.pathExtension.lowercased()
}

func sanitizedFileComponent(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:\n\r\t")
    let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未設定" : cleaned
}
