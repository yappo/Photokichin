import Foundation

package enum CameraConnectionState: Hashable, Sendable {
    case detected
    case openingSession
    case cataloging(percent: Int)
    case ready
    case ejecting
    case ejected
    case disconnected
    case failed(String)

    package var title: String {
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

    package var isBrowsable: Bool {
        switch self {
        case .cataloging, .ready:
            return true
        default:
            return false
        }
    }
}

package struct CameraDescriptor: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let serialNumber: String?
    package let isReady: Bool
    package let groupCount: Int
    package let canDeleteFiles: Bool
    package let canEject: Bool
    package let connectionState: CameraConnectionState

    package init(
        id: String,
        name: String,
        serialNumber: String?,
        isReady: Bool,
        groupCount: Int,
        canDeleteFiles: Bool,
        canEject: Bool,
        connectionState: CameraConnectionState
    ) {
        self.id = id
        self.name = name
        self.serialNumber = serialNumber
        self.isReady = isReady
        self.groupCount = groupCount
        self.canDeleteFiles = canDeleteFiles
        self.canEject = canEject
        self.connectionState = connectionState
    }

    package var statusText: String {
        switch connectionState {
        case .ready: return "\(groupCount)組"
        case .cataloging:
            return groupCount == 0
                ? "写真一覧を準備中…"
                : "\(groupCount)組を表示中・追加読み込み中"
        default: return connectionState.title
        }
    }

    package var isCataloging: Bool {
        if case .cataloging = connectionState { return true }
        return false
    }
}
