import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PhotoScanner {
    static func scan(
        root: URL,
        initialPresentationBatchSize: Int = .max,
        initialPresentationGroupTarget: Int = .max,
        progress: @escaping @Sendable ([PhotoGroup], Int) -> Void = { _, _ in }
    ) -> [PhotoGroup] {
        // Ask the card for file attributes only after the extension identifies
        // a photo or movie. Removable media can contain thousands of control
        // and sidecar files, and each resourceValues call can be a separate
        // round trip to the card reader.
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var groups: [String: PhotoGroup] = [:]
        var supportedFileCount = 0
        let presentationBatchSize = max(1, initialPresentationBatchSize)
        let presentationTarget = max(1, initialPresentationGroupTarget)
        var nextPresentationCount = min(presentationBatchSize, presentationTarget)
        for case let url as URL in enumerator {
            if Task.isCancelled { return [] }
            // Canon's management area is intentionally read-only and is not a
            // photo source. Avoid descending into it at all.
            if url.hasDirectoryPath,
               url.lastPathComponent.caseInsensitiveCompare("CANONMSC") == .orderedSame {
                enumerator.skipDescendants()
                continue
            }

            // This check must precede resourceValues: unsupported files such
            // as CTG and camera control files should not touch the card again.
            guard let variant = variant(for: url) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            supportedFileCount += 1
            let key = url.deletingPathExtension().standardizedFileURL.path
            let fallbackDate = values.contentModificationDate
            var group = groups[key] ?? PhotoGroup(
                id: key,
                basename: url.deletingPathExtension().lastPathComponent,
                directory: url.deletingLastPathComponent(),
                jpegURL: nil,
                rawURL: nil,
                movieURL: nil,
                captureDate: fallbackDate,
                metadata: .empty,
                importedJPEG: false,
                importedRAW: false,
                isMetadataLoaded: false
            )

            switch variant {
            case .jpeg: group.jpegURL = url
            case .raw: group.rawURL = url
            case .movie: group.movieURL = url
            }
            groups[key] = group

            // Build the initial list one renderable grid row at a time. Both
            // the row width and the upper bound come from the measured list
            // layout, so the scanner contains no fixed photo/file threshold.
            // Once the visible viewport and its adjacent prefetch viewports
            // are populated, visibility tracking owns further scheduling.
            if groups.count >= nextPresentationCount,
               nextPresentationCount <= presentationTarget {
                progress(sortedGroups(groups), supportedFileCount)
                if nextPresentationCount == presentationTarget {
                    nextPresentationCount = .max
                } else {
                    nextPresentationCount = min(
                        presentationTarget,
                        nextPresentationCount + presentationBatchSize
                    )
                }
            }
        }

        let result = sortedGroups(groups)
        progress(result, supportedFileCount)
        return result
    }

    private static func sortedGroups(_ groups: [String: PhotoGroup]) -> [PhotoGroup] {
        var result = groups.values.sorted {
            if $0.captureDate != $1.captureDate { return ($0.captureDate ?? .distantFuture) < ($1.captureDate ?? .distantFuture) }
            return $0.basename.localizedStandardCompare($1.basename) == .orderedAscending
        }
        for index in result.indices {
            result[index].presentationOrder = index
        }
        return result
    }

    private static func variant(for url: URL) -> AssetVariant? {
        switch normalizedExtension(url) {
        case "jpg", "jpeg": return .jpeg
        case "cr3": return .raw
        case "mov", "mp4": return .movie
        default: return nil
        }
    }
}

struct ImageIOReader {
    private static let exifDateFormatterLock = NSLock()
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // EXIF DateTimeOriginal has no timezone field in the common Canon
        // representation. Treat it as the camera's local wall-clock time so
        // date grouping does not shift an evening shoot into the next day.
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    static func readMetadata(url: URL) -> PhotoMetadata? {
        guard let source = imageSource(for: url),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        let exif = properties["{Exif}"] as? [String: Any] ?? [:]
        let tiff = properties["{TIFF}"] as? [String: Any] ?? [:]
        let maker = properties["{MakerCanon}"] as? [String: Any] ?? [:]
        let gps = properties["{GPS}"] as? [String: Any] ?? [:]

        let dateString = (exif["DateTimeOriginal"] as? String) ?? (exif["DateTimeDigitized"] as? String)
        let date = parseExifDate(dateString)
        let make = stringValue(tiff["Make"])
        let model = stringValue(tiff["Model"])
        let lens = stringValue(exif["LensModel"]) ?? stringValue(maker["LensModel"])
        let focal = formatFocalLength(exif["FocalLength"])
        let aperture = formatNumber(exif["FNumber"], prefix: "f/")
        let shutter = formatExposure(exif["ExposureTime"])
        let iso = formatISO(exif["ISOSpeedRatings"] ?? exif["PhotographicSensitivity"])
        let bias = formatNumber(exif["ExposureBiasValue"], prefix: "")
        let orientation = orientationName(properties["Orientation"])
        let gpsString = formatGPS(gps)
        let firmware = stringValue(maker["FirmwareVersion"]) ?? stringValue(exif["FirmwareVersion"])
        let width = intValue(properties["PixelWidth"])
        let height = intValue(properties["PixelHeight"])

        return PhotoMetadata(
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
    }

    static func thumbnailData(url: URL, maxPixel: Int) -> Data? {
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

    private static func imageSource(for url: URL) -> CGImageSource? {
        // Keep the removable-volume safety behavior: ImageIO must own a
        // complete in-memory snapshot so it cannot lazily touch an SD card
        // after the read operation has finished. A local library does not
        // have that unplug race, so let ImageIO read only the portions it
        // needs instead of allocating a Data buffer for the entire JPG/CR3.
        if url.standardizedFileURL.path.hasPrefix("/Volumes/") {
            guard let data = try? Data(contentsOf: url, options: []) else { return nil }
            return CGImageSourceCreateWithData(data as CFData, nil)
        }
        return CGImageSourceCreateWithURL(url as CFURL, nil)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func formatNumber(_ value: Any?, prefix: String) -> String? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return "\(prefix)\(double == floor(double) ? String(format: "%.0f", double) : String(format: "%.2f", double))"
    }

    private static func formatFocalLength(_ value: Any?) -> String? {
        guard let number = value as? NSNumber else { return nil }
        return String(format: "%.0f mm", number.doubleValue)
    }

    private static func formatISO(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return "ISO \(number.intValue)" }
        if let values = value as? [NSNumber], let first = values.first { return "ISO \(first.intValue)" }
        return stringValue(value)
    }

    private static func formatExposure(_ value: Any?) -> String? {
        guard let number = value as? NSNumber else { return nil }
        let seconds = number.doubleValue
        if seconds >= 1 { return String(format: "%.2f s", seconds) }
        return String(format: "1/%.0f s", 1 / seconds)
    }

    private static func orientationName(_ value: Any?) -> String? {
        guard let number = value as? NSNumber else { return nil }
        switch number.intValue {
        case 1: return "標準"
        case 3: return "180度回転"
        case 6: return "時計回り90度"
        case 8: return "反時計回り90度"
        default: return "EXIF \(number.intValue)"
        }
    }

    private static func formatGPS(_ gps: [String: Any]) -> String? {
        guard let lat = coordinate(gps["Latitude"]), let lon = coordinate(gps["Longitude"]) else { return nil }
        let latRef = stringValue(gps["LatitudeRef"]) == "S" ? -1.0 : 1.0
        let lonRef = stringValue(gps["LongitudeRef"]) == "W" ? -1.0 : 1.0
        return String(format: "%.6f, %.6f", lat * latRef, lon * lonRef)
    }

    private static func coordinate(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let values = value as? [NSNumber], values.count >= 3 {
            return values[0].doubleValue + values[1].doubleValue / 60 + values[2].doubleValue / 3600
        }
        return nil
    }

    private static func parseExifDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return exifDateFormatterLock.withLock {
            exifDateFormatter.date(from: value)
        }
    }
}
