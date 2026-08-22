import Foundation
import PhotokichinDomain

/// One concrete media-format contribution. Extensions are stored without a
/// leading dot and are matched case-insensitively by MediaFormatRegistry.
struct MediaFormatDefinition: Hashable, Sendable {
    let identifier: String
    let fileExtensions: Set<String>
    let variant: AssetVariant

    init(identifier: String, fileExtensions: Set<String>, variant: AssetVariant) {
        self.identifier = identifier
        self.fileExtensions = Set(fileExtensions.map(Self.normalizeExtension))
        self.variant = variant
    }

    private static func normalizeExtension(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}

protocol MediaFormatClassifying: Sendable {
    func variant(forFilename filename: String) -> AssetVariant?
}

enum MediaFormatRegistryError: Error, Equatable, Sendable {
    case duplicateIdentifier(String)
    case duplicateExtension(String, existingIdentifier: String, conflictingIdentifier: String)
    case invalidIdentifier(String)
    case invalidExtension(String, identifier: String)
}

/// A deterministic extension lookup. It deliberately does not inspect file
/// contents or depend on definition ordering.
struct MediaFormatRegistry: MediaFormatClassifying, Sendable {
    private let variantsByExtension: [String: AssetVariant]
    let definitions: [MediaFormatDefinition]

    init(definitions: [MediaFormatDefinition]) throws {
        var identifiers = Set<String>()
        var variants: [String: AssetVariant] = [:]
        var owners: [String: String] = [:]

        for definition in definitions {
            guard !definition.identifier.isEmpty else {
                throw MediaFormatRegistryError.invalidIdentifier(definition.identifier)
            }
            guard identifiers.insert(definition.identifier).inserted else {
                throw MediaFormatRegistryError.duplicateIdentifier(definition.identifier)
            }
            for extensionName in definition.fileExtensions {
                let normalized = Self.normalizeExtension(extensionName)
                guard !normalized.isEmpty else {
                    throw MediaFormatRegistryError.invalidExtension(extensionName, identifier: definition.identifier)
                }
                if let owner = owners[normalized] {
                    throw MediaFormatRegistryError.duplicateExtension(
                        normalized,
                        existingIdentifier: owner,
                        conflictingIdentifier: definition.identifier
                    )
                }
                owners[normalized] = definition.identifier
                variants[normalized] = definition.variant
            }
        }

        self.definitions = definitions
        self.variantsByExtension = variants
    }

    func variant(forFilename filename: String) -> AssetVariant? {
        let extensionName = URL(fileURLWithPath: filename).pathExtension
        return variantsByExtension[Self.normalizeExtension(extensionName)]
    }

    private static func normalizeExtension(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}

protocol FilesystemTraversalRule: Sendable {
    func shouldSkipDirectory(_ url: URL) -> Bool
}

struct FilesystemTraversalPolicy: Sendable {
    let rules: [any FilesystemTraversalRule]

    init(rules: [any FilesystemTraversalRule] = []) {
        self.rules = rules
    }

    func shouldSkipDirectory(_ url: URL) -> Bool {
        rules.contains { $0.shouldSkipDirectory(url) }
    }
}

private struct CanonManagementDirectoryRule: FilesystemTraversalRule {
    func shouldSkipDirectory(_ url: URL) -> Bool {
        url.lastPathComponent.caseInsensitiveCompare("CANONMSC") == .orderedSame
    }
}

enum MetadataScalar: Hashable, Sendable {
    case string(String)
    case number(Double)

    var stringValue: String {
        switch self {
        case let .string(value): return value
        case let .number(value):
            return value == floor(value) ? String(format: "%.0f", value) : String(value)
        }
    }

    var intValue: Int {
        switch self {
        case let .string(value): return Int(value) ?? 0
        case let .number(value): return Int(value)
        }
    }
}

struct MetadataEnrichmentContext: Hashable, Sendable {
    let filename: String?
    let standardMake: String?
    let standardModel: String?
    let makerNamespaces: [String: [String: MetadataScalar]]

    init(
        filename: String? = nil,
        standardMake: String? = nil,
        standardModel: String? = nil,
        makerNamespaces: [String: [String: MetadataScalar]] = [:]
    ) {
        self.filename = filename
        self.standardMake = standardMake
        self.standardModel = standardModel
        self.makerNamespaces = makerNamespaces
    }

    func makerNamespace(named name: String) -> [String: MetadataScalar]? {
        makerNamespaces.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

protocol MetadataEnricher: Sendable {
    func enrich(_ metadata: inout PhotoMetadata, context: MetadataEnrichmentContext) throws
}

struct CameraIdentity: Hashable, Sendable {
    let reportedName: String?
    let productKind: String?
    let usbVendorID: Int?
    let usbProductID: Int?

    init(reportedName: String?, productKind: String?, usbVendorID: Int?, usbProductID: Int?) {
        self.reportedName = Self.nonEmpty(reportedName)
        self.productKind = Self.nonEmpty(productKind)
        self.usbVendorID = Self.positive(usbVendorID)
        self.usbProductID = Self.positive(usbProductID)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

protocol CameraSupportMatcher: Sendable {
    var supportIdentifier: String { get }
    func matches(_ identity: CameraIdentity) -> Bool
}

private struct CanonCameraMatcher: CameraSupportMatcher {
    let supportIdentifier = "CanonCameraSupport"

    func matches(_ identity: CameraIdentity) -> Bool {
        [identity.reportedName, identity.productKind].compactMap { $0 }.contains {
            $0.range(of: "Canon", options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// Matches only the manufacturer names explicitly contributed by a camera
/// support. Matching is intentionally limited to the reported name and
/// product kind; USB identifiers are not used to infer a manufacturer.
private struct NamedCameraMatcher: CameraSupportMatcher {
    let supportIdentifier: String
    let manufacturerNames: [String]

    func matches(_ identity: CameraIdentity) -> Bool {
        [identity.reportedName, identity.productKind].compactMap { $0 }.contains { value in
            manufacturerNames.contains { manufacturerName in
                value.range(of: manufacturerName, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}

struct CameraSupportDefinition: Sendable {
    let identifier: String
    let mediaFormats: [MediaFormatDefinition]
    let filesystemTraversalRules: [any FilesystemTraversalRule]
    let metadataEnrichers: [any MetadataEnricher]
    let cameraMatchers: [any CameraSupportMatcher]

    init(
        identifier: String,
        mediaFormats: [MediaFormatDefinition],
        filesystemTraversalRules: [any FilesystemTraversalRule] = [],
        metadataEnrichers: [any MetadataEnricher] = [],
        cameraMatchers: [any CameraSupportMatcher] = []
    ) {
        self.identifier = identifier
        self.mediaFormats = mediaFormats
        self.filesystemTraversalRules = filesystemTraversalRules
        self.metadataEnrichers = metadataEnrichers
        self.cameraMatchers = cameraMatchers
    }
}

enum GenericMediaSupport {
    static let identifier = "GenericMediaSupport"

    static func definition() -> CameraSupportDefinition {
        CameraSupportDefinition(
            identifier: identifier,
            mediaFormats: [
                MediaFormatDefinition(
                    identifier: "jpeg",
                    fileExtensions: ["jpg", "jpeg"],
                    variant: .renderedImage
                ),
                MediaFormatDefinition(
                    identifier: "heif",
                    fileExtensions: ["hif", "heif", "heic"],
                    variant: .renderedImage
                ),
                MediaFormatDefinition(
                    identifier: "dng",
                    fileExtensions: ["dng"],
                    variant: .raw
                ),
                MediaFormatDefinition(
                    identifier: "movie",
                    fileExtensions: ["mov", "mp4"],
                    variant: .movie
                )
            ]
        )
    }
}

enum CanonCameraSupport {
    static let identifier = "CanonCameraSupport"

    static func definition() -> CameraSupportDefinition {
        CameraSupportDefinition(
            identifier: identifier,
            mediaFormats: [
                MediaFormatDefinition(
                    identifier: "canon.cr3",
                    fileExtensions: ["cr3"],
                    variant: .raw
                ),
                MediaFormatDefinition(
                    identifier: "canon.cr2",
                    fileExtensions: ["cr2"],
                    variant: .raw
                )
            ],
            filesystemTraversalRules: [CanonManagementDirectoryRule()],
            metadataEnrichers: [CanonMetadataEnricher()],
            cameraMatchers: [CanonCameraMatcher()]
        )
    }
}

enum SonyCameraSupport {
    static let identifier = "SonyCameraSupport"

    static func definition() -> CameraSupportDefinition {
        CameraSupportDefinition(
            identifier: identifier,
            mediaFormats: [
                MediaFormatDefinition(
                    identifier: "sony.arw",
                    fileExtensions: ["arw"],
                    variant: .raw
                )
            ],
            cameraMatchers: [NamedCameraMatcher(supportIdentifier: identifier, manufacturerNames: ["Sony"])]
        )
    }
}

enum NikonCameraSupport {
    static let identifier = "NikonCameraSupport"

    static func definition() -> CameraSupportDefinition {
        CameraSupportDefinition(
            identifier: identifier,
            mediaFormats: [
                MediaFormatDefinition(
                    identifier: "nikon.nef",
                    fileExtensions: ["nef"],
                    variant: .raw
                )
            ],
            cameraMatchers: [NamedCameraMatcher(supportIdentifier: identifier, manufacturerNames: ["Nikon"])]
        )
    }
}

enum FujifilmCameraSupport {
    static let identifier = "FujifilmCameraSupport"

    static func definition() -> CameraSupportDefinition {
        CameraSupportDefinition(
            identifier: identifier,
            mediaFormats: [
                MediaFormatDefinition(
                    identifier: "fujifilm.raf",
                    fileExtensions: ["raf"],
                    variant: .raw
                )
            ],
            cameraMatchers: [NamedCameraMatcher(supportIdentifier: identifier, manufacturerNames: ["FUJIFILM"])]
        )
    }
}

enum PanasonicCameraSupport {
    static let identifier = "PanasonicCameraSupport"

    static func definition() -> CameraSupportDefinition {
        CameraSupportDefinition(
            identifier: identifier,
            mediaFormats: [
                MediaFormatDefinition(
                    identifier: "panasonic.rw2",
                    fileExtensions: ["rw2"],
                    variant: .raw
                )
            ],
            cameraMatchers: [NamedCameraMatcher(supportIdentifier: identifier, manufacturerNames: ["Panasonic", "LUMIX"])]
        )
    }
}

enum OMSystemCameraSupport {
    static let identifier = "OMSystemCameraSupport"

    static func definition() -> CameraSupportDefinition {
        CameraSupportDefinition(
            identifier: identifier,
            mediaFormats: [
                MediaFormatDefinition(
                    identifier: "omsystem.orf",
                    fileExtensions: ["orf"],
                    variant: .raw
                )
            ],
            cameraMatchers: [NamedCameraMatcher(
                supportIdentifier: identifier,
                manufacturerNames: ["OM SYSTEM", "OM Digital Solutions", "Olympus"]
            )]
        )
    }
}

enum PentaxCameraSupport {
    static let identifier = "PentaxCameraSupport"

    static func definition() -> CameraSupportDefinition {
        CameraSupportDefinition(
            identifier: identifier,
            mediaFormats: [
                MediaFormatDefinition(
                    identifier: "pentax.pef",
                    fileExtensions: ["pef"],
                    variant: .raw
                )
            ],
            cameraMatchers: [NamedCameraMatcher(supportIdentifier: identifier, manufacturerNames: ["PENTAX"])]
        )
    }
}

enum RicohCameraSupport {
    static let identifier = "RicohCameraSupport"

    static func definition() -> CameraSupportDefinition {
        CameraSupportDefinition(
            identifier: identifier,
            mediaFormats: [],
            cameraMatchers: [NamedCameraMatcher(supportIdentifier: identifier, manufacturerNames: ["RICOH"])]
        )
    }
}

enum SigmaCameraSupport {
    static let identifier = "SigmaCameraSupport"

    static func definition() -> CameraSupportDefinition {
        CameraSupportDefinition(
            identifier: identifier,
            mediaFormats: [],
            cameraMatchers: [NamedCameraMatcher(supportIdentifier: identifier, manufacturerNames: ["SIGMA"])]
        )
    }
}

struct CameraSupportResolver: Sendable {
    let definitions: [CameraSupportDefinition]

    init(definitions: [CameraSupportDefinition]) {
        self.definitions = definitions
    }

    func supportIdentifier(for identity: CameraIdentity) -> String? {
        definitions.first { definition in
            definition.cameraMatchers.contains { $0.matches(identity) }
        }?.identifier
    }

    func resolve(_ identity: CameraIdentity) -> String? {
        supportIdentifier(for: identity)
    }
}

enum CameraSupportRegistryError: Error, Equatable, Sendable {
    case duplicateIdentifier(String)
}

/// A value registry for support contributions. It is deliberately created by
/// the composition root; no process-global registry or runtime discovery is
/// involved.
struct CameraSupportRegistry: Sendable {
    let definitions: [CameraSupportDefinition]

    init(definitions: [CameraSupportDefinition]) throws {
        var identifiers = Set<String>()
        for definition in definitions {
            guard identifiers.insert(definition.identifier).inserted else {
                throw CameraSupportRegistryError.duplicateIdentifier(definition.identifier)
            }
        }
        self.definitions = definitions
    }

    var resolver: CameraSupportResolver {
        CameraSupportResolver(definitions: definitions)
    }
}

struct InfrastructureComposition: Sendable {
    let mediaClassifier: any MediaFormatClassifying
    let traversalPolicy: FilesystemTraversalPolicy
    let cameraSupportResolver: CameraSupportResolver
    let metadataPipeline: MetadataEnrichmentPipeline

    static func production() -> InfrastructureComposition {
        do {
            let supportRegistry = try CameraSupportRegistry(
                definitions: [
                    GenericMediaSupport.definition(),
                    CanonCameraSupport.definition(),
                    SonyCameraSupport.definition(),
                    NikonCameraSupport.definition(),
                    FujifilmCameraSupport.definition(),
                    PanasonicCameraSupport.definition(),
                    OMSystemCameraSupport.definition(),
                    PentaxCameraSupport.definition(),
                    RicohCameraSupport.definition(),
                    SigmaCameraSupport.definition()
                ]
            )
            let definitions = supportRegistry.definitions
            let classifier = try MediaFormatRegistry(
                definitions: definitions.flatMap(\.mediaFormats)
            )
            return InfrastructureComposition(
                mediaClassifier: classifier,
                traversalPolicy: FilesystemTraversalPolicy(
                    rules: definitions.flatMap(\.filesystemTraversalRules)
                ),
                cameraSupportResolver: supportRegistry.resolver,
                metadataPipeline: MetadataEnrichmentPipeline(
                    enrichers: definitions.flatMap(\.metadataEnrichers)
                )
            )
        } catch {
            // Production definitions are static application configuration. A
            // duplicate would make the composition unsafe, so fail before
            // any consumer is constructed rather than partially registering.
            preconditionFailure("Invalid media support configuration: \(error)")
        }
    }
}
