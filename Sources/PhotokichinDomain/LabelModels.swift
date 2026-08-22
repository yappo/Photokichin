import Foundation

package struct PhotoLabel: Identifiable, Hashable, Sendable {
    package let id: String
    package var name: String
    package var normalizedName: String
    package var colorHex: String
    package var sortOrder: Int
    package var lastUsedAt: Date?

    package init(id: String, name: String, normalizedName: String, colorHex: String, sortOrder: Int, lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.normalizedName = normalizedName
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.lastUsedAt = lastUsedAt
    }
}

/// Deliberately contains no label UUID. Library-copy code can transfer label
/// presentation, but cannot accidentally persist a source-library label ID.
package struct TransferredLabel: Hashable, Sendable {
    package let name: String
    package let normalizedName: String
    package let colorHex: String

    package init(name: String, normalizedName: String, colorHex: String) {
        self.name = name
        self.normalizedName = normalizedName
        self.colorHex = colorHex
    }
}

package struct SavedLabelView: Identifiable, Hashable, Sendable {
    package let id: String
    package var name: String
    package var labelIDs: [String]
    package var sortOrder: Int

    package init(id: String, name: String, labelIDs: [String], sortOrder: Int) {
        self.id = id
        self.name = name
        self.labelIDs = labelIDs
        self.sortOrder = sortOrder
    }
}

package enum LabelAssignmentState: Sendable {
    case all
    case some
    case none
}

package struct LabelCatalogSnapshot: Sendable {
    package let labels: [PhotoLabel]
    package let savedViews: [SavedLabelView]
    package let photoIDByGroupID: [String: String]
    package let labelsByPhotoID: [String: [PhotoLabel]]

    package init(
        labels: [PhotoLabel],
        savedViews: [SavedLabelView],
        photoIDByGroupID: [String: String],
        labelsByPhotoID: [String: [PhotoLabel]]
    ) {
        self.labels = labels
        self.savedViews = savedViews
        self.photoIDByGroupID = photoIDByGroupID
        self.labelsByPhotoID = labelsByPhotoID
    }
}

package enum LabelPalette {
    package static let colors = [
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

package func normalizedLabelName(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .precomposedStringWithCanonicalMapping
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
}
