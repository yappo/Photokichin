import Foundation
import PhotokichinApplication
import PhotokichinDomain

@MainActor
extension AppModel {
    func replaceGroups(_ groups: [PhotoGroup]) {
        self.groups = groups
        rebuildGroupedPhotos()
    }

    var selectedGroups: [PhotoGroup] {
        selectedIDs.compactMap { groupByID[$0] }
    }

    var focusedGroups: [PhotoGroup] {
        focusedIDs.compactMap { groupByID[$0] }
    }

    var deleteCandidateGroups: [PhotoGroup] {
        deleteCandidateIDs.compactMap { groupByID[$0] }
    }

    var focusedGroup: PhotoGroup? {
        focusedIDs.first.flatMap { groupByID[$0] }
    }

    var viewerGroup: PhotoGroup? {
        guard let viewerGroupID else { return nil }
        return groupByID[viewerGroupID]
    }

    var viewerPositionText: String {
        guard let viewerGroup,
              let index = displayGroups.firstIndex(where: { $0.id == viewerGroup.id }) else { return "" }
        return "\(index + 1) / \(displayGroups.count)"
    }

    var viewerNeighborGroups: [PhotoGroup] {
        guard let viewerGroup,
              let index = displayGroups.firstIndex(where: { $0.id == viewerGroup.id }) else { return [] }
        return [index - 1, index + 1]
            .filter { displayGroups.indices.contains($0) }
            .map { displayGroups[$0] }
    }

    var displayGroups: [PhotoGroup] {
        navigationSections.flatMap { $0 }
    }

    /// The exact photo order rendered by PhotoListView. A date containing
    /// multiple import states is rendered as contiguous state runs without
    /// changing chronology, so keyboard navigation uses those same runs.
    var navigationSections: [[PhotoGroup]] {
        filteredGroupedPhotos.flatMap { day, photos -> [[PhotoGroup]] in
            let clusters = PhotoImportCluster.preservingOrder(dateKey: day, photos: photos)
            return clusters.count > 1 ? clusters.map(\.photos) : [photos]
        }
    }

    var isLibraryView: Bool {
        guard let sourceURL else { return false }
        return libraryURLs.contains { $0.standardizedFileURL == sourceURL.standardizedFileURL }
    }

    var isCameraSource: Bool { sourceCamera != nil }

    var isCameraCataloging: Bool { sourceCamera?.isCataloging == true }

    var canDeleteSourceFiles: Bool {
        if sourceVolume != nil { return true }
        return sourceCamera?.canDeleteFiles == true
    }

    var catalogRootURL: URL? {
        isLibraryView ? sourceURL : libraryURL
    }

    var totalPhotoCount: Int { groups.count }

    var filteredPhotoCount: Int {
        filteredGroupedPhotos.reduce(0) { $0 + $1.1.count }
    }

    package var selectedPhotoCount: Int { selectedIDs.count }

    var deleteCandidatePhotoCount: Int { deleteCandidateIDs.count }

    var focusedPhotoCount: Int { focusedIDs.count }

    var activeLabels: [PhotoLabel] {
        labels.filter { activeLabelIDs.contains($0.id) }
    }

    var availableImportFilters: [PhotoImportFilter] {
        PhotoImportFilter.allCases.filter { filter in
            filter != .possible || isCameraSource
        }
    }

    /// Custom command-menu shortcuts must be disabled while a label sheet is
    /// active so standard text editing commands such as Command-A remain with
    /// the sheet's first responder instead of operating the photo list.
    package var blocksPhotoListCommandShortcuts: Bool {
        isLabelPickerPresented || isLabelManagementPresented
    }

    var labelTargetGroups: [PhotoGroup] {
        let candidates = selectedGroups.isEmpty ? focusedGroups : selectedGroups
        return candidates.filter { $0.photoID != nil && $0.libraryAssetStatus != .unregistered && $0.libraryAssetStatus != .notApplicable }
    }

    var excludedLabelTargetCount: Int {
        let candidates = selectedGroups.isEmpty ? focusedGroups : selectedGroups
        return candidates.count - labelTargetGroups.count
    }

    var canCopyToTargetLibrary: Bool {
        guard isLibraryView,
              let sourceURL,
              let libraryURL,
              sourceURL.standardizedFileURL != libraryURL.standardizedFileURL else { return false }
        return !selectedGroups.isEmpty
    }

    var hasActiveFilters: Bool {
        importFilter != .all || operationFilter != .all || !activeLabelIDs.isEmpty
    }

    var activeFilterDescription: String {
        let filters = [
            importFilter == .all ? nil : "取り込み状態: \(importFilter.title)",
            operationFilter == .all ? nil : "操作状態: \(operationFilter.title)",
            activeLabelIDs.isEmpty ? nil : "ラベル: \(activeLabels.map(\.name).joined(separator: " × "))"
        ].compactMap { $0 }
        return filters.isEmpty ? "すべて" : filters.joined(separator: " × ")
    }

    func selectedCount(in photos: [PhotoGroup]) -> Int {
        photos.reduce(into: 0) { count, photo in
            if selectedIDs.contains(photo.id) { count += 1 }
        }
    }

    func deleteCandidateCount(in photos: [PhotoGroup]) -> Int {
        photos.reduce(into: 0) { count, photo in
            if deleteCandidateIDs.contains(photo.id) { count += 1 }
        }
    }

    func clearSelection(in photos: [PhotoGroup]) {
        selectedIDs.subtract(photos.map(\.id))
    }

    func selectAll(in photos: [PhotoGroup]) {
        let ids = photos.map(\.id)
        selectedIDs.formUnion(ids)
        deleteCandidateIDs.subtract(ids)
    }

    func clearDeleteCandidates(in photos: [PhotoGroup]) {
        deleteCandidateIDs.subtract(photos.map(\.id))
    }

    func markDeleteCandidates(in photos: [PhotoGroup]) {
        guard canDeleteSourceFiles else { return }
        let ids = photos.map(\.id)
        deleteCandidateIDs.formUnion(ids)
        selectedIDs.subtract(ids)
    }

    func rebuildGroupedPhotos() {
        let dictionary = Dictionary(grouping: groups, by: \.dateKey)
        groupedPhotos = dictionary.keys.sorted { lhs, rhs in
            if lhs == "撮影日不明" { return false }
            if rhs == "撮影日不明" { return true }
            return lhs < rhs
        }.map { key in
            (key, dictionary[key, default: []].sorted(by: PhotoGroup.presentationPrecedes))
        }
        rebuildFilteredPhotos()
    }

    func rebuildFilteredPhotos() {
        let matchingPhotoIDs: Set<String>? = activeLabelIDs.isEmpty ? nil : activeLabelIDs
            .compactMap { photoIDsByLabelID[$0] }
            .sorted { $0.count < $1.count }
            .reduce(nil as Set<String>?) { partial, next in
                partial.map { $0.intersection(next) } ?? next
            } ?? []
        filteredGroupedPhotos = groupedPhotos.compactMap { day, photos in
            let filteredPhotos = photos.filter { group in
                group.matches(
                    importFilter: importFilter,
                    operationFilter: operationFilter,
                    selected: selectedIDs.contains(group.id),
                    deleteCandidate: deleteCandidateIDs.contains(group.id)
                ) && matchingPhotoIDs.map { ids in group.photoID.map(ids.contains) ?? false } != false
            }
            return filteredPhotos.isEmpty ? nil : (day, filteredPhotos)
        }

        navigationPositionByID.removeAll(keepingCapacity: true)
        var flatIndex = 0
        for (section, photos) in navigationSections.enumerated() {
            for (indexInSection, photo) in photos.enumerated() {
                navigationPositionByID[photo.id] = NavigationPosition(
                    section: section,
                    indexInSection: indexInSection,
                    flatIndex: flatIndex
                )
                flatIndex += 1
            }
        }
        listContentRevision &+= 1
    }

    func handleFilterChange() {
        let filtering = hasActiveFilters
        if filtering, focusBeforeFilter == nil {
            focusBeforeFilter = focusedIDs
            lastFocusBeforeFilter = lastFocusedID
        }

        rebuildFilteredPhotos()

        if filtering {
            focusFirstVisiblePhoto()
        } else if let focusBeforeFilter {
            let availableIDs = Set(groups.map(\.id))
            let restoredIDs = focusBeforeFilter.intersection(availableIDs)
            focusedIDs = restoredIDs
            lastFocusedID = lastFocusBeforeFilter.flatMap { restoredIDs.contains($0) ? $0 : nil }
                ?? restoredIDs.first
            self.focusBeforeFilter = nil
            lastFocusBeforeFilter = nil
        }
    }

    func focusFirstVisiblePhoto() {
        let first = displayGroups.first
        guard let first else {
            focusedIDs.removeAll()
            lastFocusedID = nil
            return
        }
        focusedIDs = [first.id]
        lastFocusedID = first.id
        requestMetadataForCurrentCameraFocus()
    }

    func requestMetadataForCurrentCameraFocus() {
        guard isCameraSource,
              let focusedGroup = navigationFocusedGroup else { return }
        prioritizeMetadata(for: focusedGroup.id, priority: .viewerCurrent)
    }

    var selectedCountText: String {
        "取り込み \(selectedIDs.count)枚 / 削除 \(deleteCandidateIDs.count)枚"
    }
}
