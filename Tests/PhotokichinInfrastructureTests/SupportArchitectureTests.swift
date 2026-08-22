import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotokichinDomain
@testable import PhotokichinApplication
@testable import PhotokichinInfrastructure

private enum MetadataTestError: Error {
    case expectedFailure
}

private struct ThrowingMetadataEnricher: MetadataEnricher {
    func enrich(_ metadata: inout PhotoMetadata, context: MetadataEnrichmentContext) throws {
        throw MetadataTestError.expectedFailure
    }
}

private struct LaterMetadataEnricher: MetadataEnricher {
    func enrich(_ metadata: inout PhotoMetadata, context: MetadataEnrichmentContext) throws {
        if metadata.lensModel == nil {
            metadata.lensModel = "Later Lens"
        }
        metadata.cameraModel = "Later Marker"
    }
}

private struct MarkerMetadataEnricher: MetadataEnricher {
    func enrich(_ metadata: inout PhotoMetadata, context: MetadataEnrichmentContext) throws {
        metadata.firmware = "pipeline-marker"
    }
}

// Optional real-file validation. Set PHOTOKICHIN_IMAGEIO_SAMPLES to a
// newline-separated list of `label=/absolute/path` entries. The test is
// disabled when the variable is absent; synthetic fixtures are deliberately
// not accepted as ImageIO RAW/HEIF evidence.
private let imageIOSampleManifest = ProcessInfo.processInfo.environment["PHOTOKICHIN_IMAGEIO_SAMPLES"]
private let imageIOSampleTestEnabled = imageIOSampleManifest?.isEmpty == false

@Suite("Camera-agnostic support architecture")
struct SupportArchitectureTests {
    @Test("Asset roles retain their legacy persistence values")
    func assetRoleCompatibility() {
        #expect(AssetVariant.renderedImage.rawValue == "JPG")
        #expect(AssetVariant.raw.rawValue == "CR3")
        #expect(AssetVariant.movie.rawValue == "動画")
        #expect(AssetVariant.renderedImage.roleDisplayName == "画像")
        #expect(AssetVariant.raw.roleDisplayName == "RAW")
        #expect(AssetVariant.movie.roleDisplayName == "動画")

        let root = URL(fileURLWithPath: "/Volumes/CARD")
        let rendered = root.appendingPathComponent("DCIM/100/IMG_0001.JPG")
        let raw = root.appendingPathComponent("DCIM/100/IMG_0001.CR3")
        #expect(SourceIdentity.legacyKey(url: rendered, variant: .renderedImage) == "/Volumes/CARD/DCIM/100/IMG_0001:JPG")
        #expect(SourceIdentity.legacyKey(url: raw, variant: .raw) == "/Volumes/CARD/DCIM/100/IMG_0001:CR3")
        #expect(SourceIdentity.key(url: rendered, variant: .renderedImage, sourceRoot: root, volumeUUID: "CARD-UUID") == "volume:card-uuid:DCIM/100/IMG_0001:JPG")
        #expect(SourceIdentity.key(url: raw, variant: .raw, sourceRoot: root, volumeUUID: "CARD-UUID") == "volume:card-uuid:DCIM/100/IMG_0001:CR3")
        #expect(CameraSourceLocation.catalogKey(cameraID: "camera-1", groupKey: "DCIM/100/IMG_0001", variant: .renderedImage) == "camera:camera-1:DCIM/100/IMG_0001:JPG")
        #expect(CameraSourceLocation.catalogKey(cameraID: "camera-1", groupKey: "DCIM/100/IMG_0001", variant: .raw) == "camera:camera-1:DCIM/100/IMG_0001:CR3")
    }

    @Test("Production definitions map formats independently of definition order")
    func productionFormatMappings() throws {
        let genericDefinitions = GenericMediaSupport.definition().mediaFormats
        let generic = try MediaFormatRegistry(definitions: genericDefinitions)
        let genericExpectations: [(String, AssetVariant)] = [
            ("jpg", .renderedImage), ("jpeg", .renderedImage),
            ("hif", .renderedImage), ("heif", .renderedImage), ("heic", .renderedImage),
            ("dng", .raw),
            ("mov", .movie), ("mp4", .movie)
        ]
        for (extensionName, expectedVariant) in genericExpectations {
            #expect(generic.variant(forFilename: "IMG.\(extensionName)") == expectedVariant)
            #expect(generic.variant(forFilename: "IMG.\(extensionName.uppercased())") == expectedVariant)
        }
        #expect(generic.variant(forFilename: "IMG.CR3") == nil)
        #expect(generic.variant(forFilename: "IMG.NEF") == nil)
        #expect(generic.variant(forFilename: "IMG.NEV") == nil)
        #expect(generic.variant(forFilename: "IMG.X3F") == nil)

        // Keep the existing Canon JPG + CR3 baseline explicit while extending
        // the table to all contributed RAW families.
        let supports = productionSupportDefinitions
        let productionDefinitions = supports.flatMap(\.mediaFormats)
        let production = try MediaFormatRegistry(definitions: productionDefinitions)
        let reversed = try MediaFormatRegistry(definitions: Array(productionDefinitions.reversed()))
        #expect(production.variant(forFilename: "IMG.CR3") == .raw)
        #expect(production.variant(forFilename: "IMG.cr3") == .raw)
        #expect(production.variant(forFilename: "IMG.cr3") == reversed.variant(forFilename: "IMG.CR3"))
        #expect(production.variant(forFilename: "IMG.CR2") == .raw)
        #expect(production.variant(forFilename: "IMG.cr2") == .raw)
        for extensionName in ["arw", "nef", "raf", "rw2", "orf", "pef", "dng"] {
            #expect(production.variant(forFilename: "IMG.\(extensionName.uppercased())") == .raw)
            #expect(production.variant(forFilename: "IMG.\(extensionName)") == reversed.variant(forFilename: "IMG.\(extensionName)"))
        }
        #expect(production.variant(forFilename: "IMG.UNKNOWN") == nil)
        #expect(production.variant(forFilename: "IMG.nev") == nil)
        #expect(production.variant(forFilename: "IMG.NEV") == nil)
        #expect(production.variant(forFilename: "IMG.x3f") == nil)
        #expect(production.variant(forFilename: "IMG.X3F") == nil)
        #expect(reversed.variant(forFilename: "IMG.JPG") == .renderedImage)
        #expect(reversed.variant(forFilename: "CLIP.MP4") == .movie)
    }

    @Test("Production support contributions have stable ownership and ordering")
    func productionSupportContributions() throws {
        let definitions = productionSupportDefinitions
        #expect(definitions.map(\.identifier) == [
            GenericMediaSupport.identifier,
            CanonCameraSupport.identifier,
            SonyCameraSupport.identifier,
            NikonCameraSupport.identifier,
            FujifilmCameraSupport.identifier,
            PanasonicCameraSupport.identifier,
            OMSystemCameraSupport.identifier,
            PentaxCameraSupport.identifier,
            RicohCameraSupport.identifier,
            SigmaCameraSupport.identifier
        ])

        #expect(RicohCameraSupport.definition().mediaFormats.isEmpty)
        #expect(SigmaCameraSupport.definition().mediaFormats.isEmpty)
        let dngOwners = definitions.filter { definition in
            definition.mediaFormats.contains { $0.fileExtensions.contains("dng") }
        }
        #expect(dngOwners.map(\.identifier) == [GenericMediaSupport.identifier])
        #expect(throws: MediaFormatRegistryError.duplicateExtension(
            "dng",
            existingIdentifier: "dng",
            conflictingIdentifier: "duplicate.dng"
        )) {
            try MediaFormatRegistry(definitions: [
                GenericMediaSupport.definition().mediaFormats.first { $0.identifier == "dng" }!,
                MediaFormatDefinition(identifier: "duplicate.dng", fileExtensions: ["DNG"], variant: .raw)
            ])
        }

        let registry = try CameraSupportRegistry(definitions: definitions)
        let classifier = try MediaFormatRegistry(definitions: registry.definitions.flatMap(\.mediaFormats))
        #expect(classifier.variant(forFilename: "IMG.NEV") == nil)
        #expect(classifier.variant(forFilename: "IMG.X3F") == nil)
    }

    @Test("Each vendor RAW format is isolated to its own contribution")
    func vendorFormatIsolation() throws {
        let genericDefinition = GenericMediaSupport.definition()
        let vendorContributions: [(CameraSupportDefinition, String)] = [
            (CanonCameraSupport.definition(), "cr3"),
            (CanonCameraSupport.definition(), "cr2"),
            (SonyCameraSupport.definition(), "arw"),
            (NikonCameraSupport.definition(), "nef"),
            (FujifilmCameraSupport.definition(), "raf"),
            (PanasonicCameraSupport.definition(), "rw2"),
            (OMSystemCameraSupport.definition(), "orf"),
            (PentaxCameraSupport.definition(), "pef")
        ]

        let genericOnly = try MediaFormatRegistry(definitions: genericDefinition.mediaFormats)
        for (contribution, extensionName) in vendorContributions {
            #expect(genericOnly.variant(forFilename: "IMG.\(extensionName)") == nil)
            let contributed = try MediaFormatRegistry(
                definitions: genericDefinition.mediaFormats + contribution.mediaFormats
            )
            #expect(contributed.variant(forFilename: "IMG.\(extensionName.uppercased())") == .raw)
        }
    }

    @Test("Camera matchers use explicit names and preserve PENTAX before RICOH")
    func cameraMatcherOrderingAndIsolation() {
        let resolver = CameraSupportResolver(definitions: productionSupportDefinitions)
        let cases: [(String, String?, String?)] = [
            (CanonCameraSupport.identifier, "Canon EOS R", nil),
            (SonyCameraSupport.identifier, "sony ILCE-7", nil),
            (NikonCameraSupport.identifier, nil, "NIKON Camera"),
            (FujifilmCameraSupport.identifier, "Fujifilm X-T5", nil),
            (PanasonicCameraSupport.identifier, "LUMIX S5II", nil),
            (PanasonicCameraSupport.identifier, nil, "Panasonic Camera"),
            (OMSystemCameraSupport.identifier, "OM SYSTEM OM-1", nil),
            (OMSystemCameraSupport.identifier, "OM Digital Solutions Camera", nil),
            (OMSystemCameraSupport.identifier, "Olympus OM-D", nil),
            (PentaxCameraSupport.identifier, "PENTAX RICOH Camera", nil),
            (RicohCameraSupport.identifier, "RICOH GR III", nil),
            (SigmaCameraSupport.identifier, "SIGMA fp", nil)
        ]

        for (expected, reportedName, productKind) in cases {
            let identity = CameraIdentity(reportedName: reportedName, productKind: productKind, usbVendorID: nil, usbProductID: nil)
            #expect(resolver.supportIdentifier(for: identity) == expected)
        }

        #expect(resolver.supportIdentifier(for: CameraIdentity(reportedName: "Camera", productKind: "Still Image", usbVendorID: 123, usbProductID: 456)) == nil)
        #expect(resolver.supportIdentifier(for: CameraIdentity(reportedName: "Unknown Camera", productKind: nil, usbVendorID: nil, usbProductID: nil)) == nil)
    }

    private var productionSupportDefinitions: [CameraSupportDefinition] {
        InfrastructureComposition.production().cameraSupportResolver.definitions
    }

    @Test("Registry normalizes extensions and rejects duplicate ownership")
    func registryValidationAndLookup() throws {
        let definitions = [
            MediaFormatDefinition(identifier: "rendered", fileExtensions: [".fimg", "FIMG"], variant: .renderedImage),
            MediaFormatDefinition(identifier: "raw", fileExtensions: ["fraw"], variant: .raw)
        ]
        let registry = try MediaFormatRegistry(definitions: definitions)
        #expect(registry.variant(forFilename: "IMG.FIMG") == .renderedImage)
        #expect(registry.variant(forFilename: "IMG.fraw") == .raw)
        #expect(registry.variant(forFilename: "IMG.nef") == nil)

        let reversed = try MediaFormatRegistry(definitions: Array(definitions.reversed()))
        #expect(reversed.variant(forFilename: "IMG.FIMG") == registry.variant(forFilename: "IMG.FIMG"))
        #expect(reversed.variant(forFilename: "IMG.FRAW") == registry.variant(forFilename: "IMG.FRAW"))

        #expect(throws: MediaFormatRegistryError.duplicateIdentifier("duplicate")) {
            try MediaFormatRegistry(definitions: [
                MediaFormatDefinition(identifier: "duplicate", fileExtensions: ["one"], variant: .raw),
                MediaFormatDefinition(identifier: "duplicate", fileExtensions: ["two"], variant: .movie)
            ])
        }
        #expect(throws: MediaFormatRegistryError.duplicateExtension("same", existingIdentifier: "one", conflictingIdentifier: "two")) {
            try MediaFormatRegistry(definitions: [
                MediaFormatDefinition(identifier: "one", fileExtensions: ["same"], variant: .raw),
                MediaFormatDefinition(identifier: "two", fileExtensions: [".SAME"], variant: .raw)
            ])
        }
        #expect(throws: CameraSupportRegistryError.duplicateIdentifier("duplicate-support")) {
            try CameraSupportRegistry(definitions: [
                CameraSupportDefinition(identifier: "duplicate-support", mediaFormats: []),
                CameraSupportDefinition(identifier: "duplicate-support", mediaFormats: [])
            ])
        }
    }

    @Test("Canon contribution is isolated from a generic-only composition")
    func canonIsolation() throws {
        let generic = try MediaFormatRegistry(definitions: GenericMediaSupport.definition().mediaFormats)
        #expect(generic.variant(forFilename: "IMG.JPG") == .renderedImage)
        #expect(generic.variant(forFilename: "CLIP.MP4") == .movie)
        #expect(generic.variant(forFilename: "IMG.CR3") == nil)
        #expect(generic.variant(forFilename: "IMG.CR2") == nil)

        let identity = CameraIdentity(reportedName: "Canon EOS R", productKind: "Camera", usbVendorID: 0, usbProductID: -1)
        #expect(identity.usbVendorID == nil && identity.usbProductID == nil)
        let resolver = CameraSupportResolver(definitions: [GenericMediaSupport.definition(), CanonCameraSupport.definition()])
        #expect(resolver.supportIdentifier(for: identity) == CanonCameraSupport.identifier)
        #expect(resolver.supportIdentifier(for: CameraIdentity(reportedName: "Camera", productKind: "Still Image", usbVendorID: nil, usbProductID: nil)) == nil)
    }

    @Test("Asset display names prefer the concrete extension and otherwise use the role")
    func assetDisplayNames() {
        #expect(AssetVariant.renderedImage.displayName(filename: "IMG.heif") == "HEIF")
        #expect(AssetVariant.raw.displayName(filename: "IMG.cr3") == "CR3")
        #expect(AssetVariant.movie.displayName(filename: nil) == "動画")
        #expect(AssetVariant.renderedImage.displayName(filename: "IMG") == "画像")

        let cardURL = URL(fileURLWithPath: "/Volumes/CARD/DCIM/IMG_0001.HEIF")
        #expect(AssetVariant.renderedImage.displayName(filename: cardURL.lastPathComponent) == "HEIF")
        let cameraReference = CameraAssetReference(
            identifier: "camera-asset",
            filename: "IMG_0001.NEF",
            variant: .raw,
            fileSize: 1,
            captureDate: nil
        )
        #expect(AssetVariant.raw.displayName(filename: cameraReference.filename) == "NEF")
        #expect(AssetVariant.raw.displayName(filename: nil) == "RAW")
    }

    @Test("Fake registration extends scanner, camera builder, and catalog inspection")
    func fakeRegistrationExtendsAllThreePaths() throws {
        let fake = try MediaFormatRegistry(definitions: [
            MediaFormatDefinition(identifier: "fake.rendered", fileExtensions: ["fimg"], variant: .renderedImage),
            MediaFormatDefinition(identifier: "fake.raw", fileExtensions: ["fraw"], variant: .raw)
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-fake-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let renderedURL = root.appendingPathComponent("IMG_0001.FIMG")
        let rawURL = root.appendingPathComponent("IMG_0001.FRAW")
        let otherDirectory = root.appendingPathComponent("OTHER", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        try Data("rendered".utf8).write(to: renderedURL)
        try Data("raw".utf8).write(to: rawURL)
        try Data("other".utf8).write(to: otherDirectory.appendingPathComponent("IMG_0001.FIMG"))

        let scannerGroups = PhotoScanner(classifier: fake, traversalPolicy: FilesystemTraversalPolicy()).scan(
            root: root,
            initialPresentationBatchSize: .max,
            initialPresentationGroupTarget: .max,
            progress: nil
        )
        let scanned = try #require(scannerGroups.first { $0.directory.standardizedFileURL == root.standardizedFileURL })
        #expect(scannerGroups.count == 2)
        #expect(scanned.variants == [.renderedImage, .raw])
        #expect(scannerGroups.contains { $0.directory.standardizedFileURL == otherDirectory.standardizedFileURL && $0.variants == [.renderedImage] })
        #expect(Set(scannerGroups.map(\.id)).count == 2)

        let fakeEntries = [
            CameraCatalogEntry(asset: CameraCatalogAsset(identifier: "fimg", filename: "IMG_0001.FIMG", remotePath: "DCIM/IMG_0001.FIMG", variant: .renderedImage, fileSize: 8, captureDate: nil, width: 0, height: 0), pairedRaw: CameraCatalogAsset(identifier: "fraw", filename: "IMG_0001.FRAW", remotePath: "DCIM/IMG_0001.FRAW", variant: .raw, fileSize: 3, captureDate: nil, width: 0, height: 0))
        ]
        let cameraGroups = CameraCatalogBuilder.groups(cameraID: "fake", cameraName: nil, entries: fakeEntries, previousGroups: [], classifier: fake)
        let cameraGroup = try #require(cameraGroups.first)
        #expect(Set(cameraGroup.cameraReference?.assets.map(\.variant) ?? []) == Set([.renderedImage, .raw]))

        let store = try CatalogStore(libraryRoot: root, classifier: fake)
        let inspection = try store.inspectLibrary()
        #expect(inspection.summary.unregisteredPhotoCount == 3)
    }

    @Test("Canon traversal rule skips management directories only when contributed")
    func canonTraversalContribution() throws {
        let fake = try MediaFormatRegistry(definitions: [
            MediaFormatDefinition(identifier: "fake.rendered", fileExtensions: ["fimg"], variant: .renderedImage)
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photokichin-traversal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, directoryName) in ["CANONMSC", "canonmsc", "CaNoNmSc"].enumerated() {
            let management = root.appendingPathComponent("PARENT_\(index)", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: management, withIntermediateDirectories: true)
            try Data("test".utf8).write(to: management.appendingPathComponent("ONLY.FIMG"))
        }

        let genericOnly = PhotoScanner(classifier: fake, traversalPolicy: FilesystemTraversalPolicy()).scan(root: root, initialPresentationBatchSize: .max, initialPresentationGroupTarget: .max, progress: nil)
        #expect(genericOnly.count == 3)
        let canonPolicy = FilesystemTraversalPolicy(rules: CanonCameraSupport.definition().filesystemTraversalRules)
        let canonSupported = PhotoScanner(classifier: fake, traversalPolicy: canonPolicy).scan(root: root, initialPresentationBatchSize: .max, initialPresentationGroupTarget: .max, progress: nil)
        #expect(canonSupported.isEmpty)
    }

    @Test("Generic metadata extraction is standard-only and keeps scalar maker context")
    func genericMetadataExtraction() throws {
        let properties: [String: Any] = [
            "{Exif}": [
                "DateTimeOriginal": "2026:08:22 12:34:56",
                "LensModel": "Generic Lens",
                "FocalLength": 50.0,
                "FNumber": 2.8,
                "ExposureTime": 0.008,
                "ISOSpeedRatings": 800,
                "ExposureBiasValue": -1.0,
                "FirmwareVersion": "Generic Firmware"
            ],
            "{TIFF}": [
                "Make": "Nikon",
                "Model": "Nikon Z"
            ],
            "{GPS}": [
                "Latitude": [35.0, 0.0, 0.0],
                "Longitude": [139.0, 0.0, 0.0],
                "LatitudeRef": "N",
                "LongitudeRef": "E"
            ],
            "Orientation": 6,
            "PixelWidth": 4000,
            "PixelHeight": 3000,
            "{MakerFoo}": [
                "StringValue": "foo",
                "NumberValue": NSNumber(value: 42),
                "ArrayValue": [1, 2],
                "DictionaryValue": ["nested": "ignored"]
            ]
        ]

        let extracted = GenericMetadataExtraction().extract(properties: properties, filename: "IMG_0001.CR3")
        #expect(extracted.context.filename == "IMG_0001.CR3")
        #expect(extracted.metadata.cameraMake == "Nikon")
        #expect(extracted.metadata.cameraModel == "Nikon Z")
        #expect(extracted.metadata.lensModel == "Generic Lens")
        #expect(extracted.metadata.focalLength == "50 mm")
        #expect(extracted.metadata.aperture != nil)
        #expect(extracted.metadata.shutterSpeed != nil)
        #expect(extracted.metadata.iso == "ISO 800")
        #expect(extracted.metadata.exposureBias == "-1 EV")
        #expect(extracted.metadata.orientation == "時計回り90度")
        #expect(extracted.metadata.gps == "35.000000, 139.000000")
        #expect(extracted.metadata.firmware == "Generic Firmware")
        #expect(extracted.metadata.pixelWidth == 4000)
        #expect(extracted.metadata.pixelHeight == 3000)

        let maker = try #require(extracted.context.makerNamespace(named: "{makerfoo}"))
        #expect(maker["StringValue"] == .string("foo"))
        #expect(maker["NumberValue"]?.intValue == 42)
        #expect(maker["ArrayValue"] == nil)
        #expect(maker["DictionaryValue"] == nil)
    }

    @Test("Canon metadata is contributed only by the Canon pipeline")
    func canonMetadataEnrichmentIsolation() throws {
        let canonPipeline = MetadataEnrichmentPipeline(enrichers: [CanonMetadataEnricher()])

        let missingGenericProperties: [String: Any] = [
            "{MakerCanon}": [
                "LensModel": "Canon Lens",
                "FirmwareVersion": "Canon Firmware"
            ]
        ]
        let genericOnlyExtracted = GenericMetadataExtraction().extract(
            properties: missingGenericProperties,
            filename: "IMG_0001.CR3"
        )
        let genericOnly = MetadataEnrichmentPipeline().apply(
            genericOnlyExtracted.metadata,
            context: genericOnlyExtracted.context
        )
        #expect(genericOnly.lensModel == nil)
        #expect(genericOnly.firmware == nil)

        let standardMake = GenericMetadataExtraction().extract(
            properties: [
                "{TIFF}": ["Make": "Canon", "Model": "Other Camera"],
                "{MakerCanon}": ["LensModel": "Make Lens", "FirmwareVersion": "Make Firmware"]
            ],
            filename: "IMG_0002.CR3"
        )
        let makeResult = canonPipeline.apply(standardMake.metadata, context: standardMake.context)
        #expect(makeResult.lensModel == "Make Lens")
        #expect(makeResult.firmware == "Make Firmware")

        let standardModel = GenericMetadataExtraction().extract(
            properties: [
                "{TIFF}": ["Make": "Other Maker", "Model": "Canon Camera"],
                "{MakerCanon}": ["LensModel": "Model Lens", "FirmwareVersion": "Model Firmware"]
            ],
            filename: "IMG_0003.CR3"
        )
        let modelResult = canonPipeline.apply(standardModel.metadata, context: standardModel.context)
        #expect(modelResult.lensModel == "Model Lens")
        #expect(modelResult.firmware == "Model Firmware")

        let productionResult = InfrastructureComposition.production().metadataPipeline.apply(
            PhotoMetadata.empty,
            context: standardMake.context
        )
        #expect(productionResult.lensModel == "Make Lens")
        #expect(productionResult.firmware == "Make Firmware")

        let makerOnlyProperties: [String: Any] = [
            "{TIFF}": ["Make": "Nikon", "Model": "Nikon Z"],
            "{MakerCanon}": ["LensModel": "Maker Lens", "FirmwareVersion": "Maker Firmware"]
        ]
        let makerOnly = GenericMetadataExtraction().extract(properties: makerOnlyProperties, filename: "IMG_0004.JPG")
        let makerOnlyResult = canonPipeline.apply(makerOnly.metadata, context: makerOnly.context)
        #expect(makerOnlyResult.lensModel == "Maker Lens")
        #expect(makerOnlyResult.firmware == "Maker Firmware")

        let cr3OnlyContext = MetadataEnrichmentContext(filename: "IMG_0005.CR3")
        let cr3OnlyResult = canonPipeline.apply(.empty, context: cr3OnlyContext)
        #expect(cr3OnlyResult.lensModel == nil)
        #expect(cr3OnlyResult.firmware == nil)
    }

    @Test("Canon enrichment never overwrites generic fields and pipeline continues after failure")
    func metadataEnrichmentFailureAndPrecedence() {
        let pipeline = MetadataEnrichmentPipeline(enrichers: [
            ThrowingMetadataEnricher(),
            LaterMetadataEnricher()
        ])
        let generic = PhotoMetadata(
            captureDate: nil,
            cameraMake: "Generic Make",
            cameraModel: "Generic Model",
            lensModel: "Generic Lens",
            focalLength: nil,
            aperture: nil,
            shutterSpeed: nil,
            iso: nil,
            exposureBias: nil,
            orientation: nil,
            gps: nil,
            firmware: "Generic Firmware",
            pixelWidth: nil,
            pixelHeight: nil
        )
        let result = pipeline.apply(generic, context: MetadataEnrichmentContext())
        #expect(result.lensModel == "Generic Lens")
        #expect(result.firmware == "Generic Firmware")
        #expect(result.cameraModel == "Later Marker")

        let properties: [String: Any] = [
            "{Exif}": [
                "LensModel": "Generic Lens",
                "FirmwareVersion": "Generic Firmware"
            ],
            "{TIFF}": ["Make": "Canon"],
            "{MakerCanon}": [
                "LensModel": "Canon Lens",
                "FirmwareVersion": "Canon Firmware"
            ]
        ]
        let extracted = GenericMetadataExtraction().extract(properties: properties, filename: "IMG.CR3")
        let resultWithCanon = MetadataEnrichmentPipeline(enrichers: [CanonMetadataEnricher()]).apply(
            extracted.metadata,
            context: extracted.context
        )
        #expect(resultWithCanon.lensModel == "Generic Lens")
        #expect(resultWithCanon.firmware == "Generic Firmware")
    }

    @Test("URL and USB metadata paths use the same enrichment pipeline")
    func urlAndUSBMetadataPaths() throws {
        let pipeline = MetadataEnrichmentPipeline(enrichers: [CanonMetadataEnricher(), MarkerMetadataEnricher()])
        let reader = ImageIOMediaReader(pipeline: pipeline)
        let directProperties: [AnyHashable: Any] = [
            "{TIFF}": ["Make": "Canon", "Model": "Canon EOS"],
            "{MakerCanon}": ["LensModel": "Canon Lens", "FirmwareVersion": "Canon Firmware"]
        ]
        let usbMetadata = try #require(reader.readMetadata(properties: directProperties, filename: "IMG.CR3"))
        #expect(usbMetadata.lensModel == "Canon Lens")
        #expect(usbMetadata.firmware == "pipeline-marker")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-metadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("IMG.JPG")
        var pixels: [UInt8] = [255, 0, 0, 255]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: &pixels,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon",
                kCGImagePropertyTIFFModel: "Canon EOS"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "Canon Lens",
                "FirmwareVersion": "Canon Firmware"
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let urlMetadata = try #require(reader.readMetadata(url: url))
        #expect(urlMetadata.cameraMake == "Canon")
        #expect(urlMetadata.lensModel == "Canon Lens")
        #expect(urlMetadata.firmware == "pipeline-marker")
    }

    @Test(
        "Provided real samples can be inspected through ImageIO",
        .enabled(if: imageIOSampleTestEnabled, "PHOTOKICHIN_IMAGEIO_SAMPLES=label=/absolute/path\n... のときだけ実行します")
    )
    func imageIOSampleFiles() throws {
        let manifest = try #require(imageIOSampleManifest)
        let entries = manifest.split(whereSeparator: \.isNewline).compactMap { line -> (label: String, url: URL)? in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("#"),
                  let separator = text.firstIndex(of: "=") else { return nil }
            let label = String(text[..<separator]).trimmingCharacters(in: .whitespaces)
            let path = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !path.isEmpty, path.hasPrefix("/") else { return nil }
            return (label, URL(fileURLWithPath: path))
        }
        try #require(!entries.isEmpty, "PHOTOKICHIN_IMAGEIO_SAMPLES に有効な label=/absolute/path がありません")

        let reader = ImageIOMediaReader(pipeline: InfrastructureComposition.production().metadataPipeline)
        for entry in entries {
            try #require(
                FileManager.default.fileExists(atPath: entry.url.path),
                "ImageIO sample がありません: \(entry.label) -> \(entry.url.path)"
            )
            let source = try #require(
                CGImageSourceCreateWithURL(entry.url as CFURL, nil),
                "ImageIO source を作成できません: \(entry.label) -> \(entry.url.path)"
            )
            let properties = try #require(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                "ImageIO properties を取得できません: \(entry.label)"
            )
            _ = try #require(
                reader.thumbnailData(url: entry.url, maxPixel: 512),
                "ImageIO thumbnail を生成できません: \(entry.label)"
            )
            let metadata = try #require(
                reader.readMetadata(url: entry.url),
                "metadata を取得できません: \(entry.label)"
            )
            let width = try #require(
                properties[kCGImagePropertyPixelWidth as String] as? Int,
                "ImageIO width がありません: \(entry.label)"
            )
            let height = try #require(
                properties[kCGImagePropertyPixelHeight as String] as? Int,
                "ImageIO height がありません: \(entry.label)"
            )
            let captureDate = try #require(metadata.captureDate, "captureDate がありません: \(entry.label)")
            let cameraMake = try #require(metadata.cameraMake, "cameraMake がありません: \(entry.label)")
            let cameraModel = try #require(metadata.cameraModel, "cameraModel がありません: \(entry.label)")
            let lensModel = try #require(metadata.lensModel, "lensModel がありません: \(entry.label)")
            let orientation = try #require(metadata.orientation, "orientation がありません: \(entry.label)")
            _ = try #require(metadata.pixelWidth, "metadata pixelWidth がありません: \(entry.label)")
            _ = try #require(metadata.pixelHeight, "metadata pixelHeight がありません: \(entry.label)")
            print(
                "ImageIO sample \(entry.label): " +
                "captureDate=\(captureDate), " +
                "make=\(cameraMake), " +
                "model=\(cameraModel), " +
                "lens=\(lensModel), " +
                "orientation=\(orientation), " +
                "dimensions=\(width)x\(height)"
            )
        }
    }

    @Test("Generic consumers do not embed vendor format knowledge")
    func genericArchitectureGuard() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let genericSources = [
            "Sources/PhotokichinInfrastructure/FileSystem/PhotoScanner.swift",
            "Sources/PhotokichinInfrastructure/Camera/CameraServices.swift",
            "Sources/PhotokichinInfrastructure/Catalog/CatalogStore.swift",
            "Sources/PhotokichinInfrastructure/FileSystem/MetadataReading.swift",
            "Sources/PhotokichinInfrastructure/FileSystem/FileTransfer.swift"
        ]
        let forbidden = [
            "MakerCanon",
            "CANONMSC",
            "\"EOS R\"",
            "AssetVariant.jpeg",
            "jpegURL",
            "importedJPEG",
            "possibleImportedJPEG",
            "jpegAndRaw",
            "jpegOnly"
        ]
        let forbiddenQuotedExtensions = [
            "\"jpg\"", "\"jpeg\"", "\"hif\"", "\"heif\"", "\"heic\"",
            "\"cr3\"", "\"cr2\"", "\"arw\"", "\"nef\"", "\"raf\"", "\"rw2\"",
            "\"orf\"", "\"pef\"", "\"dng\"", "\"mov\"", "\"mp4\"", "\"nev\"", "\"x3f\""
        ]
        let forbiddenQuotedManufacturers = [
            "\"Canon\"", "\"Sony\"", "\"Nikon\"", "\"FUJIFILM\"", "\"Panasonic\"",
            "\"LUMIX\"", "\"Olympus\"", "\"OM SYSTEM\"", "\"OM Digital Solutions\"",
            "\"PENTAX\"", "\"RICOH\"", "\"SIGMA\""
        ]
        let baselineUncheckedSendableCounts = [
            "Sources/PhotokichinInfrastructure/FileSystem/PhotoScanner.swift": 0,
            "Sources/PhotokichinInfrastructure/Camera/CameraServices.swift": 1,
            "Sources/PhotokichinInfrastructure/Catalog/CatalogStore.swift": 1,
            "Sources/PhotokichinInfrastructure/FileSystem/MetadataReading.swift": 0,
            "Sources/PhotokichinInfrastructure/FileSystem/FileTransfer.swift": 0
        ]
        func offsets(of tokens: [String], in contents: String) -> [Int] {
            tokens.compactMap { token in
                guard let range = contents.range(of: token) else { return nil }
                return contents.distance(from: contents.startIndex, to: range.lowerBound)
            }
        }

        for relativePath in genericSources {
            let source = repositoryRoot.appendingPathComponent(relativePath)
            let contents = try String(contentsOf: source, encoding: .utf8)
            for token in forbidden + forbiddenQuotedExtensions + forbiddenQuotedManufacturers {
                #expect(!contents.localizedCaseInsensitiveContains(token), "\(relativePath) contains forbidden generic-core token: \(token)")
            }
            let uncheckedCount = contents.components(separatedBy: "@unchecked Sendable").count - 1
            #expect(
                uncheckedCount == baselineUncheckedSendableCounts[relativePath],
                "\(relativePath) changed its baseline @unchecked Sendable count"
            )

            if relativePath == "Sources/PhotokichinInfrastructure/FileSystem/PhotoScanner.swift" {
                let order = offsets(of: [
                    "traversalPolicy.shouldSkipDirectory",
                    "classifier.variant(forFilename:",
                    "url.resourceValues(forKeys:"
                ], in: contents)
                #expect(order.count == 3, "PhotoScanner order guard could not find all I/O boundaries")
                #expect(order == order.sorted(), "PhotoScanner must check traversal, classifier, then resourceValues")
            }

            if relativePath == "Sources/PhotokichinInfrastructure/Catalog/CatalogStore.swift",
               let functionRange = contents.range(of: "private func photoFiles(in root: URL)") {
                let functionBody = String(contents[functionRange.upperBound...])
                let order = offsets(of: [
                    "classifier.variant(forFilename:",
                    "url.resourceValues(forKeys:"
                ], in: functionBody)
                #expect(order.count == 2, "CatalogStore photoFiles order guard could not find both boundaries")
                #expect(order == order.sorted(), "CatalogStore photoFiles must classify before resourceValues")
            }
        }
    }
}
