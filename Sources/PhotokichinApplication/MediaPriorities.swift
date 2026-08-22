import Foundation

package enum MetadataRequestPriority: Int, Sendable {
    case viewerCurrent = 0
    case viewerNeighbor = 1
    case visible = 10
    case prefetch = 20
    case background = 30

    package var taskPriority: TaskPriority {
        switch self {
        case .viewerCurrent, .viewerNeighbor, .visible:
            return .userInitiated
        case .prefetch:
            return .utility
        case .background:
            return .background
        }
    }
}

package enum ThumbnailRequestPriority: Int, Sendable {
    case viewerCurrent = 0
    case viewerNeighbor = 1
    case visible = 10
    case prefetch = 20
}
