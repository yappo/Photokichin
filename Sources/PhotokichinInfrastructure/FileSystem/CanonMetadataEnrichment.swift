import PhotokichinDomain

/// Canon's MakerNote contribution is kept outside the generic ImageIO reader.
struct CanonMetadataEnricher: MetadataEnricher {
    func enrich(_ metadata: inout PhotoMetadata, context: MetadataEnrichmentContext) throws {
        let standardNames = [context.standardMake, context.standardModel, metadata.cameraMake, metadata.cameraModel]
            .compactMap { $0 }
        let isCanon = standardNames.contains {
            $0.range(of: "Canon", options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        guard isCanon || context.makerNamespace(named: "{MakerCanon}") != nil else { return }
        guard let canon = context.makerNamespace(named: "{MakerCanon}") else { return }

        if metadata.lensModel == nil {
            metadata.lensModel = scalar(named: "LensModel", in: canon)
        }
        if metadata.firmware == nil {
            metadata.firmware = scalar(named: "FirmwareVersion", in: canon)
        }
    }

    private func scalar(named name: String, in values: [String: MetadataScalar]) -> String? {
        values.first { key, _ in key.caseInsensitiveCompare(name) == .orderedSame }?.value.stringValue
    }
}
