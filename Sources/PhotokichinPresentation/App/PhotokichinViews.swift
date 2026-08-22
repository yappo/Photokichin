import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import PhotokichinApplication
import PhotokichinDomain

package struct ContentView: View {
    @Bindable var model: AppModel
    @Bindable var viewerWindowManager: ViewerWindowManager
    @State private var showingImportSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var showingAirDropHelp = false
    @State private var showingCatalogManagement = false

    package init(model: AppModel, viewerWindowManager: ViewerWindowManager) {
        self.model = model
        self.viewerWindowManager = viewerWindowManager
    }

    package var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
        } detail: {
            BrowserDetail(model: model, showingImportSheet: $showingImportSheet, showingDeleteConfirmation: $showingDeleteConfirmation, showingCatalogManagement: $showingCatalogManagement)
        }
        .sheet(isPresented: $showingImportSheet) {
            ImportSheet(model: model)
        }
        .sheet(isPresented: $showingCatalogManagement) {
            CatalogManagementView(model: model)
        }
        .sheet(isPresented: $model.isLabelPickerPresented) {
            LabelPickerView(model: model)
        }
        .sheet(isPresented: $model.isLabelManagementPresented) {
            LabelManagementView(model: model)
        }
        .alert("削除の確認", isPresented: $showingDeleteConfirmation) {
            Button(model.sourceCamera == nil ? "ゴミ箱へ移動" : "カメラから削除", role: .destructive) {
                model.deleteCandidatesAfterConfirmation()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(model.sourceCamera == nil
                ? "削除候補にしたJPGとCR3をmacOSのゴミ箱へ移動します。実行前に確認してください。"
                : "削除候補にしたカメラ内のJPGとCR3をカメラから削除します。ゴミ箱には入らず、復元できない場合があります。実行前に確認してください。")
        }
        .alert("Photokichin", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("閉じる", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            model.installKeyMonitor()
            viewerWindowManager.update(model: model)
        }
        .onChange(of: model.viewerGroupID) { _, _ in
            viewerWindowManager.update(model: model)
        }
    }
}

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            Section("接続中のカード") {
                if model.volumeMonitor.volumes.isEmpty {
                    Label("カードが見つかりません", systemImage: "externaldrive.badge.questionmark")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.volumeMonitor.volumes) { volume in
                        Button {
                            model.scan(url: volume.url, volume: volume)
                        } label: {
                            HStack(spacing: 8) {
                                Label(volume.name, systemImage: volume.isEjectable ? "sdcard" : "externaldrive")
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if model.sourceVolume?.url.path == volume.url.path {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                        .help("表示中のSDカード")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.sourceVolume?.url.path == volume.url.path ? Color.accentColor : .primary)
                    }
                }
                Button("フォルダを選択…", systemImage: "folder") { model.chooseSourceFolder() }
                    .buttonStyle(.plain)
            }

            Section("USBカメラ") {
                if model.cameras.isEmpty {
                    Label("カメラが見つかりません", systemImage: "camera.badge.ellipsis")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.cameras) { camera in
                        Button {
                            model.scan(camera: camera)
                        } label: {
                            HStack(spacing: 8) {
                                Label(camera.name, systemImage: "camera")
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(camera.statusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if model.sourceCamera?.id == camera.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.sourceCamera?.id == camera.id ? Color.accentColor : .primary)
                        .disabled(!camera.isReady || model.isBusy)
                    }
                    Text("カメラを開くと写真一覧を準備します。準備中もアプリは操作できます。削除は確認してから実行します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("ライブラリ") {
                if model.libraryURLs.isEmpty {
                    Text("未登録（取り込み時に追加）")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.libraryURLs, id: \.path) { libraryURL in
                        let isOpen = model.isLibraryView
                            && model.sourceURL?.path == libraryURL.path
                        let isTarget = model.libraryURL?.path == libraryURL.path
                        VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Button {
                                model.openLibrary(libraryURL)
                            } label: {
                                Label(libraryURL.lastPathComponent, systemImage: "internaldrive")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(isOpen ? Color.accentColor : .primary)
                            .help("ライブラリを開く: \(libraryURL.path)")
                            Spacer(minLength: 4)
                            Button {
                                if isTarget {
                                    model.clearTargetLibrary()
                                } else {
                                    model.setTargetLibrary(libraryURL)
                                }
                            } label: {
                                Image(systemName: isTarget ? "arrow.down.circle.fill" : "arrow.down.circle")
                                    .foregroundStyle(isTarget ? Color.accentColor : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(isTarget ? "保存先ライブラリを解除" : "保存先ライブラリに設定")
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(isOpen ? Color.accentColor.opacity(0.14) : Color.clear)
                        .help(libraryURL.path)
                        if isOpen {
                            if !model.labels.isEmpty {
                                HStack(spacing: 6) {
                                    Text("ラベル")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Menu {
                                        ForEach(model.labels) { label in
                                            Button {
                                                model.addLabelFilter(label)
                                            } label: {
                                                Label(
                                                    label.name,
                                                    systemImage: model.activeLabelIDs.contains(label.id) ? "checkmark" : "plus"
                                                )
                                            }
                                            .disabled(model.activeLabelIDs.contains(label.id))
                                        }
                                    } label: {
                                        Label("条件追加", systemImage: "plus")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .font(.caption)
                                    .help("現在のラベル条件に追加")
                                }
                                .padding(.leading, 22)

                                if model.activeLabelIDs.count > 1 && model.activeSavedLabelViewID == nil {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(model.activeLabels) { label in
                                            HStack(spacing: 4) {
                                                Circle()
                                                    .fill(Color(labelHex: label.colorHex))
                                                    .frame(width: 8, height: 8)
                                                Text(label.name)
                                                    .lineLimit(1)
                                            }
                                            .foregroundStyle(Color.accentColor)
                                        }
                                        HStack {
                                            Spacer(minLength: 4)
                                            SaveLabelViewButton(
                                                model: model,
                                                buttonTitle: "+ビューに追加",
                                                showsTitle: true
                                            )
                                            .buttonStyle(.borderless)
                                            .controlSize(.small)
                                        }
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                                    }
                                    .padding(.leading, 44)
                                    .padding(.trailing, 4)
                                }

                                ForEach(model.labels) { label in
                                    Button { model.selectSingleLabelFilter(label) } label: {
                                        HStack {
                                            Circle().fill(Color(labelHex: label.colorHex)).frame(width: 9, height: 9)
                                            Text(label.name).lineLimit(1)
                                            Spacer()
                                            if model.activeSavedLabelViewID == nil && model.activeLabelIDs.contains(label.id) {
                                                Image(systemName: "checkmark")
                                            }
                                        }.padding(.leading, 26)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(
                                        model.activeSavedLabelViewID == nil
                                            && model.activeLabelIDs.count == 1
                                            && model.activeLabelIDs.contains(label.id)
                                            ? Color.accentColor
                                            : Color.primary
                                    )
                                }
                            }
                            if !model.savedLabelViews.isEmpty {
                                Text("保存ビュー").font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
                                ForEach(model.savedLabelViews) { view in
                                    Button { model.applySavedLabelView(view) } label: {
                                        Label(view.name, systemImage: "rectangle.stack").padding(.leading, 22)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(model.activeSavedLabelViewID == view.id ? Color.accentColor : Color.primary)
                                }
                            }
                            Button { model.isLabelManagementPresented = true } label: {
                                Label("ラベルを管理…", systemImage: "tag").padding(.leading, 22)
                            }.buttonStyle(.plain)
                        }
                        }
                    }
                }
                Button("ライブラリを追加・開く…", systemImage: "folder.badge.plus") {
                    model.chooseLibrary()
                }
                .buttonStyle(.plain)
            }

            Section("状態") {
                Label(model.progressText, systemImage: model.isBusy || model.isScanning ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.selectedCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Photokichin")
    }
}

private struct BrowserDetail: View {
    @Bindable var model: AppModel
    @Binding var showingImportSheet: Bool
    @Binding var showingDeleteConfirmation: Bool
    @Binding var showingCatalogManagement: Bool

    var body: some View {
        HStack(spacing: 0) {
            PhotoGrid(model: model)
            if model.inspectorShown {
                Divider()
                InspectorView(model: model, group: model.focusedGroup)
                    .frame(width: 270)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("更新", systemImage: "arrow.clockwise") {
                    if let sourceCamera = model.sourceCamera {
                        model.scan(camera: sourceCamera)
                    } else if let sourceURL = model.sourceURL {
                        model.scan(url: sourceURL, volume: model.sourceVolume)
                    }
                }
                .disabled(model.sourceURL == nil || model.isBusy)
                .help("現在の写真一覧を再読み込み")

                Button("ソース", systemImage: "folder.badge.plus") { model.chooseSourceFolder() }
                    .help("写真を表示するフォルダ、SDカード、またはUSBカメラを選択")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(AirDropMode.allCases) { mode in
                        Button {
                            model.airDrop(mode: mode)
                        } label: {
                            Label(mode.title, systemImage: mode.systemImage)
                        }
                    }
                } label: {
                    Label("AirDrop", systemImage: "airplayaudio")
                }
                .disabled(model.selectedPhotoCount == 0 || model.isBusy)
                .help("選択した写真をAirDropで送信")

                Picker(
                    selection: Binding<String>(
                        get: { model.libraryURL?.path ?? "" },
                        set: { path in
                            guard let libraryURL = model.libraryURLs.first(where: { $0.path == path }) else { return }
                            model.setTargetLibrary(libraryURL)
                        }
                    )
                ) {
                    if model.libraryURLs.isEmpty {
                        Text("保存先未設定").tag("")
                    } else {
                        ForEach(model.libraryURLs, id: \.path) { libraryURL in
                            Text(libraryURL.lastPathComponent).tag(libraryURL.path)
                        }
                    }
                } label: {
                    Label(model.libraryURL?.lastPathComponent ?? "保存先未設定", systemImage: "arrow.down.circle")
                }
                .pickerStyle(.menu)
                .disabled(model.isBusy || model.isScanning)
                .help("保存先ライブラリ")

                Button("ターゲットライブラリへ保存", systemImage: "square.and.arrow.down") {
                    showingImportSheet = true
                }
                .disabled(
                    model.isLibraryView
                        ? (!model.canCopyToTargetLibrary || model.isBusy)
                        : (model.selectedPhotoCount == 0 || model.isBusy)
                )
                .help(
                    model.isLibraryView
                        ? "選択した写真をターゲットライブラリへコピー"
                        : "選択した写真をターゲットライブラリへ取り込む"
                )

                Button("ゴミ箱", systemImage: "trash") { showingDeleteConfirmation = true }
                    .disabled(model.deleteCandidatePhotoCount == 0 || model.isBusy || !model.canDeleteSourceFiles)
                    .help("削除候補の写真をゴミ箱へ移動")

                Button("Eject", systemImage: "eject") { model.ejectCurrentVolume() }
                    .disabled(
                            (model.sourceVolume == nil && model.sourceCamera?.canEject != true)
                            || model.isBusy
                            || model.isScanning
                            || model.isCameraCataloging
                    )
                    .help(model.sourceCamera == nil ? "SDカードを安全に取り出す" : "カメラを安全に取り出す")

                Button {
                    model.inspectorShown.toggle()
                } label: {
                    Label("情報", systemImage: model.inspectorShown ? "sidebar.right" : "sidebar.right")
                }
                .help(model.inspectorShown ? "情報インスペクタを隠す" : "情報インスペクタを表示")

                Button("カタログ管理", systemImage: "externaldrive.badge.timemachine") {
                    showingCatalogManagement = true
                    if model.isLibraryView { model.inspectLibrary() }
                }
                .disabled(model.libraryURL == nil)
                .help("ライブラリのカタログを管理")
            }
        }
        .navigationTitle(model.sourceCamera?.name ?? model.sourceURL?.lastPathComponent ?? "Photokichin")
    }
}

private struct PhotoSourceSnapshot {
    let sourcePath: String
    var allGroups: [(String, [PhotoGroup])]
    var filteredGroups: [String: [(String, [PhotoGroup])]]
}

private struct PhotoGrid: View {
    @Bindable var model: AppModel
    @State private var rangeSelectionMode = false
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var sourceSnapshots: [String: PhotoSourceSnapshot] = [:]
    @State private var scrollPositions: [String: ScrollPosition] = [:]

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                SelectionSummaryBar(model: model)
                Divider()
                photoContent
            }
            .onAppear {
                model.updateGridColumnCount(width: geometry.size.width)
                model.updateGridViewport(height: geometry.size.height)
            }
            .onChange(of: geometry.size.width) { _, width in
                model.updateGridColumnCount(width: width)
            }
            .onChange(of: geometry.size.height) { _, height in
                model.updateGridViewport(height: height)
            }
            .onChange(of: model.thumbnailSize) { _, _ in
                model.updateGridColumnCount(width: geometry.size.width)
            }
            .onAppear { captureCurrentSourceSnapshot() }
            .onChange(of: model.sourceURL?.path) { _, _ in captureCurrentSourceSnapshot() }
            .onChange(of: model.listContentRevision) { _, _ in captureCurrentSourceSnapshot() }
            .onChange(of: model.isScanning) { _, scanning in
                if !scanning { captureCurrentSourceSnapshot() }
            }
        }
        .background(PhotoSelectionResponder(model: model).frame(width: 1, height: 1))
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 10) {
                if model.isScanning { ProgressView().controlSize(.small) }
                Text(model.progressText).font(.caption).foregroundStyle(.secondary)
                Divider().frame(height: 16)
                Button {
                    rangeSelectionMode.toggle()
                } label: {
                    Label("範囲選択", systemImage: rangeSelectionMode ? "rectangle.dashed.and.paperclip" : "rectangle.dashed")
                }
                .buttonStyle(.bordered)
                Slider(value: $model.thumbnailSize, in: 90...640)
                    .frame(width: 120)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(14)
        }
    }

    @ViewBuilder
    private var photoContent: some View {
        if model.sourceURL == nil {
            EmptyStateView()
        } else if model.isCameraCataloging && model.groups.isEmpty {
            CameraCatalogLoadingView()
        } else if model.isScanning && model.groups.isEmpty && currentSourceSnapshot == nil {
            ProgressView("写真を探しています…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                if let snapshot = currentSourceSnapshot {
                    SourcePhotoLists(
                        snapshot: snapshot,
                        currentFilterKey: filterKey,
                        scrollPosition: scrollPositionBinding(for: activeListIdentity(in: snapshot)),
                        model: model,
                        rangeSelectionMode: $rangeSelectionMode,
                        dragStart: $dragStart,
                        dragEnd: $dragEnd
                    )
                }

                if model.isCameraCataloging && model.groups.isEmpty {
                    CameraCatalogLoadingView()
                        .background(.background.opacity(0.75))
                } else if model.isScanning && model.groups.isEmpty {
                    ProgressView("写真を探しています…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background.opacity(0.75))
                } else if model.groups.isEmpty {
                    EmptyStateView()
                }
            }
        }
    }

    private var filterKey: String {
        "\(model.importFilter.id)|\(model.operationFilter.id)|\(model.activeLabelIDs.sorted().joined(separator: ","))"
    }

    private var currentSourceSnapshot: PhotoSourceSnapshot? {
        guard let sourcePath = model.sourceURL?.path else { return nil }
        return sourceSnapshots[sourcePath]
    }

    private func activeListIdentity(in snapshot: PhotoSourceSnapshot) -> String {
        model.hasActiveFilters
            ? "\(snapshot.sourcePath)|\(filterKey)"
            : "\(snapshot.sourcePath)|all"
    }

    private func scrollPositionBinding(for listIdentity: String) -> Binding<ScrollPosition> {
        Binding(
            // Supplying the target ID type is required for ScrollPosition to
            // record the top-most photo-row ID as the user scrolls. An
            // edge-only position uses Never as its ID type, so after user
            // scrolling it has no semantic row position to restore.
            get: {
                scrollPositions[listIdentity]
                    ?? ScrollPosition(idType: PhotoRowAnchorID.self, edge: .top)
            },
            set: { scrollPositions[listIdentity] = $0 }
        )
    }

    private func captureCurrentSourceSnapshot() {
        guard let sourcePath = model.sourceURL?.path else { return }
        let existingSnapshot = sourceSnapshots[sourcePath]
        var snapshot = existingSnapshot ?? PhotoSourceSnapshot(
            sourcePath: sourcePath,
            allGroups: [],
            filteredGroups: [:]
        )

        // A returning volume source keeps its complete list throughout a
        // rescan so a small initial filesystem batch cannot clamp its saved
        // scroll offset. Camera catalog snapshots are different: each
        // accepted catalog is the requested replacement and must be published
        // while the camera is still cataloging.
        let hasRetainedContent = existingSnapshot?.allGroups.isEmpty == false
        let isLiveCameraCatalogUpdate = model.isCameraSource && model.isCameraCataloging
        let mayPublishCurrentGroups = isLiveCameraCatalogUpdate
            || !hasRetainedContent
            || !model.isScanning
        if mayPublishCurrentGroups {
            snapshot.allGroups = model.groupedPhotos
            if model.hasActiveFilters {
                snapshot.filteredGroups[filterKey] = model.filteredGroupedPhotos
            }
        }
        sourceSnapshots[sourcePath] = snapshot
    }

}

/// Gives the standard Edit > Select All command a responder when the photo
/// grid has focus. Text fields remain the first responder in their own sheet,
/// so the same command continues to select text there.
private struct PhotoSelectionResponder: NSViewRepresentable {
    @Bindable var model: AppModel

    func makeNSView(context: Context) -> PhotoSelectionResponderView {
        let view = PhotoSelectionResponderView()
        view.model = model
        model.photoSelectionResponder = view
        return view
    }

    func updateNSView(_ nsView: PhotoSelectionResponderView, context: Context) {
        nsView.model = model
        model.photoSelectionResponder = nsView
    }
}

private final class PhotoSelectionResponderView: NSView {
    weak var model: AppModel?

    override var acceptsFirstResponder: Bool { true }

    override func selectAll(_ sender: Any?) {
        model?.selectAll()
    }
}

/// Builds only the currently visible source/filter list. Its native SwiftUI
/// scroll position is owned by PhotoGrid, keyed by source and filter, so a
/// source switch does not keep hidden thumbnail views alive.
private struct SourcePhotoLists: View {
    let snapshot: PhotoSourceSnapshot
    let currentFilterKey: String
    @Binding var scrollPosition: ScrollPosition
    @Bindable var model: AppModel
    @Binding var rangeSelectionMode: Bool
    @Binding var dragStart: CGPoint?
    @Binding var dragEnd: CGPoint?

    private var activeGroups: [(String, [PhotoGroup])] {
        guard model.hasActiveFilters else { return snapshot.allGroups }
        return snapshot.filteredGroups[currentFilterKey] ?? []
    }

    private var listIdentity: String {
        model.hasActiveFilters
            ? "\(snapshot.sourcePath)|\(currentFilterKey)"
            : "\(snapshot.sourcePath)|all"
    }

    var body: some View {
        PhotoListView(
            model: model,
            groups: activeGroups,
            listIdentity: listIdentity,
            showImportClusters: true,
            collapseImportedByDefault: false,
            emptyDescription: model.hasActiveFilters ? model.activeFilterDescription : "すべて",
            scrollPosition: $scrollPosition,
            rangeSelectionMode: $rangeSelectionMode,
            dragStart: $dragStart,
            dragEnd: $dragEnd
        )
        // The stored position and the ScrollView lifecycle must switch as one
        // unit. Without an explicit identity SwiftUI reuses the same native
        // scroll view while replacing its Binding, allowing the old source's
        // live offset to be written into the new source's saved position.
        .id(listIdentity)
    }
}

private nonisolated struct PhotoRowAnchorID: Hashable, Sendable {
    let listIdentity: String
    let firstPhotoID: String
}

private enum PhotoListItemID: Hashable {
    case clusterHeader(String)
    case photoRow(PhotoRowAnchorID)
}

private struct PhotoListItem: Identifiable {
    enum Content {
        case clusterHeader(PhotoImportCluster)
        case photoRow(id: PhotoRowAnchorID, photos: [PhotoGroup])
    }

    let id: PhotoListItemID
    let content: Content
}

private struct PhotoListView: View {
    @Bindable var model: AppModel
    let groups: [(String, [PhotoGroup])]
    let listIdentity: String
    let showImportClusters: Bool
    let collapseImportedByDefault: Bool
    let emptyDescription: String
    @Binding var scrollPosition: ScrollPosition
    @Binding var rangeSelectionMode: Bool
    @Binding var dragStart: CGPoint?
    @Binding var dragEnd: CGPoint?
    @State private var collapsedClusterIDs: Set<String> = []
    @State private var manuallyToggledClusterIDs: Set<String> = []
    @State private var didInitializeCollapsedClusters = false
    @State private var visibleRowIDs: Set<PhotoRowAnchorID> = []
    @State private var loadingRowPriorities: [PhotoRowAnchorID: ThumbnailRequestPriority] = [:]
    @State private var isRangeDragActive = false
    @State private var pendingRangeSelectionRect: CGRect?

    var body: some View {
        Group {
            if groups.isEmpty {
                FilterEmptyState(description: emptyDescription) {
                    model.importFilter = .all
                    model.operationFilter = .all
                    model.clearLabelFilters()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.0) { day, photos in
                            daySection(day: day, photos: photos)
                                .id(dateSectionID(day))
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition($scrollPosition)
                .simultaneousGesture(MagnificationGesture().onEnded { value in
                    model.thumbnailSize = min(640, max(90, model.thumbnailSize * value))
                })
                .onAppear {
                    syncDefaultCollapsedClusters()
                    prepareRestoredThumbnailWorkingSet()
                }
                .onChange(of: model.focusScrollRevision) { _, _ in
                    updateScrollPosition()
                }
                .onScrollTargetVisibilityChange(idType: PhotoRowAnchorID.self, threshold: 0.5) { rowIDs in
                    let nextVisibleRowIDs = normalizedVisibleRowIDs(Set(rowIDs))
                    guard !nextVisibleRowIDs.isEmpty else { return }
                    guard nextVisibleRowIDs != visibleRowIDs else { return }
                    visibleRowIDs = nextVisibleRowIDs
                    updateLoadingRowPriorities(visibleIDs: nextVisibleRowIDs)
                }
                .onChange(of: groups.count) { _, _ in
                    syncDefaultCollapsedClusters()
                    updateLoadingRowPriorities(visibleIDs: visibleRowIDs)
                }
                .onChange(of: model.groupStateRevision) { _, _ in
                    syncDefaultCollapsedClusters()
                    updateLoadingRowPriorities(visibleIDs: visibleRowIDs)
                }
                .onChange(of: model.gridColumnCount) { _, _ in
                    updateLoadingRowPriorities(visibleIDs: visibleRowIDs)
                }
                .onChange(of: model.thumbnailSize) { _, _ in
                    updateLoadingRowPriorities(visibleIDs: visibleRowIDs)
                }
                .overlayPreferenceValue(TileFramePreferenceKey.self) { anchors in
                    GeometryReader { proxy in
                        ZStack(alignment: .topLeading) {
                            if rangeSelectionMode {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 4)
                                            .onChanged { value in
                                                isRangeDragActive = true
                                                dragStart = value.startLocation
                                                dragEnd = value.location
                                            }
                                            .onEnded { value in
                                                // Keep the preference collection alive for one SwiftUI update. A
                                                // very short drag can end in the same event turn in which the
                                                // tile anchors are enabled; resolving the empty snapshot here
                                                // would silently select nothing.
                                                pendingRangeSelectionRect = rect(from: value.startLocation, to: value.location)
                                            }
                                    )
                                if let pendingRangeSelectionRect {
                                    Color.clear
                                        .task(id: "\(pendingRangeSelectionRect)-\(anchors.count)") {
                                            guard !anchors.isEmpty else { return }
                                            let ids = anchors.compactMap { id, anchor -> String? in
                                                proxy[anchor].intersects(pendingRangeSelectionRect) ? id : nil
                                            }
                                            model.setFocus(ids: Set(ids))
                                            self.pendingRangeSelectionRect = nil
                                            isRangeDragActive = false
                                            dragStart = nil
                                            dragEnd = nil
                                        }
                                    }
                                if let dragStart, let dragEnd {
                                    Rectangle()
                                        .fill(Color.accentColor.opacity(0.16))
                                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                                        .frame(width: abs(dragEnd.x - dragStart.x), height: abs(dragEnd.y - dragStart.y))
                                        .position(x: (dragStart.x + dragEnd.x) / 2, y: (dragStart.y + dragEnd.y) / 2)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                }
        }
        }
        .onChange(of: rangeSelectionMode) { _, enabled in
            if !enabled {
                isRangeDragActive = false
                pendingRangeSelectionRect = nil
                dragStart = nil
                dragEnd = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func daySection(day: String, photos: [PhotoGroup]) -> some View {
        let items = listItems(for: day, photos: photos)
        Section {
            ForEach(items) { item in
                switch item.content {
                case .clusterHeader(let cluster):
                    PhotoImportClusterHeader(
                        cluster: cluster,
                        model: model,
                        collapsed: collapsedClusterIDs.contains(cluster.id),
                        onToggleCollapsed: {
                            manuallyToggledClusterIDs.insert(cluster.id)
                            if collapsedClusterIDs.contains(cluster.id) {
                                collapsedClusterIDs.remove(cluster.id)
                            } else {
                                collapsedClusterIDs.insert(cluster.id)
                            }
                        }
                    )
                case .photoRow(let id, let rowPhotos):
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(rowPhotos) { group in
                            photoTile(
                                for: group,
                                loadingPriority: loadingPriority(for: id)
                            )
                            // The same camera filename can exist on the card
                            // and in a library. Include the source path so a
                            // source switch cannot reuse another tile state.
                            // Variant paths are also part of the identity:
                            // an incremental card scan can publish a group
                            // after finding one member of a JPG/CR3 pair, then
                            // complete that same group in the final snapshot.
                            .id(tileIdentity(for: group))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 22)
                    .id(id)
                }
            }
        } header: {
            DateSectionHeader(
                day: day,
                photos: photos,
                model: model,
                // Keep the import-state count visible even when every photo
                // in the day has the same state, including library views.
                showImportSummary: showImportClusters
            )
        }
    }

    private func listItems(for day: String, photos: [PhotoGroup]) -> [PhotoListItem] {
        let clusters = importClusters(for: day, photos: photos)
        var items: [PhotoListItem] = []

        if showImportClusters && clusters.count > 1 {
            for cluster in clusters {
                items.append(PhotoListItem(
                    id: .clusterHeader(cluster.id),
                    content: .clusterHeader(cluster)
                ))
                guard !collapsedClusterIDs.contains(cluster.id) else { continue }
                appendRows(for: cluster.photos, to: &items)
            }
        } else {
            appendRows(for: photos, to: &items)
        }
        return items
    }

    private func appendRows(for photos: [PhotoGroup], to items: inout [PhotoListItem]) {
        let columnCount = max(1, model.gridColumnCount)
        var start = 0
        while start < photos.count {
            let end = min(start + columnCount, photos.count)
            let id = PhotoRowAnchorID(
                listIdentity: listIdentity,
                firstPhotoID: photos[start].id
            )
            items.append(PhotoListItem(
                id: .photoRow(id),
                content: .photoRow(id: id, photos: Array(photos[start..<end]))
            ))
            start = end
        }
    }

    private func tileIdentity(for group: PhotoGroup) -> String {
        [
            group.id,
            group.jpegURL?.path ?? "",
            group.rawURL?.path ?? "",
            group.movieURL?.path ?? "",
            group.cameraReference?.cameraID ?? "",
            group.cameraReference?.groupKey ?? ""
        ].joined(separator: "|")
    }

    private func importClusters(for day: String, photos: [PhotoGroup]) -> [PhotoImportCluster] {
        PhotoImportCluster.preservingOrder(dateKey: day, photos: photos)
    }

    @ViewBuilder
    private func photoTile(
        for group: PhotoGroup,
        loadingPriority: ThumbnailRequestPriority?
    ) -> some View {
        let tile = PhotoGroupTile(
            thumbnailServices: model.thumbnailServices,
            group: group,
            size: model.thumbnailSize,
            focused: model.focusedIDs.contains(group.id),
            selected: model.selectedIDs.contains(group.id),
            deleteCandidate: model.deleteCandidateIDs.contains(group.id),
            rangeSelectionMode: rangeSelectionMode,
            showImportStatus: true,
            // A realized LazyVStack tile can load on its own. The
            // three-viewport map adds adaptive prefetching around it.
            loadingPriority: loadingPriority,
            prioritizeMetadata: { groupID, priority in
                model.prioritizeMetadata(for: groupID, priority: priority)
            },
            onClick: {
                model.focusPhotoList()
                model.focus(group, modifiers: NSEvent.modifierFlags)
            },
            onDoubleClick: {
                model.focusPhotoList()
                model.focus(group)
                model.openViewer(for: group)
            }
        )
        let interactiveTile = tile.contextMenu {
            if model.isLibraryView {
                Button("ラベルを設定…", systemImage: "tag") {
                    model.focus(group)
                    model.presentLabelPicker()
                }
            }
        }

        if isRangeDragActive {
            interactiveTile.anchorPreference(key: TileFramePreferenceKey.self, value: .bounds) { [group.id: $0] }
        } else {
            interactiveTile
        }
    }

    /// Keeps thumbnails ready for the visible viewport plus one viewport in
    /// each scroll direction. The number of visible rows is the viewport
    /// size, so extending by that count gives an adaptive three-screen
    /// working set at every thumbnail size and window height.
    private func loadingPriority(for rowID: PhotoRowAnchorID) -> ThumbnailRequestPriority? {
        // LazyVStack only creates rows near the viewport. Every realized row
        // must therefore be independently loadable even when a semantic
        // scroll restoration emits no visibility callback. The explicit
        // working-set map still marks adjacent unrealized rows for prefetch.
        return loadingRowPriorities[rowID] ?? .visible
    }

    /// SwiftUI can emit a transient visibility snapshot while a large lazy
    /// list is being relaid out in which rows near opposite ends of the list
    /// are both reported. A real viewport can only contain one contiguous run
    /// of photo rows. Keep the run connected to the previously visible rows;
    /// on first layout, keep the largest contiguous run.
    private func normalizedVisibleRowIDs(
        _ candidateIDs: Set<PhotoRowAnchorID>
    ) -> Set<PhotoRowAnchorID> {
        guard !candidateIDs.isEmpty else { return [] }
        let rowIDs = renderedRows.map(\.id)
        let indexByID = Dictionary(
            uniqueKeysWithValues: rowIDs.enumerated().map { ($0.element, $0.offset) }
        )
        let candidateIndexes = candidateIDs.compactMap { indexByID[$0] }.sorted()
        guard let firstIndex = candidateIndexes.first else { return [] }

        var runs: [[Int]] = [[firstIndex]]
        for index in candidateIndexes.dropFirst() {
            if index == runs[runs.count - 1].last! + 1 {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
        }
        guard runs.count > 1 else { return candidateIDs }

        let previousIndexes = Set(visibleRowIDs.compactMap { indexByID[$0] })
        let selectedRun = runs.max { lhs, rhs in
            let lhsOverlap = lhs.reduce(into: 0) { count, index in
                if previousIndexes.contains(index) { count += 1 }
            }
            let rhsOverlap = rhs.reduce(into: 0) { count, index in
                if previousIndexes.contains(index) { count += 1 }
            }
            if lhsOverlap != rhsOverlap { return lhsOverlap < rhsOverlap }
            return lhs.count < rhs.count
        } ?? runs[0]

        return Set(selectedRun.map { rowIDs[$0] })
    }

    private func updateLoadingRowPriorities(visibleIDs: Set<PhotoRowAnchorID>) {
        guard !visibleIDs.isEmpty else {
            return
        }
        let rows = renderedRows
        let rowIDs = rows.map(\.id)
        let indexByID = Dictionary(uniqueKeysWithValues: rowIDs.enumerated().map { ($0.element, $0.offset) })
        let visibleIndexes = visibleIDs.compactMap { indexByID[$0] }
        guard let firstVisible = visibleIndexes.min(),
              let lastVisible = visibleIndexes.max() else {
            return
        }
        let viewportRowCount = max(1, lastVisible - firstVisible + 1)
        let lowerBound = max(0, firstVisible - viewportRowCount)
        let upperBound = min(rowIDs.count - 1, lastVisible + viewportRowCount)
        var priorities: [PhotoRowAnchorID: ThumbnailRequestPriority] = [:]
        priorities.reserveCapacity(upperBound - lowerBound + 1)
        for index in lowerBound...upperBound {
            let id = rowIDs[index]
            priorities[id] = visibleIDs.contains(id) ? .visible : .prefetch
        }
        if loadingRowPriorities != priorities {
            loadingRowPriorities = priorities
        }

        let thumbnailRequests = (lowerBound...upperBound).flatMap { index in
            let priority: ThumbnailRequestPriority = visibleIDs.contains(rows[index].id) ? .visible : .prefetch
            return rows[index].photos.map { ($0, priority) }
        }
        let maxPixel = min(640, max(320, Int(model.thumbnailSize * 2)))
        if model.isCameraSource {
            model.thumbnailServices.file.updateListWorkingSet(
                groups: [],
                maxPixel: maxPixel,
                onThumbnailReady: { _, _ in }
            )
            model.thumbnailServices.camera.updateListWorkingSet(
                groups: thumbnailRequests,
                maxPixel: maxPixel,
                onThumbnailReady: { groupID, priority in
                    model.prioritizeMetadata(
                        for: groupID,
                        priority: priority == .visible ? .visible : .prefetch
                    )
                }
            )
        } else {
            model.thumbnailServices.camera.updateListWorkingSet(
                groups: [],
                maxPixel: maxPixel,
                onThumbnailReady: { _, _ in }
            )
            model.thumbnailServices.file.updateListWorkingSet(
                groups: thumbnailRequests,
                maxPixel: maxPixel
            ) { groupID, priority in
                model.prioritizeMetadata(
                    for: groupID,
                    priority: priority == .visible ? .visible : .prefetch
                )
            }
        }
    }

    /// A semantic ScrollPosition can restore before SwiftUI emits a fresh
    /// visibility callback. Seed thumbnail loading from that restored row so
    /// returning to a source never waits for the user to scroll once.
    private func prepareRestoredThumbnailWorkingSet() {
        let rows = renderedRows
        guard !rows.isEmpty else { return }
        let restoredRowID = scrollPosition.viewID(type: PhotoRowAnchorID.self)
        let firstVisibleIndex = restoredRowID.flatMap { restored in
            rows.firstIndex(where: { $0.id == restored })
        } ?? 0
        let captionHeight = NSFont.preferredFont(forTextStyle: .caption1).boundingRectForFont.height
        let rowHeight = max(
            1,
            model.thumbnailSize * PhotoGridLayoutMetrics.thumbnailHeightRatio
                + PhotoGridLayoutMetrics.tileTextSpacing
                + captionHeight
        )
        let visibleRowCount = max(1, Int(ceil(model.gridViewportHeight / rowHeight)))
        let lastVisibleIndex = min(rows.count - 1, firstVisibleIndex + visibleRowCount - 1)
        let restoredVisibleIDs = Set(rows[firstVisibleIndex...lastVisibleIndex].map(\.id))
        visibleRowIDs = restoredVisibleIDs
        updateLoadingRowPriorities(visibleIDs: restoredVisibleIDs)
    }

    private var renderedRows: [(id: PhotoRowAnchorID, photos: [PhotoGroup])] {
        var result: [(id: PhotoRowAnchorID, photos: [PhotoGroup])] = []
        for (day, photos) in groups {
            for item in listItems(for: day, photos: photos) {
                if case .photoRow(let id, let rowPhotos) = item.content {
                    result.append((id: id, photos: rowPhotos))
                }
            }
        }
        return result
    }

    private func syncDefaultCollapsedClusters() {
        guard collapseImportedByDefault, !groups.isEmpty else { return }
        let importedIDs = groups.flatMap { day, photos in
            importClusters(for: day, photos: photos)
                .filter { $0.state == .imported }
                .map(\.id)
        }
        if !didInitializeCollapsedClusters {
            collapsedClusterIDs = Set(importedIDs)
            didInitializeCollapsedClusters = true
        } else {
            collapsedClusterIDs.formUnion(importedIDs.filter { !manuallyToggledClusterIDs.contains($0) })
        }
    }

    private func updateScrollPosition() {
        guard let focusedID = model.focusedGroup?.id,
              let rowID = scrollRowID(for: focusedID) else { return }
        guard !visibleRowIDs.contains(rowID) else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if model.focusScrollEdge == .beginning,
               focusedID == groups.first?.1.first?.id,
               groups.first != nil {
                // The document edge includes the pinned date header. A photo
                // row aligned to .top would sit underneath that header.
                scrollPosition.scrollTo(edge: .top)
            } else {
                scrollPosition.scrollTo(id: rowID, anchor: model.focusScrollEdge == .beginning ? .top : .bottom)
            }
        }
    }

    private func scrollRowID(for groupID: String) -> PhotoRowAnchorID? {
        let columnCount = max(1, model.gridColumnCount)
        for (day, photos) in groups {
            let clusters = importClusters(for: day, photos: photos)
            let visibleSections: [[PhotoGroup]] = showImportClusters && clusters.count > 1
                ? clusters.map(\.photos)
                : [photos]

            for sectionPhotos in visibleSections {
                guard let photoIndex = sectionPhotos.firstIndex(where: { $0.id == groupID }) else { continue }
                let rowStart = (photoIndex / columnCount) * columnCount
                guard sectionPhotos.indices.contains(rowStart) else { return nil }
                return PhotoRowAnchorID(listIdentity: listIdentity, firstPhotoID: sectionPhotos[rowStart].id)
            }
        }
        return nil
    }

    private func dateSectionID(_ day: String) -> String {
        "photokichin-date-section-\(day)"
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
    }
}

private struct PhotoImportClusterHeader: View {
    let cluster: PhotoImportCluster
    @Bindable var model: AppModel
    let collapsed: Bool
    let onToggleCollapsed: () -> Void

    private var selectedCount: Int { model.selectedCount(in: cluster.photos) }
    private var deleteCount: Int { model.deleteCandidateCount(in: cluster.photos) }

    var body: some View {
        HStack(spacing: 9) {
            MacOSDisclosureButton(
                isExpanded: !collapsed,
                accessibilityLabel: collapsed ? "写真グループを展開" : "写真グループを折りたたむ",
                onToggle: onToggleCollapsed
            )
            Label(cluster.state.title, systemImage: cluster.state.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle([.possible, .partial].contains(cluster.state) ? .orange : .primary)
            Text("\(cluster.photos.count)枚")
                .font(.caption)
                .foregroundStyle(.secondary)
            if selectedCount > 0 {
                Label("\(selectedCount)枚選択", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            if deleteCount > 0 {
                Label("\(deleteCount)枚削除候補", systemImage: "trash.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button(selectedCount == cluster.photos.count ? "選択解除" : "選択") {
                if selectedCount == cluster.photos.count {
                    model.clearSelection(in: cluster.photos)
                } else {
                    model.selectAll(in: cluster.photos)
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.25))
    }
}

private struct MacOSDisclosureButton: NSViewRepresentable {
    let isExpanded: Bool
    let accessibilityLabel: String
    let onToggle: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: onToggle)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.toggle))
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .disclosure
        button.controlSize = .small
        button.isBordered = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        update(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = onToggle
        update(button)
    }

    private func update(_ button: NSButton) {
        button.state = isExpanded ? .on : .off
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(isExpanded ? "展開" : "折りたたみ")
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func toggle(_ sender: NSButton) {
            action()
        }
    }
}

private struct SelectionSummaryBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Label("写真", systemImage: "photo.on.rectangle")
            Text(model.hasActiveFilters
                 ? "\(model.filteredPhotoCount)/\(model.totalPhotoCount)枚"
                 : "\(model.totalPhotoCount)枚")
                .foregroundStyle(.secondary)
            if model.sourceURL != nil && !model.isLibraryView {
                Menu {
                    ForEach(model.availableImportFilters) { filter in
                        Button {
                            model.importFilter = filter
                        } label: {
                            Label(filter.title, systemImage: model.importFilter == filter ? "checkmark" : filter.systemImage)
                        }
                    }
                } label: {
                    Label("取り込み状態: \(model.importFilter.title)", systemImage: "arrow.down.circle")
                }
                .menuStyle(.borderlessButton)
                .help("取り込み状態で絞り込み")
            }
            Menu {
                ForEach(PhotoOperationFilter.allCases) { filter in
                    Button {
                        model.operationFilter = filter
                    } label: {
                        Label(filter.title, systemImage: model.operationFilter == filter ? "checkmark" : filter.systemImage)
                    }
                }
            } label: {
                Label("操作状態: \(model.operationFilter.title)", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .help("選択状態で絞り込み")
            if model.isLibraryView {
                Menu {
                    ForEach(model.labels) { label in
                        Button { model.toggleLabelFilter(label) } label: {
                            Label(label.name, systemImage: model.activeLabelIDs.contains(label.id) ? "checkmark" : "tag")
                        }
                    }
                    if model.labels.isEmpty { Text("ラベルがありません") }
                } label: {
                    Label("ラベル", systemImage: "tag")
                }
                .menuStyle(.borderlessButton)
                ForEach(model.activeLabels) { label in
                    Button { model.toggleLabelFilter(label) } label: {
                        HStack(spacing: 4) {
                            Circle().fill(Color(labelHex: label.colorHex)).frame(width: 8, height: 8)
                            Text(label.name)
                            Image(systemName: "xmark").font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if model.activeLabelIDs.count > 1 && model.activeSavedLabelViewID == nil {
                    SaveLabelViewButton(model: model)
                }
                if !model.activeLabelIDs.isEmpty {
                    Button("ラベル条件を解除", systemImage: "xmark.circle") { model.clearLabelFilters() }
                        .labelStyle(.iconOnly)
                        .help("すべてのラベル条件を解除")
                }
            }
            Divider().frame(height: 16)
            Label("選択", systemImage: "checkmark.circle")
            Text("\(model.selectedPhotoCount)枚")
                .foregroundStyle(model.selectedPhotoCount == 0 ? .secondary : Color.accentColor)
            Divider().frame(height: 16)
            Label("削除候補", systemImage: "trash")
            Text("\(model.deleteCandidatePhotoCount)枚")
                .foregroundStyle(model.deleteCandidatePhotoCount == 0 ? Color.secondary : Color.red)
            if let progress = model.operationProgress {
                Divider().frame(height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 118)
                        Text("\(progress.completedGroups)/\(progress.totalGroups)組")
                            .monospacedDigit()
                        Text("(\(progress.completedFiles)/\(progress.totalFiles)件)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .transition(.opacity)
                if ["取り込み中", "ライブラリへコピー中"].contains(progress.title) {
                    Button(model.isCancellingImport ? "中断中…" : "中断") {
                        model.cancelImport()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isCancellingImport)
                }
            }
            Spacer()
            Button("全選択") { model.selectAll() }
                .disabled(model.groups.isEmpty || model.selectedPhotoCount == model.totalPhotoCount)
            Button("選択解除") { model.clearSelection() }
                .disabled(model.selectedPhotoCount == 0)
            Button("削除候補解除") { model.clearDeleteCandidates() }
                .foregroundStyle(.red)
                .disabled(model.deleteCandidatePhotoCount == 0)
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

private struct DateSectionHeader: View {
    let day: String
    let photos: [PhotoGroup]
    @Bindable var model: AppModel
    let showImportSummary: Bool

    private var selectedCount: Int { model.selectedCount(in: photos) }
    private var deleteCount: Int { model.deleteCandidateCount(in: photos) }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(day)
                    .font(.title3.weight(.semibold))
                Text("\(photos.count)枚")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showImportSummary {
                    if model.isImportStateRefreshing {
                        Label("取り込み状態を確認中…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(PhotoImportState.allCases.sorted { $0.sortOrder < $1.sortOrder }) { state in
                            let count = photos.filter { $0.displayImportState == state }.count
                            if count > 0 {
                                Text("\(state.title) \(count)")
                                    .font(.caption)
                                    .foregroundStyle(color(for: state))
                            }
                        }
                    }
                }
                if selectedCount > 0 {
                    Label("\(selectedCount)枚選択", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                if deleteCount > 0 {
                    Label("\(deleteCount)枚削除候補", systemImage: "trash.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .layoutPriority(1)
            Spacer()
            HStack(spacing: 8) {
                Button {
                    model.selectAll(in: photos)
                } label: {
                    Text("全選択")
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(selectedCount == photos.count)
                if selectedCount > 0 {
                    Button {
                        model.clearSelection(in: photos)
                    } label: {
                        Text("選択解除")
                            .fixedSize()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                Menu {
                    Button("削除候補にする", systemImage: "trash") {
                        model.markDeleteCandidates(in: photos)
                    }
                    .disabled(!model.canDeleteSourceFiles || deleteCount == photos.count)
                    Button("削除候補を解除", systemImage: "trash.slash") {
                        model.clearDeleteCandidates(in: photos)
                    }
                    .disabled(deleteCount == 0)
                } label: {
                    Label("削除操作", systemImage: "trash")
                        .fixedSize()
                }
                .font(.caption)
            }
            .fixedSize()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .zIndex(1)
    }

    private func color(for state: PhotoImportState) -> Color {
        switch state {
        case .notImported: return .secondary
        case .possible: return .orange
        case .partial: return .orange
        case .imported: return .green
        case .notApplicable: return .gray
        }
    }
}

private struct TileFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct PhotoGroupTile: View {
    let thumbnailServices: ThumbnailServices
    let group: PhotoGroup
    let size: Double
    let focused: Bool
    let selected: Bool
    let deleteCandidate: Bool
    let rangeSelectionMode: Bool
    let showImportStatus: Bool
    let loadingPriority: ThumbnailRequestPriority?
    let prioritizeMetadata: (String, MetadataRequestPriority) -> Void
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    @State private var loader: ThumbnailLoader

    init(
        thumbnailServices: ThumbnailServices,
        group: PhotoGroup,
        size: Double,
        focused: Bool,
        selected: Bool,
        deleteCandidate: Bool,
        rangeSelectionMode: Bool,
        showImportStatus: Bool,
        loadingPriority: ThumbnailRequestPriority?,
        prioritizeMetadata: @escaping (String, MetadataRequestPriority) -> Void,
        onClick: @escaping () -> Void,
        onDoubleClick: @escaping () -> Void
    ) {
        self.thumbnailServices = thumbnailServices
        self.group = group
        self.size = size
        self.focused = focused
        self.selected = selected
        self.deleteCandidate = deleteCandidate
        self.rangeSelectionMode = rangeSelectionMode
        self.showImportStatus = showImportStatus
        self.loadingPriority = loadingPriority
        self.prioritizeMetadata = prioritizeMetadata
        self.onClick = onClick
        self.onDoubleClick = onDoubleClick
        _loader = State(initialValue: ThumbnailLoader(services: thumbnailServices))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PhotoGridLayoutMetrics.tileTextSpacing) {
            ZStack(alignment: .topLeading) {
                if let image = loader.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else if loader.isLoading {
                    Rectangle().fill(.quaternary)
                    ProgressView().controlSize(.small)
                } else {
                    Rectangle().fill(.quaternary)
                    Image(systemName: group.movieURL != nil ? "film" : "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
                if selected || deleteCandidate {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(deleteCandidate ? Color.red : Color.accentColor, lineWidth: 4)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, deleteCandidate ? Color.red : Color.accentColor)
                        .padding(7)
                }
            }
            .frame(
                width: size,
                height: size * PhotoGridLayoutMetrics.thumbnailHeightRatio
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                PhotoVariantBadges(group: group)
                    .padding(7)
            }
            .overlay(alignment: .topTrailing) {
                if showImportStatus {
                    switch group.displayImportState {
                    case .imported:
                        ImportedStatusBadge(size: 18)
                            .padding(8)
                    case .possible:
                        PossibleImportedStatusBadge(size: 18)
                            .padding(8)
                    default:
                        EmptyView()
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !group.labels.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(Array(group.labels.prefix(3))) { label in
                            Circle()
                                .fill(Color(labelHex: label.colorHex))
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1))
                        }
                        if group.labels.count > 3 {
                            Text("+\(group.labels.count - 3)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(7)
                    .help(group.labels.map(\.name).joined(separator: "、"))
                }
            }
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.black.opacity(0.85), lineWidth: 7)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white, lineWidth: 3)
                        }
                        .shadow(color: .black.opacity(0.35), radius: 2)
                }
            }
            .contentShape(Rectangle())
            // A click changes focus only. Return/Delete decide which action set
            // the focused photo belongs to, so browsing never destroys a batch.
            .onTapGesture(perform: onClick)
            .simultaneousGesture(TapGesture(count: 2).onEnded(onDoubleClick))
            Text(group.basename)
                .font(.caption)
                .lineLimit(1)
                .frame(width: size, alignment: .leading)
        }
        // A card and a library commonly contain the same basename. The path
        // is part of the task identity so switching sources always starts a
        // thumbnail read for the new file instead of retaining the old tile's
        // loader state.
        .task(id: [
            group.id,
            String(Int(size)),
            group.jpegURL?.path ?? "",
            group.rawURL?.path ?? "",
            group.movieURL?.path ?? "",
            group.cameraReference?.cameraID ?? "",
            group.cameraReference?.groupKey ?? "",
            String(loadingPriority?.rawValue ?? -1)
        ].joined(separator: "|")) {
            guard let loadingPriority else {
                loader.cancel()
                return
            }
            loader.load(
                for: group,
                maxPixel: min(640, max(320, Int(size * 2))),
                priority: loadingPriority
            ) {
                prioritizeMetadata(
                    group.id,
                    loadingPriority == .visible ? .visible : .prefetch
                )
            }
        }
        .onDisappear { loader.cancel() }
        .opacity(rangeSelectionMode ? 0.94 : 1)
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(color.opacity(0.9), in: Capsule())
    }
}

private struct ImportedStatusBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
        }
            .shadow(color: .black.opacity(0.35), radius: 2)
            .accessibilityLabel("取り込み済み")
            .help("取り込み済み")
    }
}

private struct PossibleImportedStatusBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.orange)
            Image(systemName: "questionmark")
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 2)
        .accessibilityLabel("取り込み済みかもしれない")
        .help("取り込み済みかもしれない")
    }
}

private struct PhotoVariantBadges: View {
    let group: PhotoGroup

    var body: some View {
        let hasJPEG = group.variants.contains(.jpeg)
        let hasRAW = group.variants.contains(.raw)
        HStack(spacing: 4) {
            if hasJPEG { Badge(text: "JPG", color: .blue) }
            if hasRAW { Badge(text: "RAW", color: .orange) }
            if group.libraryAssetStatus == .unregistered || group.libraryAssetStatus == .partial {
                if hasJPEG || hasRAW {
                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, 3)
                }
                Badge(text: "EXT", color: .extBadge)
            }
        }
    }
}

private extension Color {
    static let extBadge = Color(red: 0.455, green: 0.404, blue: 0.659)

    init(labelHex: String) {
        let value = labelHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let rgb = UInt64(value, radix: 16) ?? 0xE5484D
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }

    var labelHex: String {
        guard let color = NSColor(self).usingColorSpace(.deviceRGB) else { return LabelPalette.colors[0] }
        return String(format: "#%02X%02X%02X", Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("写真を表示する場所を選択してください")
                .font(.title3.weight(.semibold))
        Text("EOS RのSDカード、USBカメラ、または写真の入ったフォルダを選択します。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CameraCatalogLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text("カメラの写真一覧を準備しています")
                .font(.title3.weight(.semibold))
            Text("見つかった写真から順に表示します。写真の枚数が多い場合は、追加読み込み中も操作できます。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FilterEmptyState: View {
    let description: String
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("「\(description)」に一致する写真はありません")
                .font(.title3.weight(.semibold))
            Button("条件を解除", action: onClear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InspectorView: View {
    @Bindable var model: AppModel
    let group: PhotoGroup?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("写真情報").font(.headline)
                if let group {
                    Text(group.basename).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 7) {
                        if !model.isLibraryView {
                            switch group.displayImportState {
                            case .imported:
                                ImportedStatusBadge(size: 18)
                            case .possible:
                                PossibleImportedStatusBadge(size: 18)
                            default:
                                EmptyView()
                            }
                        }
                        PhotoVariantBadges(group: group)
                    }
                    if model.isLibraryView {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("ラベル").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("設定…", systemImage: "tag") { model.presentLabelPicker() }
                                    .labelStyle(.iconOnly)
                                    .help("ラベルを設定（L）")
                            }
                            if group.labels.isEmpty {
                                Text(group.photoID == nil ? "管理対象外" : "未設定").foregroundStyle(.secondary)
                            } else {
                                FlowLabelList(labels: group.labels)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Button {
                            model.toggleFocusedSelection()
                        } label: {
                            Image(systemName: model.selectedIDs.contains(group.id) ? "checkmark.circle.fill" : "checkmark.circle")
                                .font(.system(size: 27, weight: .semibold))
                                .foregroundStyle(model.selectedIDs.contains(group.id) ? Color.accentColor : Color.secondary)
                                .frame(width: 42, height: 36)
                        }
                        .buttonStyle(.plain)
                        .help("取り込み対象を切り替え（Return）")

                        Button {
                            model.toggleFocusedDeleteCandidate()
                        } label: {
                            Image(systemName: model.deleteCandidateIDs.contains(group.id) ? "trash.circle.fill" : "trash.circle")
                                .font(.system(size: 27, weight: .semibold))
                                .foregroundStyle(model.deleteCandidateIDs.contains(group.id) ? Color.red : Color.secondary)
                                .frame(width: 42, height: 36)
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canDeleteSourceFiles)
                        .help("削除候補を切り替え（Delete）")
                    }
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.45), in: Capsule())
                    .help(model.focusedPhotoCount > 1 ? "フォーカス中の写真すべてに適用" : "フォーカス中の写真に適用")
                    InspectorRow(label: "状態", value: group.statusLabel)
                    InspectorRow(label: "撮影日時", value: metadataValue(group.metadata.captureDate.map(DateFormatters.detail.string(from:))))
                    InspectorRow(label: "カメラ", value: metadataValue(group.metadata.cameraDisplayName))
                    InspectorRow(label: "レンズ", value: metadataValue(group.metadata.lensModel))
                    InspectorRow(label: "焦点距離", value: metadataValue(group.metadata.focalLength))
                    InspectorRow(label: "絞り", value: metadataValue(group.metadata.aperture))
                    InspectorRow(label: "シャッター", value: metadataValue(group.metadata.shutterSpeed))
                    InspectorRow(label: "感度", value: metadataValue(group.metadata.iso))
                    InspectorRow(label: "露出補正", value: metadataValue(group.metadata.exposureBias))
                    InspectorRow(label: "向き", value: metadataValue(group.metadata.orientation))
                    InspectorRow(label: "GPS", value: metadataValue(group.metadata.gps, missing: "なし"))
                    InspectorRow(label: "解像度", value: resolution)
                    InspectorRow(label: "フォルダ", value: group.directory.path)
                } else {
                    Text("写真をクリックするとフォーカスし、ここから取り込み対象または削除候補を指定できます。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
    }

    private var resolution: String {
        guard let group else { return "不明" }
        guard group.isMetadataLoaded else { return "読み込み中…" }
        guard let width = group.metadata.pixelWidth, let height = group.metadata.pixelHeight else { return "不明" }
        return "\(width) × \(height)"
    }

    private func metadataValue(_ value: String?, missing: String = "不明") -> String {
        guard let group else { return missing }
        return group.isMetadataLoaded ? (value ?? missing) : "読み込み中…"
    }

}

private struct InspectorRow: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}

private struct FlowLabelList: View {
    let labels: [PhotoLabel]
    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 5)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            ForEach(labels) { label in
                HStack(spacing: 4) {
                    Circle().fill(Color(labelHex: label.colorHex)).frame(width: 8, height: 8)
                    Text(label.name).lineLimit(1)
                }
                .font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .help(label.name)
            }
        }
    }
}

private struct SaveLabelViewButton: View {
    @Bindable var model: AppModel
    var buttonTitle: String = "ビューとして保存"
    var showsTitle = false
    @State private var presented = false
    @State private var name = ""

    var body: some View {
        Button {
            presented = true
        } label: {
            triggerLabel
        }
            .help("現在のラベル条件をビューとして保存")
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ラベルビューを保存").font(.headline)
                    TextField("ビュー名", text: $name)
                    HStack {
                        Button("キャンセル") { presented = false }
                        Button("保存") {
                            model.saveCurrentLabelView(name: name)
                            presented = false
                            name = ""
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding().frame(width: 280)
            }
    }

    @ViewBuilder
    private var triggerLabel: some View {
        if showsTitle {
            Label(buttonTitle, systemImage: "rectangle.stack.badge.plus")
        } else {
            Label(buttonTitle, systemImage: "rectangle.stack.badge.plus")
                .labelStyle(.iconOnly)
        }
    }
}

private struct LabelPickerView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var newName = ""
    @State private var newColor = LabelPalette.colors[0]
    private let colorColumns = Array(repeating: GridItem(.fixed(24), spacing: 8), count: 8)

    private var filteredLabels: [PhotoLabel] {
        let query = normalizedLabelName(search)
        let values = query.isEmpty ? model.labels : model.labels.filter { $0.normalizedName.contains(query) }
        return values.sorted {
            if $0.lastUsedAt != $1.lastUsedAt { return ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            return $0.sortOrder < $1.sortOrder
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ラベルを設定").font(.title2.weight(.semibold))
                    Text("対象 \(model.labelTargetGroups.count)枚" + (model.excludedLabelTargetCount > 0 ? "・管理対象外 \(model.excludedLabelTargetCount)枚" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("閉じる") { dismiss() }
            }
            TextField("ラベルを検索", text: $search)
                .textFieldStyle(.roundedBorder)
            List(filteredLabels) { label in
                Button { model.toggleLabelAssignment(label) } label: {
                    HStack {
                        Circle().fill(Color(labelHex: label.colorHex)).frame(width: 12, height: 12)
                        Text(label.name)
                        Spacer()
                        switch model.labelAssignmentState(label) {
                        case .all:
                            Image(systemName: "checkmark.square.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28, height: 28)
                        case .some:
                            Image(systemName: "minus.square.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28, height: 28)
                        case .none:
                            Image(systemName: "square")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                        }
                    }
                }.buttonStyle(.plain)
            }
            .frame(height: 145)
            Divider()
            Text("新しいラベル").font(.headline)
            TextField("ラベル名", text: $newName)
                .onSubmit { createAndAssignLabel() }
            LazyVGrid(columns: colorColumns, alignment: .leading, spacing: 8) {
                ForEach(LabelPalette.colors, id: \.self) { hex in
                    Button { newColor = hex } label: {
                        Circle().fill(Color(labelHex: hex)).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(newColor == hex ? Color.primary : Color.clear, lineWidth: 3))
                            .padding(1)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("ラベル色 \(hex)")
                        .accessibilityValue(newColor == hex ? "選択中" : "未選択")
                }
            }
            HStack {
                Spacer()
                Button("作成して設定") {
                    createAndAssignLabel()
                }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 540)
        .onAppear { newColor = model.randomLabelColor() }
    }

    private func createAndAssignLabel() {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let previousColor = newColor
        model.createLabel(name: newName, colorHex: previousColor)
        newName = ""
        newColor = model.randomLabelColor(excluding: previousColor)
    }
}

private struct LabelManagementView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var labelToDelete: PhotoLabel?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ラベルを管理").font(.title2.weight(.semibold))
                Spacer()
                Button("閉じる") { dismiss() }
            }
            if model.labels.isEmpty {
                ContentUnavailableView("ラベルはありません", systemImage: "tag", description: Text("写真のラベルピッカーから作成できます。"))
            } else {
                List {
                    ForEach(model.labels) { label in
                        LabelManagementRow(model: model, label: label, onDelete: { labelToDelete = label })
                    }
                    Section("保存ビュー") {
                        if model.savedLabelViews.isEmpty { Text("保存ビューはありません").foregroundStyle(.secondary) }
                        ForEach(model.savedLabelViews) { view in
                            HStack {
                                Label(view.name, systemImage: "rectangle.stack")
                                Spacer()
                                Button("削除", role: .destructive) { model.deleteSavedLabelView(view) }
                            }
                        }
                    }
                }
            }
        }
        .padding(24).frame(width: 680, height: 560)
        .confirmationDialog("ラベル「\(labelToDelete?.name ?? "")」を削除しますか？", isPresented: Binding(get: { labelToDelete != nil }, set: { if !$0 { labelToDelete = nil } })) {
            Button("削除", role: .destructive) {
                if let labelToDelete { model.deleteLabel(labelToDelete) }
                labelToDelete = nil
            }
            Button("キャンセル", role: .cancel) { labelToDelete = nil }
        } message: {
            Text("写真との紐付けと、このラベルだけを条件に持つ保存ビューも削除されます。")
        }
    }
}

private struct LabelManagementRow: View {
    @Bindable var model: AppModel
    let label: PhotoLabel
    let onDelete: () -> Void
    @State private var name: String

    init(model: AppModel, label: PhotoLabel, onDelete: @escaping () -> Void) {
        self.model = model; self.label = label; self.onDelete = onDelete
        _name = State(initialValue: label.name)
    }

    var body: some View {
        HStack(spacing: 10) {
            ColorPicker("", selection: Binding(
                get: { Color(labelHex: label.colorHex) },
                set: { color in var changed = label; changed.colorHex = color.labelHex; model.updateLabel(changed) }
            )).labelsHidden().frame(width: 28)
            TextField("ラベル名", text: $name)
                .onSubmit { var changed = label; changed.name = name; model.updateLabel(changed) }
            Button("上へ", systemImage: "chevron.up") { model.moveLabel(label, by: -1) }
                .labelStyle(.iconOnly)
            Button("下へ", systemImage: "chevron.down") { model.moveLabel(label, by: 1) }
                .labelStyle(.iconOnly)
            Menu("統合") {
                ForEach(model.labels.filter { $0.id != label.id }) { destination in
                    Button(destination.name) { model.mergeLabel(label, into: destination) }
                }
            }.disabled(model.labels.count < 2)
            Button("削除", role: .destructive, action: onDelete)
        }
    }
}

private struct CatalogManagementView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var issueToForget: CatalogIssue?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("カタログ管理").font(.title2.weight(.semibold))
                    Text("取り込み履歴と、Finderで移動・削除された写真の確認を行います。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("閉じる") { dismiss() }
            }

            if let summary = model.catalogSummary {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary.catalogURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("DB容量 \(ByteCountFormatter.string(fromByteCount: summary.catalogSize, countStyle: .file))  •  最終検査 \(summary.lastInspectionAt.map(DateFormatters.detail.string(from:)) ?? "未実施")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        CatalogMetric(label: "取り込み履歴", value: "\(summary.importedFileCount)件")
                        CatalogMetric(label: "明示登録", value: "\(summary.registeredAssetCount)件")
                        CatalogMetric(label: "未登録", value: "\(summary.unregisteredPhotoCount)件")
                        CatalogMetric(label: "問題", value: "\(summary.missingCount + summary.candidateCount + summary.conflictCount)件")
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("カタログがまだ作成されていません。")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("ライブラリを再検査", systemImage: "arrow.clockwise") { model.inspectLibrary() }
                    .disabled(model.isCatalogInspecting || model.libraryURL == nil)
                Button("未登録写真を登録", systemImage: "checkmark.circle") { model.registerUnregisteredLibraryPhotos() }
                    .disabled(!model.isLibraryView || model.catalogSummary?.unregisteredPhotoCount == 0)
                Button("ファイルを完全検査", systemImage: "checkmark.shield") { model.verifyCatalog() }
                Button("バックアップ…", systemImage: "externaldrive.badge.plus") { saveBackup() }
                Button("Finderで表示", systemImage: "folder") { model.showCatalogInFinder() }
            }
            .buttonStyle(.bordered)

            if model.isCatalogInspecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("ライブラリを検査しています…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("確認が必要な写真")
                    .font(.headline)
                Spacer()
                Text("閉じても問題は保持されます")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.catalogIssues.isEmpty {
                ContentUnavailableView("問題はありません", systemImage: "checkmark.circle", description: Text("ライブラリ検査で確認が必要な写真は見つかりませんでした。"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.catalogIssues) { issue in
                            CatalogIssueRow(model: model, issue: issue, issueToForget: $issueToForget)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(minWidth: 820, minHeight: 620)
        .alert("履歴を削除しますか？", isPresented: Binding(get: { issueToForget != nil }, set: { if !$0 { issueToForget = nil } })) {
            Button("履歴を削除", role: .destructive) {
                if let issueToForget { model.forgetCatalogIssue(issueToForget) }
                issueToForget = nil
            }
            Button("キャンセル", role: .cancel) { issueToForget = nil }
        } message: {
            Text("写真ファイルは削除されません。次回同じSDカードを読み込むと、未取り込みとして扱われます。")
        }
    }

    private func saveBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "catalog-backup-\(DateFormatters.directoryDay.string(from: Date())).sqlite"
        if let sqliteType = UTType(filenameExtension: "sqlite") {
            panel.allowedContentTypes = [sqliteType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.backupCatalog(to: url)
    }
}

private struct CatalogMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }
}

private struct CatalogIssueRow: View {
    @Bindable var model: AppModel
    let issue: CatalogIssue
    @Binding var issueToForget: CatalogIssue?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: issueIcon)
                .font(.title3)
                .foregroundStyle(issueColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(issue.lastKnownURL.deletingPathExtension().lastPathComponent)  [\(issue.variant.rawValue)]")
                    .font(.callout.weight(.semibold))
                Text(issueDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let candidateURL = issue.candidateURL {
                    Text("候補: \(candidateURL.path)")
                        .font(.caption)
                        .lineLimit(1)
                        .textSelection(.enabled)
                } else {
                    Text("最後に確認した場所: \(issue.lastKnownURL.path)")
                        .font(.caption)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if let candidateURL = issue.candidateURL {
                Button("この候補で紐付け") { model.relinkCatalogIssue(issue, to: candidateURL) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("候補を探す…") { model.searchCandidates(for: issue) }
                    .buttonStyle(.bordered)
            }
            Button("新しくコピー") { model.recopyCatalogIssue(issue) }
                .buttonStyle(.bordered)
            Button("履歴を削除") { issueToForget = issue }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
        }
        .padding(10)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }

    private var issueIcon: String {
        switch issue.issueType {
        case "candidate": return "arrow.triangle.branch"
        case "conflict": return "exclamationmark.triangle"
        default: return "questionmark.folder"
        }
    }

    private var issueColor: Color {
        switch issue.issueType {
        case "candidate": return .orange
        case "conflict": return .red
        default: return .secondary
        }
    }

    private var issueDescription: String {
        switch issue.issueType {
        case "candidate": return "同じファイル内容の候補が見つかりました。確認して紐付けてください。"
        case "conflict": return "記録された場所のファイル内容が変わっています。自動では置き換えません。"
        default: return "記録されたファイルが見つかりません。フォルダを指定して候補を探せます。"
        }
    }
}

private struct ImportSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let isLibraryCopy: Bool
    @State private var destination: URL?
    @State private var template: String

    init(model: AppModel) {
        self.model = model
        isLibraryCopy = model.isLibraryView
        _destination = State(initialValue: model.libraryURL)
        _template = State(initialValue: model.importTemplate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isLibraryCopy ? "ライブラリへコピー" : "写真を取り込む")
                .font(.title2.weight(.semibold))
            Text(isLibraryCopy
                ? "選択した写真を、コピー元ライブラリの構成を保ったままターゲットライブラリへコピーします。"
                : "選択した写真はJPGとCR3をセットで安全にコピーします。元のカード上のファイルは変更しません。")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label(sourceName, systemImage: sourceIcon)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Label(destination?.lastPathComponent ?? "保存先未選択", systemImage: "internaldrive")
                    .lineLimit(1)
                    .foregroundStyle(destination == nil ? .secondary : .primary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                Label("対象", systemImage: "photo.stack")
                Text("写真 \(model.selectedPhotoCount)組 / ファイル \(selectedFileCount)件")
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if isLibraryCopy {
                Picker("ターゲットライブラリ", selection: targetLibrarySelection) {
                    Text("保存先未選択").tag("")
                    ForEach(availableTargetLibraries, id: \.path) { libraryURL in
                        Text(libraryURL.lastPathComponent).tag(libraryURL.path)
                    }
                }
                .pickerStyle(.menu)
                Text(destination?.path ?? "保存先未選択")
                    .lineLimit(1)
                    .foregroundStyle(destination == nil ? .secondary : .primary)
                Toggle("ラベルもコピー", isOn: $model.copyLabelsOnLibraryCopy)
                    .help("コピー先ではラベル名を照合し、ラベルUUIDはコピー先で解決します")
            } else {
                HStack {
                    Text(destination?.path ?? "保存先未選択")
                        .lineLimit(1)
                        .foregroundStyle(destination == nil ? .secondary : .primary)
                    Spacer()
                    Button("選択…") { chooseDestination() }
                }
            }
            if !isLibraryCopy {
                TextField("フォルダ名テンプレート", text: $template)
                Text("使用できるトークン: {date}（yyyy-MM-dd）、{camera}。現在の値: \(template)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("JPG・CR3、ファイルのタイムスタンプ、元ライブラリのフォルダ構成を維持します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                Button(isLibraryCopy ? "コピーする" : "取り込む") {
                    guard destination != nil else { return }
                    dismiss()
                    if isLibraryCopy {
                        model.copySelectedToTargetLibrary()
                    } else if let destination {
                        model.importSelected(to: destination, template: template)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    destination == nil
                        || model.selectedPhotoCount == 0
                        || (isLibraryCopy && !model.canCopyToTargetLibrary)
                        || model.isBusy
                )
            }
        }
        .padding(28)
        .frame(width: isLibraryCopy ? 620 : 560)
    }

    private var availableTargetLibraries: [URL] {
        model.libraryURLs.filter { libraryURL in
            libraryURL.path != model.sourceURL?.path
        }
    }

    private var targetLibrarySelection: Binding<String> {
        Binding(
            get: { destination?.path ?? "" },
            set: { path in
                guard let libraryURL = availableTargetLibraries.first(where: { $0.path == path }) else { return }
                destination = libraryURL
                model.setTargetLibrary(libraryURL)
            }
        )
    }

    private var selectedFileCount: Int {
        model.selectedGroups.reduce(0) { count, group in
            count + group.importableVariants.count
        }
    }

    private var sourceName: String {
        model.sourceCamera?.name
            ?? model.sourceVolume?.name
            ?? model.sourceURL?.lastPathComponent
            ?? "選択元未設定"
    }

    private var sourceIcon: String {
        if isLibraryCopy { return "internaldrive" }
        if model.sourceCamera != nil { return "camera" }
        return model.sourceVolume == nil ? "folder" : "sdcard"
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { destination = panel.url }
    }
}

private struct ViewerSheet: View {
    @Bindable var model: AppModel
    @State private var loader: ThumbnailLoader

    init(model: AppModel) {
        self.model = model
        _loader = State(initialValue: ThumbnailLoader(services: model.thumbnailServices))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let group = model.viewerGroup {
                HStack(spacing: 14) {
                    Text(group.basename)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 16)
                    Text(model.viewerPositionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Button {
                        model.toggleViewerSelection()
                    } label: {
                        Image(systemName: model.selectedIDs.contains(group.id) ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(model.selectedIDs.contains(group.id) ? Color.accentColor : Color.secondary)
                    }
                    .help("取り込み対象を切り替え（Return）")
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    Button {
                        model.toggleViewerDeleteCandidate()
                    } label: {
                        Image(systemName: model.deleteCandidateIDs.contains(group.id) ? "trash.circle.fill" : "trash.circle")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(model.deleteCandidateIDs.contains(group.id) ? Color.red : Color.secondary)
                    }
                    .help("削除候補を切り替え（Delete）")
                    .buttonStyle(.plain)
                    Button("閉じる") {
                        model.closeViewer()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)

                Divider()

                ZStack {
                    Color.black
                    if let image = loader.image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(24)
                    } else if loader.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ViewerMetadataBar(group: group, showImportStatus: !model.isLibraryView)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .task(id: model.viewerGroup?.id) {
            guard let group = model.viewerGroup else { return }
            model.prioritizeMetadata(for: group.id, priority: .viewerCurrent)
            for neighbor in model.viewerNeighborGroups {
                model.prioritizeMetadata(for: neighbor.id, priority: .viewerNeighbor)
            }
            loader.load(for: group, maxPixel: 3200, priority: .viewerCurrent)
            if model.isCameraSource {
                model.thumbnailServices.file.clearViewerPrefetch()
                model.thumbnailServices.camera.updateViewerPrefetch(
                    groups: model.viewerNeighborGroups,
                    maxPixel: 2400
                )
            } else {
                model.thumbnailServices.camera.clearViewerPrefetch()
                model.thumbnailServices.file.updateViewerPrefetch(
                    groups: model.viewerNeighborGroups,
                    maxPixel: 2400
                )
            }
        }
        .onDisappear {
            loader.cancel()
            model.thumbnailServices.file.clearViewerPrefetch()
            model.thumbnailServices.camera.clearViewerPrefetch()
        }
        .onExitCommand { model.closeViewer() }
    }
}

private struct ViewerMetadataBar: View {
    let group: PhotoGroup
    let showImportStatus: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                if showImportStatus {
                    switch group.displayImportState {
                    case .imported:
                        ImportedStatusBadge(size: 18)
                    case .possible:
                        PossibleImportedStatusBadge(size: 18)
                    default:
                        EmptyView()
                    }
                }
                PhotoVariantBadges(group: group)
                Divider()
                    .frame(height: 15)
                if group.isMetadataLoaded {
                    Text(metadataLineOne)
                        .lineLimit(1)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(metadataLineTwo)
                        .lineLimit(1)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("メタデータ読み込み中…")
                        .lineLimit(1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 20)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var metadataLineOne: String {
        let date = group.metadata.captureDate.map(DateFormatters.detail.string(from:)) ?? "日時不明"
        let camera = group.metadata.cameraDisplayName ?? "カメラ不明"
        let lens = group.metadata.lensModel ?? "レンズ不明"
        return "\(date)  •  \(camera)  •  \(lens)"
    }

    private var metadataLineTwo: String {
        let values = [
            group.metadata.iso,
            group.metadata.shutterSpeed.map { "シャッター \($0)" },
            group.metadata.aperture.map { "絞り \($0)" }
        ].compactMap { $0 }
        return values.isEmpty ? "撮影情報不明" : values.joined(separator: "  •  ")
    }
}

@MainActor
@Observable package final class ViewerWindowManager: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var window: NSWindow?

    package override init() {
        super.init()
    }

    func update(model: AppModel) {
        self.model = model
        guard let group = model.viewerGroup else {
            closeWindow()
            return
        }

        if let window {
            window.title = group.basename
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: ViewerSheet(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = group.basename
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(width: 800, height: 600)
        // Keep the AppKit frame minimum explicit as well. The viewer is an
        // independent window, so this constraint is never inherited from the
        // main window or recalculated by a sheet presentation.
        window.minSize = NSSize(width: 800, height: 600)
        window.delegate = self
        self.window = window

        if let savedFrame, savedFrame.width >= 800, savedFrame.height >= 600 {
            window.setFrame(savedFrame, display: true)
        } else {
            window.setContentSize(NSSize(width: 1024, height: 720))
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    package func windowWillClose(_ notification: Notification) {
        saveCurrentFrame()
        window?.delegate = nil
        window = nil
        model?.closeViewer()
    }

    package func windowDidEndLiveResize(_ notification: Notification) {
        saveCurrentFrame()
    }

    package func windowDidMove(_ notification: Notification) {
        saveCurrentFrame()
    }

    private func closeWindow() {
        guard let window else { return }
        saveCurrentFrame()
        self.window = nil
        window.delegate = nil
        window.close()
    }

    private var savedFrame: NSRect? {
        guard let value = UserDefaults.standard.string(forKey: "viewerWindowFrame.v2") else { return nil }
        return NSRectFromString(value)
    }

    private func saveCurrentFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "viewerWindowFrame.v2")
    }
}
