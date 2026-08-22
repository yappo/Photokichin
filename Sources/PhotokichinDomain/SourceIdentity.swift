import Foundation

/// Stable identity for an asset on a removable volume.
///
/// The volume UUID distinguishes two cards that happen to be mounted at the
/// same path. The relative path distinguishes files on that card without
/// retaining the mount-point name in the catalog.
package enum SourceIdentity {
    package struct Components: Sendable, Equatable {
        package let volumeUUID: String
        package let relativePath: String

        package init(volumeUUID: String, relativePath: String) {
            self.volumeUUID = volumeUUID
            self.relativePath = relativePath
        }
    }

    package static func legacyKey(url: URL, variant: AssetVariant) -> String {
        "\(url.deletingPathExtension().standardizedFileURL.path):\(variant.rawValue)"
    }

    package static func key(
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

    package static func components(url: URL, sourceRoot: URL?, volumeUUID: String?) -> Components? {
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

    package static func matchesLegacyPath(_ sourceKey: String, url: URL, variant: AssetVariant) -> Bool {
        sourceKey == legacyKey(url: url, variant: variant)
    }
}

/// Keeps the source filename separate from the current library path.
///
/// The raw filename is retained for provenance. The key is only a candidate
/// lookup value; file identity is still established by the verified SHA-256.
package enum FilenameIdentity {
    package static func rawFilename(for url: URL) -> String? {
        let filename = url.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else { return nil }
        return filename
    }

    package static func key(for filename: String?) -> String? {
        guard let filename else { return nil }
        let basename = URL(fileURLWithPath: filename).lastPathComponent
        guard !basename.isEmpty, basename != ".", basename != ".." else { return nil }
        return basename.precomposedStringWithCanonicalMapping.lowercased()
    }
}
