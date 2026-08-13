import Foundation

struct PhotoLabel: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var normalizedName: String
    var colorHex: String
    var sortOrder: Int
    var lastUsedAt: Date?
}

/// Deliberately contains no label UUID. Library-copy code can transfer label
/// presentation, but cannot accidentally persist a source-library label ID.
struct TransferredLabel: Hashable, Sendable {
    let name: String
    let normalizedName: String
    let colorHex: String
}

struct SavedLabelView: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var labelIDs: [String]
    var sortOrder: Int
}

enum LabelAssignmentState: Sendable {
    case all
    case some
    case none
}

struct LabelCatalogSnapshot: Sendable {
    let labels: [PhotoLabel]
    let savedViews: [SavedLabelView]
    let photoIDByGroupID: [String: String]
    let labelsByPhotoID: [String: [PhotoLabel]]
}

enum LabelPalette {
    static let colors = [
        "#E5484D", "#D13438", "#FF6369", "#B4232B",
        "#E57A1F", "#F28C28", "#FFB224", "#C65D0E",
        "#D6A800", "#F2C037", "#E8D33F", "#B89500",
        "#46A758", "#2F9E44", "#65C466", "#1D7A46",
        "#12A594", "#0E9384", "#37B8AA", "#087F73",
        "#0091FF", "#3B82F6", "#5B8DEF", "#1D4ED8",
        "#6E56CF", "#7C3AED", "#9B6DFF", "#5131A6",
        "#D6409F", "#E052A0", "#F472B6", "#A92D7D"
    ]
}

func normalizedLabelName(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .precomposedStringWithCanonicalMapping
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
}
