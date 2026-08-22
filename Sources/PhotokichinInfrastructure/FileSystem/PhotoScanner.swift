import Foundation
import PhotokichinApplication
import PhotokichinDomain

struct PhotoScanner: PhotoScanning {
    private let classifier: any MediaFormatClassifying
    private let traversalPolicy: FilesystemTraversalPolicy

    init(
        classifier: any MediaFormatClassifying,
        traversalPolicy: FilesystemTraversalPolicy
    ) {
        self.classifier = classifier
        self.traversalPolicy = traversalPolicy
    }

    func scan(
        root: URL,
        initialPresentationBatchSize: Int,
        initialPresentationGroupTarget: Int,
        progress: (@Sendable ([PhotoGroup], Int) -> Void)?
    ) -> [PhotoGroup] {
        Self.scan(
            root: root,
            initialPresentationBatchSize: initialPresentationBatchSize,
            initialPresentationGroupTarget: initialPresentationGroupTarget,
            progress: progress ?? { _, _ in },
            classifier: classifier,
            traversalPolicy: traversalPolicy
        )
    }

    private static func scan(
        root: URL,
        initialPresentationBatchSize: Int,
        initialPresentationGroupTarget: Int,
        progress: @escaping @Sendable ([PhotoGroup], Int) -> Void,
        classifier: any MediaFormatClassifying,
        traversalPolicy: FilesystemTraversalPolicy
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
            // Support contributions own directory traversal rules. Evaluate
            // them before classification or any resource access so skipped
            // subtrees never cause a card round trip.
            if url.hasDirectoryPath, traversalPolicy.shouldSkipDirectory(url) {
                enumerator.skipDescendants()
                continue
            }

            // This check must precede resourceValues: unsupported files such
            // as CTG and camera control files should not touch the card again.
            guard let variant = classifier.variant(forFilename: url.lastPathComponent) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            supportedFileCount += 1
            let key = url.deletingPathExtension().standardizedFileURL.path
            let fallbackDate = values.contentModificationDate
            var group = groups[key] ?? PhotoGroup(
                id: key,
                basename: url.deletingPathExtension().lastPathComponent,
                directory: url.deletingLastPathComponent(),
                renderedImageURL: nil,
                rawURL: nil,
                movieURL: nil,
                captureDate: fallbackDate,
                metadata: .empty,
                importedRenderedImage: false,
                importedRAW: false,
                isMetadataLoaded: false
            )

            switch variant {
            case .renderedImage: group.renderedImageURL = url
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

}
