import Foundation

/// Stable identity for an asset on a removable volume.
///
/// The volume UUID distinguishes two cards that happen to be mounted at the
/// same path. The relative path distinguishes files on that card without
/// retaining the mount-point name in the catalog.
enum SourceIdentity {
    struct Components: Sendable, Equatable {
        let volumeUUID: String
        let relativePath: String
    }

    static func legacyKey(url: URL, variant: AssetVariant) -> String {
        "\(url.deletingPathExtension().standardizedFileURL.path):\(variant.rawValue)"
    }

    static func key(
        url: URL,
        variant: AssetVariant,
        sourceRoot: URL?,
        volumeUUID: String?
    ) -> String {
        guard let components = components(url: url, sourceRoot: sourceRoot, volumeUUID: volumeUUID) else {
            return legacyKey(url: url, variant: variant)
        }
        return "volume:\(components.volumeUUID):\(components.relativePath):\(variant.rawValue)"
    }

    static func components(url: URL, sourceRoot: URL?, volumeUUID: String?) -> Components? {
        guard let sourceRoot,
              let volumeUUID,
              !volumeUUID.isEmpty else { return nil }

        let standardizedURL = url.standardizedFileURL
        let standardizedRoot = sourceRoot.standardizedFileURL
        let rootPath = standardizedRoot.path.hasSuffix("/") ? standardizedRoot.path : standardizedRoot.path + "/"
        guard standardizedURL.path.hasPrefix(rootPath) else { return nil }

        let relativePath = String(standardizedURL.path.dropFirst(rootPath.count))
            .replacingOccurrences(of: "\\", with: "/")
        let extensionLength = (relativePath as NSString).pathExtension.count
        let relativeWithoutExtension: String
        if extensionLength > 0, relativePath.count > extensionLength + 1 {
            relativeWithoutExtension = String(relativePath.dropLast(extensionLength + 1))
        } else {
            relativeWithoutExtension = relativePath
        }
        guard !relativeWithoutExtension.isEmpty else { return nil }

        return Components(
            volumeUUID: volumeUUID.lowercased(),
            relativePath: relativeWithoutExtension
        )
    }

    static func matchesLegacyPath(_ sourceKey: String, url: URL, variant: AssetVariant) -> Bool {
        sourceKey == legacyKey(url: url, variant: variant)
    }
}
