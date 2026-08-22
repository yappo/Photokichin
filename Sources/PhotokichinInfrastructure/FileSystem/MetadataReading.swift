import Foundation
import ImageIO
import UniformTypeIdentifiers
import PhotokichinApplication
import PhotokichinDomain

protocol MetadataDictionaryReading: Sendable {
    func readMetadata(properties: [AnyHashable: Any], filename: String?) -> PhotoMetadata?
}

struct MetadataEnrichmentPipeline: Sendable {
    let enrichers: [any MetadataEnricher]

    init(enrichers: [any MetadataEnricher] = []) {
        self.enrichers = enrichers
    }

    func apply(
        _ metadata: PhotoMetadata,
        context: MetadataEnrichmentContext
    ) -> PhotoMetadata {
        var result = metadata
        for enricher in enrichers {
            do {
                try enricher.enrich(&result, context: context)
            } catch {
                // An optional vendor contribution must never discard the
                // standard metadata, and one failed contribution must not
                // prevent later contributions from being attempted.
            }
        }
        return result
    }
}

struct GenericMetadataExtraction: Sendable {
    private static let exifDateFormatterLock = NSLock()
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // EXIF DateTimeOriginal has no timezone field in the common camera
        // representation. Treat it as the camera's local wall-clock time so
        // date grouping does not shift an evening shoot into another day.
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    func extract(
        properties: [String: Any],
        filename: String?
    ) -> (metadata: PhotoMetadata, context: MetadataEnrichmentContext) {
        let exif = nestedDictionary(properties["{Exif}"])
        let tiff = nestedDictionary(properties["{TIFF}"])
        let gps = nestedDictionary(properties["{GPS}"])
        let dateString = stringValue(exif["DateTimeOriginal"]) ?? stringValue(exif["DateTimeDigitized"])
        let date = parseExifDate(dateString)
        let make = stringValue(tiff["Make"])
        let model = stringValue(tiff["Model"])
        let lens = stringValue(exif["LensModel"])
        let focal = formatFocalLength(exif["FocalLength"])
        let aperture = formatNumber(exif["FNumber"], prefix: "f/")
        let shutter = formatExposure(exif["ExposureTime"])
        let iso = formatISO(exif["ISOSpeedRatings"] ?? exif["PhotographicSensitivity"])
        let bias = formatNumber(exif["ExposureBiasValue"], prefix: "")
        let orientation = orientationName(properties["Orientation"])
        let gpsString = formatGPS(gps)
        let firmware = stringValue(exif["FirmwareVersion"])
        let width = intValue(properties["PixelWidth"] ?? properties["ImageWidth"])
        let height = intValue(properties["PixelHeight"] ?? properties["ImageHeight"])

        let metadata = PhotoMetadata(
            captureDate: date,
            cameraMake: make,
            cameraModel: model,
            lensModel: lens,
            focalLength: focal,
            aperture: aperture,
            shutterSpeed: shutter,
            iso: iso,
            exposureBias: bias.map { "\($0) EV" },
            orientation: orientation,
            gps: gpsString,
            firmware: firmware,
            pixelWidth: width,
            pixelHeight: height
        )
        let context = MetadataEnrichmentContext(
            filename: filename,
            standardMake: make,
            standardModel: model,
            makerNamespaces: makerNamespaces(in: properties)
        )
        return (metadata, context)
    }

    private func makerNamespaces(in properties: [String: Any]) -> [String: [String: MetadataScalar]] {
        properties.reduce(into: [String: [String: MetadataScalar]]()) { result, entry in
            let key = entry.key
            guard key.hasPrefix("{Maker"), key.hasSuffix("}") else { return }
            let values = nestedDictionary(entry.value).reduce(into: [String: MetadataScalar]()) { scalars, item in
                guard let scalar = scalarValue(item.value) else { return }
                scalars[item.key] = scalar
            }
            result[key] = values
        }
    }

    private func nestedDictionary(_ value: Any?) -> [String: Any] {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let dictionary = value as? [AnyHashable: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[String(describing: entry.key)] = entry.value
            }
        }
        return [:]
    }

    private func scalarValue(_ value: Any) -> MetadataScalar? {
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber { return .number(value.doubleValue) }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func numberValue(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        guard let value = numberValue(value) else { return nil }
        return Int(value)
    }

    private func formatNumber(_ value: Any?, prefix: String) -> String? {
        guard let double = numberValue(value) else { return nil }
        return "\(prefix)\(double == floor(double) ? String(format: "%.0f", double) : String(format: "%.2f", double))"
    }

    private func formatFocalLength(_ value: Any?) -> String? {
        guard let number = numberValue(value) else { return nil }
        return String(format: "%.0f mm", number)
    }

    private func formatISO(_ value: Any?) -> String? {
        if let number = numberValue(value) { return "ISO \(Int(number))" }
        if let values = value as? [Any], let first = values.first, let number = numberValue(first) {
            return "ISO \(Int(number))"
        }
        if let values = value as? [NSNumber], let first = values.first {
            return "ISO \(first.intValue)"
        }
        return stringValue(value)
    }

    private func formatExposure(_ value: Any?) -> String? {
        guard let seconds = numberValue(value), seconds > 0 else { return nil }
        if seconds >= 1 { return String(format: "%.2f s", seconds) }
        return String(format: "1/%.0f s", 1 / seconds)
    }

    private func orientationName(_ value: Any?) -> String? {
        guard let orientation = intValue(value) else { return nil }
        switch orientation {
        case 1: return "標準"
        case 3: return "180度回転"
        case 6: return "時計回り90度"
        case 8: return "反時計回り90度"
        default: return "EXIF \(orientation)"
        }
    }

    private func formatGPS(_ gps: [String: Any]) -> String? {
        guard let lat = coordinate(gps["Latitude"]), let lon = coordinate(gps["Longitude"]) else { return nil }
        let latRef = stringValue(gps["LatitudeRef"]) == "S" ? -1.0 : 1.0
        let lonRef = stringValue(gps["LongitudeRef"]) == "W" ? -1.0 : 1.0
        return String(format: "%.6f, %.6f", lat * latRef, lon * lonRef)
    }

    private func coordinate(_ value: Any?) -> Double? {
        if let number = numberValue(value) { return number }
        if let values = value as? [Any], values.count >= 3 {
            guard let degrees = numberValue(values[0]),
                  let minutes = numberValue(values[1]),
                  let seconds = numberValue(values[2]) else { return nil }
            return degrees + minutes / 60 + seconds / 3600
        }
        if let values = value as? [NSNumber], values.count >= 3 {
            return values[0].doubleValue + values[1].doubleValue / 60 + values[2].doubleValue / 3600
        }
        return nil
    }

    private func parseExifDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return Self.exifDateFormatterLock.withLock {
            Self.exifDateFormatter.date(from: value)
        }
    }
}

struct ImageIOMediaReader: MediaReading, MetadataDictionaryReading {
    let pipeline: MetadataEnrichmentPipeline
    private let extraction = GenericMetadataExtraction()

    init(pipeline: MetadataEnrichmentPipeline) {
        self.pipeline = pipeline
    }

    func readMetadata(url: URL) -> PhotoMetadata? {
        guard let source = imageSource(for: url),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        return readMetadata(properties: properties, filename: url.lastPathComponent)
    }

    func readMetadata(properties: [AnyHashable: Any], filename: String?) -> PhotoMetadata? {
        let dictionary = properties.reduce(into: [String: Any]()) { result, entry in
            result[String(describing: entry.key)] = entry.value
        }
        return readMetadata(properties: dictionary, filename: filename)
    }

    func thumbnailData(url: URL, maxPixel: Int) -> Data? {
        guard let source = imageSource(for: url) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outputData as Data
    }

    private func readMetadata(properties: [String: Any], filename: String?) -> PhotoMetadata {
        let extracted = extraction.extract(properties: properties, filename: filename)
        return pipeline.apply(extracted.metadata, context: extracted.context)
    }

    private func imageSource(for url: URL) -> CGImageSource? {
        // Keep the removable-volume safety behavior: ImageIO must own a
        // complete in-memory snapshot so it cannot lazily touch an SD card
        // after the read operation has finished.
        if url.standardizedFileURL.path.hasPrefix("/Volumes/") {
            guard let data = try? Data(contentsOf: url, options: []) else { return nil }
            return CGImageSourceCreateWithData(data as CFData, nil)
        }
        return CGImageSourceCreateWithURL(url as CFURL, nil)
    }
}
