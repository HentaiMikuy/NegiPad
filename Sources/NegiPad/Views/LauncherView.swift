import AppKit
import SwiftUI
import UniformTypeIdentifiers

// An interruptible spring for live reordering: when the pointer sweeps across
// several tiles in quick succession, each new move re-targets the in-flight
// animation smoothly instead of restarting an ease curve. Shared by the
// top-level grid and the folder overlay.
private let launcherReorderAnimation: Animation = .interactiveSpring(
    response: 0.26,
    dampingFraction: 0.86,
    blendDuration: 0.12
)

/// The folder overlay card's fixed size, shared with the exit-drop delegate
/// so its "outside the folder" hit test tracks the centered card whenever
/// the panel size changes.
private let folderOverlayCardSize = CGSize(width: 570, height: 350)

/// The last live reorder issued during the current drag. Drop delegates use
/// it as hysteresis: hovering the same target keeps the current placement
/// until the pointer decisively crosses to the other side, so jitter around
/// the tile midline never thrashes the model or restarts animations.
private struct LiveReorderPlacement: Equatable {
    let draggedID: String
    let targetID: String
    let placeAfter: Bool
}

struct LauncherView: View {
    /// Panel height while only a calculator result is showing: search header
    /// (76) + divider + result row (70) + divider + footer (48).
    static let compactPanelHeight: CGFloat = 196

    /// Columns that fit the user-configured panel width at ~98pt per tile
    /// (24pt grid padding + 8pt column spacing), reproducing the classic
    /// 7 columns at the default 760pt width.
    static func columnCount(forPanelWidth width: Double) -> Int {
        max(5, Int((width - 16) / 106))
    }

    /// Grid rows per page (horizontal paging mode) that fit the configured
    /// panel height below the fixed chrome (header, recently-installed
    /// strip, footer); 4 rows at the default 668pt height.
    static func rowCountPerPage(forPanelHeight height: Double) -> Int {
        max(2, Int((height - 240) / 104))
    }

    @EnvironmentObject private var library: AppLibrary
    @EnvironmentObject private var launcherSession: LauncherSession
    @EnvironmentObject private var launcherSettings: LauncherSettings
    @EnvironmentObject private var toolboxSettings: ToolboxSettings
    @FocusState private var searchIsFocused: Bool

    /// Full panel size from user settings; AppDelegate sizes the borderless
    /// NSPanel to match.
    private var panelSize: CGSize {
        launcherSettings.panelSize
    }

    private var columnCount: Int {
        Self.columnCount(forPanelWidth: panelSize.width)
    }

    private var rowCountPerPage: Int {
        Self.rowCountPerPage(forPanelHeight: panelSize.height)
    }

    @State private var searchText = ""
    @State private var selectedID: LauncherItem.ID?
    @State private var draggedID: String?
    @State private var folderDropTargetID: String?
    @State private var edgeDropTargetID: String?
    @State private var livePlacement: LiveReorderPlacement?
    @State private var openFolderID: String?
    @State private var folderStartsRenaming = false
    @State private var visiblePage = 0
    @State private var verticalScrollMetrics = LauncherScrollMetrics()
    @State private var aliasEditorApp: AppItem?
    @State private var aliasDraft = ""
    @State private var calculatorShowsCopied = false
    @State private var calculatorCopyResetTask: Task<Void, Never>?

    let onDismiss: () -> Void
    let onOpenManager: () -> Void
    /// Reports the height the panel should have (top edge fixed) whenever
    /// the launcher switches between full and calculator-only layouts.
    let onPreferredHeightChange: (CGFloat) -> Void
    /// Fires when the user-configured panel size changes so the host can
    /// resize and re-center the NSPanel while it is on screen.
    let onPanelSizeChange: () -> Void

    private var items: [LauncherItem] {
        library.launcherItems(matching: searchText)
    }

    private var recentlyInstalledApps: [AppItem] {
        library.recentlyInstalledApps(limit: columnCount)
    }

    private var showsRecentlyInstalledRow: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !recentlyInstalledApps.isEmpty
    }

    /// Live calculator readout for the current query, nil when the tool is
    /// disabled or the query isn't arithmetic. Parsing is a few microseconds
    /// on launcher-sized input, so no caching between body evaluations.
    private var calculation: CalculationResult? {
        guard toolboxSettings.isCalculatorEnabled else { return nil }
        return CalculatorEngine.evaluate(searchText)
    }

    /// The query is pure arithmetic: a result is showing and no app matched.
    /// The grid area carries no information, so the panel collapses to just
    /// header + result + footer.
    private var isCalculatorOnlyMode: Bool {
        calculation != nil && items.isEmpty
    }

    private var preferredPanelHeight: CGFloat {
        isCalculatorOnlyMode ? Self.compactPanelHeight : panelSize.height
    }

    private var itemIDs: [LauncherItem.ID] {
        items.map(\.id)
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 78), spacing: 8),
            count: columnCount
        )
    }

    private var itemsPerPage: Int {
        columnCount * rowCountPerPage
    }

    private var pages: [[LauncherItem]] {
        stride(from: 0, to: items.count, by: itemsPerPage).map { startIndex in
            let endIndex = min(startIndex + itemsPerPage, items.count)
            return Array(items[startIndex..<endIndex])
        }
    }

    private var pageCount: Int {
        pages.count
    }

    private var currentPageIndex: Int {
        min(max(visiblePage, 0), max(pageCount - 1, 0))
    }

    private var selectedItem: LauncherItem? {
        guard let selectedID else { return items.first }
        return items.first { $0.id == selectedID }
    }

    var body: some View {
        ZStack {
            mainContent
            folderOverlay
        }
        .frame(width: panelSize.width, height: preferredPanelHeight)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 30, y: 16)
        // The hosting view briefly keeps the old window size when the mode
        // flips; pinning the card to the top edge hides that transient.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: preferredPanelHeight) { _, newHeight in
            onPreferredHeightChange(newHeight)
        }
        .onChange(of: panelSize) {
            onPanelSizeChange()
        }
        .alert(
            "搜索别名",
            isPresented: Binding(
                get: { aliasEditorApp != nil },
                set: { if !$0 { aliasEditorApp = nil } }
            ),
            presenting: aliasEditorApp
        ) { app in
            TextField("例如：wx，聊天", text: $aliasDraft)
            Button("保存") {
                commitAliases(for: app)
            }
            Button("取消", role: .cancel) {
                aliasEditorApp = nil
            }
        } message: { app in
            Text("为“\(app.name)”设置搜索别名，多个别名用逗号分隔，留空则清除。")
        }
        .onAppear {
            prepareForPresentation()
        }
        .onChange(of: launcherSession.presentationID) {
            prepareForPresentation()
        }
        .onChange(of: itemIDs) { _, newIDs in
            if let selectedID, newIDs.contains(selectedID) {
                // While a drag is live-reordering, tiles (including the
                // selected one) may cross page boundaries every few ticks;
                // snapping the visible page to follow would yank the pager
                // around mid-drag. Edge zones own paging until the drop.
                if draggedID == nil {
                    syncVisiblePage(to: selectedID, animated: false)
                }
                return
            }
            selectedID = newIDs.first
            visiblePage = 0
        }
        .onChange(of: searchText) {
            openFolderID = nil
            visiblePage = 0
            resetCalculatorCopyFeedback()
        }
        .onChange(of: draggedID) { _, newValue in
            // Every performDrop path clears draggedID; that marks the end of
            // the drag, so the batched undo step and deferred save commit.
            if newValue == nil {
                livePlacement = nil
                library.endOrganizeSession()
            }
        }
        .onChange(of: launcherSettings.browsingMode) {
            syncVisiblePage(to: selectedID, animated: false)
        }
        .onExitCommand {
            if openFolderID != nil {
                closeFolder()
            } else {
                onDismiss()
            }
        }
        .onKeyPress(.downArrow) {
            guard openFolderID == nil else { return .ignored }
            moveSelectionVertically(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard openFolderID == nil else { return .ignored }
            moveSelectionVertically(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard openFolderID == nil else { return .ignored }
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard openFolderID == nil else { return .ignored }
            moveSelection(by: -1)
            return .handled
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider().opacity(0.7)
            if let calculation {
                CalculatorResultRow(
                    result: calculation,
                    showsCopied: calculatorShowsCopied,
                    respondsToReturn: items.isEmpty,
                    onCopy: { copyCalculationResult(calculation) }
                )
                Divider().opacity(0.7)
            }
            // The pager has no vertical scrolling, so it keeps the strip
            // pinned here as a header; in vertical-scroll mode the strip
            // lives inside the scroll view and scrolls away with the grid.
            if showsRecentlyInstalledRow
                && launcherSettings.browsingMode == .horizontalPaging {
                recentlyInstalledRow
                Divider().opacity(0.7)
            }
            if !isCalculatorOnlyMode {
                resultContent
                Divider().opacity(0.7)
            }
            footer
        }
    }

    @ViewBuilder
    private var folderOverlay: some View {
        if let openFolderID,
           let folder = library.folder(withID: openFolderID) {
            FolderOverlay(
                folder: folder,
                apps: library.apps(in: folder),
                panelSize: panelSize,
                beginsRenaming: folderStartsRenaming,
                onRename: { name in
                    library.renameFolder(folder.id, to: name)
                },
                onRemove: { appID in
                    guard library.removeApp(appID, fromFolder: folder.id) else {
                        return
                    }
                    selectedID = appID
                    closeFolder()
                },
                onLaunch: launch,
                onClose: {
                    closeFolder()
                }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索应用、拼音、别名或关键字…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .focused($searchIsFocused)
                .onSubmit {
                    // With a calculation showing and no app to launch, Enter
                    // naturally means "take the result".
                    if let calculation, items.isEmpty {
                        copyCalculationResult(calculation)
                    } else {
                        activateSelectedItem()
                    }
                }

            if library.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 76)
    }

    private var recentlyInstalledRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近安装")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)

            // Same column layout as the grid below so the tiles line up.
            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(recentlyInstalledApps) { app in
                    LauncherRecentTile(app: app) {
                        launch(app)
                    }
                    .contextMenu {
                        appContextMenu(app)
                    }
                    .help(recentInstallHint(for: app))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func recentInstallHint(for app: AppItem) -> String {
        guard let installDate = app.installDate else { return app.name }
        let relativeDate = RelativeDateTimeFormatter()
            .localizedString(for: installDate, relativeTo: Date())
        return "\(app.name)（\(relativeDate)安装）"
    }

    @ViewBuilder
    private var resultContent: some View {
        if items.isEmpty && !library.isLoading {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("没有找到应用")
                    .font(.headline)
                Text("尝试输入应用名称、分类或 Bundle ID")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch launcherSettings.browsingMode {
            case .verticalScroll:
                verticalResultContent
            case .horizontalPaging:
                pagedResultContent
            }
        }
    }

    private var verticalResultContent: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if showsRecentlyInstalledRow {
                            recentlyInstalledRow
                            Divider().opacity(0.7)
                        }

                        LazyVGrid(
                            columns: gridColumns,
                            spacing: 8
                        ) {
                            ForEach(items) { item in
                                launcherItemView(item)
                                    .id(item.id)
                            }
                        }
                        .padding(12)
                    }
                    // Metrics live on the whole scroll content (strip + grid)
                    // so the custom scroll bar tracks the true content height.
                    .background {
                        GeometryReader { contentGeometry in
                            Color.clear
                                .preference(
                                    key: LauncherScrollMetricsKey.self,
                                    value: LauncherScrollMetrics(
                                        offset: -contentGeometry
                                            .frame(in: .named("launcherVerticalScroll"))
                                            .minY,
                                        contentHeight: contentGeometry.size.height
                                    )
                                )
                        }
                    }
                }
                .coordinateSpace(name: "launcherVerticalScroll")
                .scrollIndicators(.hidden)
                .onDrop(
                    of: [UTType.text],
                    delegate: LauncherBlankAreaDropDelegate(
                        draggedID: $draggedID,
                        canReorder: searchText.isEmpty,
                        moveToEnd: { id in
                            withAnimation(launcherReorderAnimation) {
                                library.moveItemToEnd(id)
                            }
                        }
                    )
                )
                .onPreferenceChange(LauncherScrollMetricsKey.self) { metrics in
                    verticalScrollMetrics = metrics
                }
                .overlay(alignment: .trailing) {
                    LauncherScrollBar(
                        metrics: verticalScrollMetrics,
                        viewportHeight: geometry.size.height
                    )
                }
                .onChange(of: selectedID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newValue)
                    }
                }
            }
        }
    }

    private var pagedResultContent: some View {
        GeometryReader { geometry in
            let pageWidth = max(geometry.size.width, 1)

            // A hand-rolled pager instead of ScrollView + scrollPosition(id:):
            // the wheel monitor already owns every paging gesture, and the
            // native binding writes back intermediate pages mid-animation,
            // which made the indicator and the content fight each other.
            HStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, pageItems in
                    Group {
                        if abs(pageIndex - currentPageIndex) <= 1 {
                            LazyVGrid(
                                columns: gridColumns,
                                spacing: 8
                            ) {
                                ForEach(pageItems) { item in
                                    launcherItemView(item)
                                }
                            }
                            .padding(12)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(
                        width: pageWidth,
                        height: geometry.size.height,
                        alignment: .top
                    )
                }
            }
            .offset(x: -CGFloat(currentPageIndex) * pageWidth)
            .frame(
                width: pageWidth,
                height: geometry.size.height,
                alignment: .leading
            )
            .clipped()
            .onDrop(
                of: [UTType.text],
                delegate: LauncherBlankAreaDropDelegate(
                    draggedID: $draggedID,
                    canReorder: searchText.isEmpty,
                    moveToEnd: { id in
                        withAnimation(launcherReorderAnimation) {
                            library.moveItemToEnd(id)
                        }
                    }
                )
            )
            .overlay {
                // Dwelling near either edge mid-drag flips pages, so an item
                // can be carried to a tile that lives on another page.
                if draggedID != nil && pageCount > 1 {
                    HStack(spacing: 0) {
                        LauncherEdgePagingZone(
                            symbol: "chevron.compact.left",
                            isAvailable: currentPageIndex > 0,
                            onPage: { movePage(by: -1) }
                        )
                        Spacer(minLength: 0)
                        LauncherEdgePagingZone(
                            symbol: "chevron.compact.right",
                            isAvailable: currentPageIndex < pageCount - 1,
                            onPage: { movePage(by: 1) }
                        )
                    }
                }
            }
            .onChange(of: selectedID) { _, newValue in
                syncVisiblePage(to: newValue, animated: true)
            }
            .onChange(of: visiblePage) { _, newPage in
                selectFirstItemIfNeeded(on: newPage)
            }
            .background {
                LauncherPagingWheelMonitor(
                    isEnabled: openFolderID == nil,
                    behavior: launcherSettings.pagingWheelBehavior,
                    onPage: movePage
                )
            }
        }
    }

    @ViewBuilder
    private func launcherItemView(_ item: LauncherItem) -> some View {
        switch item {
        case let .app(app):
            LauncherGridTile(
                app: app,
                isFavorite: library.isFavorite(app),
                isSelected: selectedID == app.id,
                isFolderTarget: folderDropTargetID == app.id,
                isEdgeTarget: edgeDropTargetID == app.id,
                onLaunch: {
                    launch(app)
                }
            )
            .contextMenu {
                appContextMenu(app)
            }
            .onDrag {
                library.beginOrganizeSession()
                draggedID = app.id
                return NSItemProvider(object: app.id as NSString)
            }
            .onDrop(
                of: [UTType.text],
                delegate: AppTileDropDelegate(
                    targetAppID: app.id,
                    draggedID: $draggedID,
                    folderTargetID: $folderDropTargetID,
                    edgeTargetID: $edgeDropTargetID,
                    livePlacement: $livePlacement,
                    createFolder: { draggedID, targetID in
                        guard let folderID = library.createFolder(
                            containing: draggedID,
                            and: targetID
                        ) else {
                            return
                        }
                        selectedID = folderID
                        openFolder(folderID)
                    },
                    move: { draggedID, targetID, placeAfter in
                        withAnimation(launcherReorderAnimation) {
                            library.moveItem(
                                draggedID,
                                relativeTo: targetID,
                                placeAfter: placeAfter
                            )
                        }
                    }
                )
            )

        case let .folder(folder, apps):
            LauncherFolderTile(
                folder: folder,
                apps: apps,
                isSelected: selectedID == folder.id,
                isDropTarget: folderDropTargetID == folder.id,
                isEdgeTarget: edgeDropTargetID == folder.id,
                onOpen: {
                    selectedID = folder.id
                    openFolder(folder.id)
                }
            )
            .contextMenu {
                folderContextMenu(folder)
            }
            .onDrag {
                library.beginOrganizeSession()
                draggedID = folder.id
                return NSItemProvider(object: folder.id as NSString)
            }
            .onDrop(
                of: [UTType.text],
                delegate: FolderTileDropDelegate(
                    folderID: folder.id,
                    draggedID: $draggedID,
                    folderTargetID: $folderDropTargetID,
                    edgeTargetID: $edgeDropTargetID,
                    livePlacement: $livePlacement,
                    addToFolder: { appID, folderID in
                        library.addApp(appID, toFolder: folderID)
                        selectedID = folderID
                    },
                    move: { draggedID, targetID, placeAfter in
                        withAnimation(launcherReorderAnimation) {
                            library.moveItem(
                                draggedID,
                                relativeTo: targetID,
                                placeAfter: placeAfter
                            )
                        }
                    }
                )
            )
        }
    }

    @ViewBuilder
    private func appContextMenu(_ app: AppItem) -> some View {
        Button {
            launch(app)
        } label: {
            Label("打开", systemImage: "play.fill")
        }

        Button {
            library.revealInFinder(app)
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }

        Button {
            copyPath(of: app)
        } label: {
            Label("拷贝路径", systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            library.toggleFavorite(app)
        } label: {
            Label(
                library.isFavorite(app) ? "取消收藏" : "添加到收藏",
                systemImage: library.isFavorite(app) ? "star.slash" : "star"
            )
        }

        Button {
            beginEditingAliases(for: app)
        } label: {
            Label("搜索别名…", systemImage: "text.badge.plus")
        }

        Menu("移动到分类") {
            Button("使用自动分类") {
                library.setCategory(nil, for: app)
            }
            Divider()
            ForEach(library.categories) { destination in
                Button {
                    library.setCategory(destination, for: app)
                } label: {
                    Label(destination.rawValue, systemImage: destination.symbol)
                }
            }
        }

        if !library.folders.isEmpty {
            Menu("移入文件夹") {
                ForEach(library.folders) { folder in
                    Button {
                        library.addApp(app.id, toFolder: folder.id)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
            }
        }

        if library.folderContaining(app.id) != nil {
            Button {
                if let folder = library.folderContaining(app.id) {
                    library.removeApp(app.id, fromFolder: folder.id)
                }
            } label: {
                Label("移出文件夹", systemImage: "arrow.up.forward.app")
            }
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: AppFolder) -> some View {
        Button {
            selectedID = folder.id
            openFolder(folder.id)
        } label: {
            Label("打开", systemImage: "folder")
        }

        Button {
            selectedID = folder.id
            openFolder(folder.id, renaming: true)
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            library.dissolveFolder(folder.id)
        } label: {
            Label("解散文件夹", systemImage: "folder.badge.minus")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch selectedItem {
            case let .app(app):
                Label(
                    library.category(for: app).rawValue,
                    systemImage: library.category(for: app).symbol
                )
                .foregroundStyle(library.category(for: app).tint)
                .lineLimit(1)

            case let .folder(folder, apps):
                Label("\(folder.name) · \(apps.count) 个应用", systemImage: "folder.fill")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

            case nil:
                Text("共 \(library.apps.count) 个应用")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if launcherSettings.browsingMode == .horizontalPaging && pageCount > 1 {
                pageControls
            } else {
                Text("拖到图标中央可创建文件夹")
                    .foregroundStyle(.tertiary)
            }

            Button {
                library.undoLastOrganize()
            } label: {
                Label("撤销整理", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(!library.canUndo)
            .opacity(library.canUndo ? 1 : 0.35)
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销上一次整理操作（⌘Z）")

            Button(action: onOpenManager) {
                Label("应用管理", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.plain)

            keyHint("⌘ ,")
            keyHint("↵")
            keyHint("esc")
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var pageControls: some View {
        HStack(spacing: 6) {
            Button {
                movePage(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(currentPageIndex == 0)
            .help("上一页")

            Text("\(currentPageIndex + 1) / \(pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34)

            Button {
                movePage(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(currentPageIndex >= pageCount - 1)
            .help("下一页")
        }
    }

    private func keyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced().weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func movePage(by offset: Int) {
        guard pageCount > 0 else { return }
        let targetPage = min(max(currentPageIndex + offset, 0), pageCount - 1)
        guard targetPage != currentPageIndex else { return }

        let firstItemIndex = targetPage * itemsPerPage
        if items.indices.contains(firstItemIndex) {
            selectedID = items[firstItemIndex].id
        }

        withAnimation(.easeInOut(duration: 0.24)) {
            visiblePage = targetPage
        }
    }

    private func syncVisiblePage(to itemID: LauncherItem.ID?, animated: Bool) {
        guard launcherSettings.browsingMode == .horizontalPaging,
              let itemID,
              let itemIndex = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let targetPage = itemIndex / itemsPerPage
        guard visiblePage != targetPage else { return }

        if animated {
            withAnimation(.easeInOut(duration: 0.24)) {
                visiblePage = targetPage
            }
        } else {
            visiblePage = targetPage
        }
    }

    private func selectFirstItemIfNeeded(on page: Int) {
        guard page >= 0,
              page < pageCount else {
            return
        }

        let pageRange = (page * itemsPerPage)..<min((page + 1) * itemsPerPage, items.count)
        if let selectedID,
           let selectedIndex = items.firstIndex(where: { $0.id == selectedID }),
           pageRange.contains(selectedIndex) {
            return
        }

        guard items.indices.contains(pageRange.lowerBound) else { return }
        selectedID = items[pageRange.lowerBound].id
    }

    private func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }

        let currentIndex = selectedID.flatMap { id in
            items.firstIndex { $0.id == id }
        } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), items.count - 1)
        selectedID = items[nextIndex].id
    }

    private func moveSelectionVertically(by rowOffset: Int) {
        guard !items.isEmpty else { return }

        let currentIndex = selectedID.flatMap { id in
            items.firstIndex { $0.id == id }
        } ?? 0
        let proposedIndex = currentIndex + rowOffset * columnCount

        if proposedIndex >= 0 && proposedIndex < items.count {
            selectedID = items[proposedIndex].id
            return
        }

        guard rowOffset > 0 else { return }

        let lastRowStart = ((items.count - 1) / columnCount) * columnCount
        guard currentIndex < lastRowStart else { return }

        let sameColumnIndex = lastRowStart + currentIndex % columnCount
        selectedID = items[min(sameColumnIndex, items.count - 1)].id
    }

    private func activateSelectedItem() {
        guard let selectedItem else { return }

        switch selectedItem {
        case let .app(app):
            launch(app)
        case let .folder(folder, _):
            openFolder(folder.id)
        }
    }

    private func openFolder(_ folderID: String, renaming: Bool = false) {
        searchIsFocused = false
        folderStartsRenaming = renaming
        withAnimation(.easeOut(duration: 0.16)) {
            openFolderID = folderID
        }
    }

    private func closeFolder() {
        folderStartsRenaming = false
        withAnimation(.easeOut(duration: 0.16)) {
            openFolderID = nil
        }
        DispatchQueue.main.async {
            searchIsFocused = true
        }
    }

    private func launch(_ app: AppItem) {
        library.launch(app)
        onDismiss()
    }

    private func copyPath(of app: AppItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(app.url.path, forType: .string)
    }

    private func copyCalculationResult(_ result: CalculationResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.rawText, forType: .string)

        calculatorCopyResetTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            calculatorShowsCopied = true
        }
        calculatorCopyResetTask = Task {
            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                calculatorShowsCopied = false
            }
        }
    }

    private func resetCalculatorCopyFeedback() {
        calculatorCopyResetTask?.cancel()
        calculatorCopyResetTask = nil
        calculatorShowsCopied = false
    }

    private func beginEditingAliases(for app: AppItem) {
        aliasDraft = library.aliases(for: app.id).joined(separator: "，")
        aliasEditorApp = app
    }

    private func commitAliases(for app: AppItem) {
        library.setAliases(
            aliasDraft.components(separatedBy: CharacterSet(charactersIn: ",，、")),
            for: app.id
        )
        aliasEditorApp = nil
    }

    private func prepareForPresentation() {
        library.endOrganizeSession()
        searchText = ""
        selectedID = library.launcherItems().first?.id
        draggedID = nil
        folderDropTargetID = nil
        edgeDropTargetID = nil
        livePlacement = nil
        openFolderID = nil
        folderStartsRenaming = false
        visiblePage = 0
        resetCalculatorCopyFeedback()

        DispatchQueue.main.async {
            searchIsFocused = true
        }
    }
}

private struct LauncherPagingWheelMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let behavior: PagingWheelBehavior
    let onPage: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        context.coordinator.update(
            isEnabled: isEnabled,
            behavior: behavior,
            onPage: onPage
        )
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(
            isEnabled: isEnabled,
            behavior: behavior,
            onPage: onPage
        )
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private var eventMonitor: Any?
        private var accumulatedDelta: CGFloat = 0
        private var isGestureLocked = false
        private var unlockTask: Task<Void, Never>?
        private var isEnabled = false
        private var behavior: PagingWheelBehavior = .shiftModified
        private var onPage: (Int) -> Void = { _ in }

        func attach(to _: NSView) {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                let wasConsumed = MainActor.assumeIsolated {
                    self?.process(event) ?? false
                }
                return wasConsumed ? nil : event
            }
        }

        private func process(_ event: NSEvent) -> Bool {
            let targetWindow = event.window
                ?? NSApp.windows.first(where: { $0.isKeyWindow })
            guard isEnabled,
                  targetWindow is LauncherPanel else {
                return false
            }

            let verticalMagnitude = abs(event.scrollingDeltaY)
            let horizontalMagnitude = abs(event.scrollingDeltaX)
            guard max(verticalMagnitude, horizontalMagnitude) > 0 else {
                return false
            }

            let isTrackpadGesture = event.phase != [] || event.momentumPhase != []

            // Some mouse drivers convert Shift + vertical wheel into a
            // horizontal delta before the local event monitor sees it, so
            // page on whichever axis is dominant.
            let wheelDelta = horizontalMagnitude > verticalMagnitude
                ? event.scrollingDeltaX
                : event.scrollingDeltaY

            if behavior == .shiftModified {
                let shiftIsPressed = event.modifierFlags.contains(.shift)
                    || NSEvent.modifierFlags.contains(.shift)

                // The Shift requirement only concerns the vertical wheel; a
                // horizontal trackpad swipe pages Launchpad-style either way.
                let isHorizontalSwipe = isTrackpadGesture
                    && horizontalMagnitude > verticalMagnitude
                guard shiftIsPressed || isHorizontalSwipe else {
                    // AppKit redirects a plain vertical wheel to a scroll view
                    // that can only scroll horizontally, so the event must be
                    // swallowed — not passed through — to keep the pager still
                    // while Shift is not held.
                    return true
                }
            }

            handleWheelScroll(event, delta: wheelDelta)
            return true
        }

        func update(
            isEnabled: Bool,
            behavior: PagingWheelBehavior,
            onPage: @escaping (Int) -> Void
        ) {
            self.isEnabled = isEnabled
            if self.behavior != behavior {
                resetGesture()
            }
            self.behavior = behavior
            self.onPage = onPage

            if !isEnabled {
                resetGesture()
            }
        }

        func stop() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            unlockTask?.cancel()
            unlockTask = nil
        }

        private func handleWheelScroll(_ event: NSEvent, delta: CGFloat) {
            let isTrackpadGesture = event.phase != [] || event.momentumPhase != []

            if event.phase == .began {
                // A new swipe starts a fresh gesture even if the previous
                // momentum tail is still being delivered.
                resetGesture()
            }

            if isTrackpadGesture {
                // Keep re-arming while the swipe (and its momentum) lasts so
                // one trackpad gesture flips exactly one page.
                scheduleGestureReset(after: .milliseconds(280))
            }

            guard !isGestureLocked else { return }

            // scrollingDelta* already honors the system "natural scrolling"
            // preference, so it is used as-is: a positive delta asks for
            // earlier content (previous page), a negative one for the next.
            accumulatedDelta += delta

            // High-resolution mouse wheels and trackpads often emit deltas
            // below 1pt per event. A small accumulated threshold keeps a
            // single wheel gesture responsive, while the gesture lock below
            // still prevents one inertial scroll from skipping multiple pages.
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 0.5 : 0.1
            guard abs(accumulatedDelta) >= threshold else { return }

            let pageOffset = accumulatedDelta > 0 ? -1 : 1
            accumulatedDelta = 0
            isGestureLocked = true
            onPage(pageOffset)

            if !isTrackpadGesture {
                // A notched wheel has no gesture phases; unlock after a fixed
                // cooldown so a sustained roll keeps flipping pages.
                scheduleGestureReset(after: .milliseconds(200))
            }
        }

        private func scheduleGestureReset(after delay: Duration) {
            unlockTask?.cancel()
            unlockTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.resetGesture()
            }
        }

        private func resetGesture() {
            accumulatedDelta = 0
            isGestureLocked = false
        }
    }
}

private struct LauncherScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
}

private struct LauncherScrollMetricsKey: PreferenceKey {
    static let defaultValue = LauncherScrollMetrics()

    static func reduce(
        value: inout LauncherScrollMetrics,
        nextValue: () -> LauncherScrollMetrics
    ) {
        value = nextValue()
    }
}

/// A slim capsule scroll indicator that matches the launcher's translucent
/// styling: it fades in while scrolling, fades out shortly after the scroll
/// settles, and widens with a subtle track while the pointer hovers over it.
private struct LauncherScrollBar: View {
    let metrics: LauncherScrollMetrics
    let viewportHeight: CGFloat

    @State private var isVisible = false
    @State private var isHovering = false
    @State private var fadeTask: Task<Void, Never>?

    private let verticalInset: CGFloat = 6
    private let minThumbHeight: CGFloat = 36

    private var scrollableRange: CGFloat {
        metrics.contentHeight - viewportHeight
    }

    private var isScrollable: Bool {
        scrollableRange > 1
    }

    private var trackHeight: CGFloat {
        max(viewportHeight - verticalInset * 2, 0)
    }

    private var thumbHeight: CGFloat {
        guard isScrollable, metrics.contentHeight > 0 else { return 0 }
        let proportionalHeight = trackHeight * viewportHeight / metrics.contentHeight
        return min(max(proportionalHeight, minThumbHeight), trackHeight)
    }

    private var thumbOffset: CGFloat {
        guard isScrollable else { return verticalInset }
        let progress = min(max(metrics.offset / scrollableRange, 0), 1)
        return verticalInset + progress * (trackHeight - thumbHeight)
    }

    var body: some View {
        if isScrollable {
            ZStack(alignment: .top) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0))
                    .padding(.vertical, verticalInset)

                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.42 : 0.26))
                    .frame(height: thumbHeight)
                    .offset(y: thumbOffset)
            }
            .frame(width: isHovering ? 7 : 4)
            .frame(width: 14, alignment: .trailing)
            .padding(.trailing, 3)
            .contentShape(Rectangle())
            .opacity(isVisible || isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .animation(.easeInOut(duration: 0.3), value: isVisible)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    fadeTask?.cancel()
                } else {
                    scheduleFade()
                }
            }
            .onChange(of: metrics) {
                flash()
            }
            .onAppear {
                flash()
            }
            .onDisappear {
                fadeTask?.cancel()
            }
        }
    }

    private func flash() {
        isVisible = true
        scheduleFade()
    }

    private func scheduleFade() {
        fadeTask?.cancel()
        fadeTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}

/// The live calculator readout under the search field. The whole card is a
/// single click target that copies the plain-text result.
private struct CalculatorResultRow: View {
    @State private var isHovering = false

    let result: CalculationResult
    let showsCopied: Bool
    /// Whether Enter currently copies (true when no app results compete for
    /// the return key); only affects the hint text.
    let respondsToReturn: Bool
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 14) {
                Image(systemName: "equal.square.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("计算器")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(result.displayText)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                }

                Spacer(minLength: 12)

                if showsCopied {
                    Label("已拷贝", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    Text(respondsToReturn ? "点击或 ⏎ 拷贝" : "点击拷贝")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Fixed height keeps LauncherView.compactPanelHeight exact.
            .frame(height: 70)
            .contentShape(Rectangle())
            .background(Color.white.opacity(isHovering ? 0.05 : 0))
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("将计算结果拷贝到剪贴板")
    }
}

/// A compact tile for the single-row "recently installed" strip under the
/// search field: pointer-driven only, so it stays out of the grid's
/// keyboard-selection and drag-reorder machinery.
private struct LauncherRecentTile: View {
    @State private var isHovering = false

    let app: AppItem
    let onLaunch: () -> Void

    var body: some View {
        Button(action: onLaunch) {
            VStack(spacing: 5) {
                AppIconView(app: app, size: 34)
                    .shadow(color: .black.opacity(0.14), radius: 3, y: 1.5)

                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.07 : 0))
            }
            .scaleEffect(isHovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct LauncherGridTile: View {
    @State private var isHovering = false

    let app: AppItem
    let isFavorite: Bool
    let isSelected: Bool
    let isFolderTarget: Bool
    let isEdgeTarget: Bool
    let onLaunch: () -> Void

    var body: some View {
        Button(action: onLaunch) {
            VStack(spacing: 6) {
                AppIconView(app: app, size: 48)
                    .shadow(color: .black.opacity(0.16), radius: 4, y: 2)

                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(tileBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(tileBorder, lineWidth: isFolderTarget ? 2 : 1.5)
            }
            .overlay(alignment: .topTrailing) {
                if isFolderTarget {
                    Image(systemName: "folder.badge.plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(7)
                } else if isSelected {
                    Image(systemName: "return")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(7)
                } else if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(7)
                }
            }
            .scaleEffect(isFolderTarget ? 1.08 : (isHovering && !isSelected ? 1.025 : 1))
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isSelected)
            .animation(.easeOut(duration: 0.12), value: isFolderTarget)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var tileBackground: Color {
        if isFolderTarget {
            return Color.accentColor.opacity(0.28)
        }
        if isSelected || isEdgeTarget || isHovering {
            return Color.white.opacity(0.07)
        }
        return .clear
    }

    private var tileBorder: Color {
        if isFolderTarget {
            return Color.accentColor.opacity(0.9)
        }
        if isEdgeTarget || isHovering {
            return Color.white.opacity(0.14)
        }
        return .clear
    }
}

private struct LauncherFolderTile: View {
    @State private var isHovering = false

    let folder: AppFolder
    let apps: [AppItem]
    let isSelected: Bool
    let isDropTarget: Bool
    let isEdgeTarget: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 6) {
                // A plain eager 2x2 grid: a nested LazyVGrid inside the lazy
                // launcher grid gets kept alive without reliably re-running
                // its cells' .task, which intermittently left the preview
                // icons blank.
                VStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 3) {
                            ForEach(0..<2, id: \.self) { column in
                                if let app = previewApp(atRow: row, column: column) {
                                    AppIconView(app: app, size: 22)
                                        .id(app.id)
                                } else {
                                    Color.clear
                                        .frame(width: 22, height: 22)
                                }
                            }
                        }
                    }
                }
                .padding(5)
                .frame(width: 56, height: 56)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))

                Text(folder.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        isDropTarget
                            ? Color.accentColor.opacity(0.28)
                            : Color.white.opacity(
                                isSelected || isEdgeTarget || isHovering ? 0.07 : 0
                            )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(
                        isDropTarget
                            ? Color.accentColor.opacity(0.9)
                            : Color.white.opacity(isEdgeTarget ? 0.14 : 0),
                        lineWidth: isDropTarget ? 2 : 1.5
                    )
            }
            .scaleEffect(isDropTarget ? 1.08 : (isHovering ? 1.025 : 1))
            .animation(.easeOut(duration: 0.12), value: isDropTarget)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private func previewApp(atRow row: Int, column: Int) -> AppItem? {
        let index = row * 2 + column
        guard index < min(apps.count, 4) else { return nil }
        return apps[index]
    }
}

private struct FolderOverlay: View {
    private let columnCount = 5

    @EnvironmentObject private var library: AppLibrary
    @FocusState private var folderNameIsFocused: Bool
    @FocusState private var gridIsFocused: Bool
    @State private var folderName: String
    @State private var isEditingName = false
    @State private var draggedAppID: String?
    @State private var reorderTargetID: String?
    @State private var livePlacement: LiveReorderPlacement?
    @State private var isExitDropTarget = false
    @State private var selectedAppID: String?

    let folder: AppFolder
    let apps: [AppItem]
    /// Current launcher panel size, forwarded to the exit-drop delegate so
    /// its "outside the folder card" hit test tracks the configured size.
    let panelSize: CGSize
    let beginsRenaming: Bool
    let onRename: (String) -> Void
    let onRemove: (String) -> Void
    let onLaunch: (AppItem) -> Void
    let onClose: () -> Void

    init(
        folder: AppFolder,
        apps: [AppItem],
        panelSize: CGSize,
        beginsRenaming: Bool,
        onRename: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void,
        onLaunch: @escaping (AppItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.folder = folder
        self.apps = apps
        self.panelSize = panelSize
        self.beginsRenaming = beginsRenaming
        self.onRename = onRename
        self.onRemove = onRemove
        self.onLaunch = onLaunch
        self.onClose = onClose
        _folderName = State(initialValue: folder.name)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)

            VStack(spacing: 16) {
                ZStack {
                    if isEditingName {
                        TextField("文件夹名称", text: $folderName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 16, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .frame(width: 300)
                            .focused($folderNameIsFocused)
                            .onSubmit {
                                finishEditingName()
                            }
                    } else {
                        Text(folderName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                beginEditingName()
                            }
                            .help("双击修改文件夹名称")
                    }
                }
                .frame(height: 30)

                memberGrid
            }
            .padding(22)
            .frame(
                width: folderOverlayCardSize.width,
                height: folderOverlayCardSize.height
            )
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 24, y: 12)

            if draggedAppID != nil {
                VStack {
                    Spacer()
                    Label(
                        isExitDropTarget ? "松开以移出文件夹" : "拖到文件夹外",
                        systemImage: isExitDropTarget
                            ? "arrow.up.forward.app.fill"
                            : "arrow.up.forward.app"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isExitDropTarget ? Color.accentColor : .secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .onDrop(
            of: [UTType.text],
            delegate: FolderExitDropDelegate(
                panelSize: panelSize,
                draggedAppID: $draggedAppID,
                isExitDropTarget: $isExitDropTarget,
                removeFromFolder: onRemove
            )
        )
        .onChange(of: folderNameIsFocused) { _, isFocused in
            if !isFocused && isEditingName {
                finishEditingName()
            }
        }
        .onChange(of: apps) { _, newApps in
            if let selectedAppID,
               newApps.contains(where: { $0.id == selectedAppID }) {
                return
            }
            selectedAppID = newApps.first?.id
        }
        .onChange(of: draggedAppID) { _, newValue in
            if newValue == nil {
                livePlacement = nil
                library.endOrganizeSession()
            }
        }
        .onAppear {
            selectedAppID = apps.first?.id
            if beginsRenaming {
                beginEditingName()
            } else {
                DispatchQueue.main.async {
                    gridIsFocused = true
                }
            }
        }
    }

    private var memberGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 72), spacing: 12),
                    count: columnCount
                ),
                spacing: 12
            ) {
                ForEach(apps) { app in
                    memberTile(app)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($gridIsFocused)
        .onMoveCommand { direction in
            guard !isEditingName else { return }
            moveSelection(direction)
        }
        .onKeyPress(.return) {
            guard !isEditingName,
                  let app = apps.first(where: { $0.id == selectedAppID }) else {
                return .ignored
            }
            onLaunch(app)
            return .handled
        }
    }

    private func memberTile(_ app: AppItem) -> some View {
        Button {
            selectedAppID = app.id
            onLaunch(app)
        } label: {
            VStack(spacing: 7) {
                AppIconView(app: app, size: 48)
                Text(app.name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 82)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        selectedAppID == app.id
                            ? Color.white.opacity(0.07)
                            : .clear
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        reorderTargetID == app.id
                            ? Color.accentColor.opacity(0.9)
                            : .clear,
                        lineWidth: 2
                    )
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            memberContextMenu(app)
        }
        .onDrag {
            library.beginOrganizeSession()
            draggedAppID = app.id
            selectedAppID = app.id
            return NSItemProvider(object: app.id as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: FolderMemberDropDelegate(
                targetAppID: app.id,
                draggedAppID: $draggedAppID,
                reorderTargetID: $reorderTargetID,
                livePlacement: $livePlacement,
                move: { draggedID, targetID, placeAfter in
                    withAnimation(launcherReorderAnimation) {
                        library.moveApp(
                            draggedID,
                            relativeTo: targetID,
                            placeAfter: placeAfter,
                            inFolder: folder.id
                        )
                    }
                }
            )
        )
    }

    @ViewBuilder
    private func memberContextMenu(_ app: AppItem) -> some View {
        Button {
            onLaunch(app)
        } label: {
            Label("打开", systemImage: "play.fill")
        }

        Button {
            library.toggleFavorite(app)
        } label: {
            Label(
                library.isFavorite(app) ? "取消收藏" : "添加到收藏",
                systemImage: library.isFavorite(app) ? "star.slash" : "star"
            )
        }

        Menu("移动到分类") {
            Button("使用自动分类") {
                library.setCategory(nil, for: app)
            }
            Divider()
            ForEach(library.categories) { destination in
                Button {
                    library.setCategory(destination, for: app)
                } label: {
                    Label(destination.rawValue, systemImage: destination.symbol)
                }
            }
        }

        Divider()

        Button {
            onRemove(app.id)
        } label: {
            Label("移出文件夹", systemImage: "arrow.up.forward.app")
        }

        Button {
            library.revealInFinder(app)
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !apps.isEmpty else { return }

        let currentIndex = apps.firstIndex { $0.id == selectedAppID } ?? 0
        var nextIndex = currentIndex

        switch direction {
        case .left:
            nextIndex = max(currentIndex - 1, 0)
        case .right:
            nextIndex = min(currentIndex + 1, apps.count - 1)
        case .up:
            if currentIndex - columnCount >= 0 {
                nextIndex = currentIndex - columnCount
            }
        case .down:
            if currentIndex + columnCount < apps.count {
                nextIndex = currentIndex + columnCount
            } else {
                let lastRowStart = ((apps.count - 1) / columnCount) * columnCount
                if currentIndex < lastRowStart {
                    nextIndex = apps.count - 1
                }
            }
        @unknown default:
            break
        }

        selectedAppID = apps[nextIndex].id
    }

    private func close() {
        if isEditingName {
            finishEditingName()
        }
        onClose()
    }

    private func beginEditingName() {
        isEditingName = true
        DispatchQueue.main.async {
            folderNameIsFocused = true
        }
    }

    private func finishEditingName() {
        guard isEditingName else { return }

        let trimmedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        folderName = trimmedName.isEmpty ? "应用文件夹" : trimmedName
        isEditingName = false
        folderNameIsFocused = false
        onRename(folderName)
        DispatchQueue.main.async {
            gridIsFocused = true
        }
    }
}

private struct FolderExitDropDelegate: DropDelegate {
    /// Full panel size; drop locations arrive in this coordinate space.
    let panelSize: CGSize

    /// The overlay card centered in the panel, in the drop area's (full
    /// panel) coordinate space.
    private var folderFrame: CGRect {
        CGRect(
            x: (panelSize.width - folderOverlayCardSize.width) / 2,
            y: (panelSize.height - folderOverlayCardSize.height) / 2,
            width: folderOverlayCardSize.width,
            height: folderOverlayCardSize.height
        )
    }

    @Binding var draggedAppID: String?
    @Binding var isExitDropTarget: Bool
    let removeFromFolder: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggedAppID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let isOutsideFolder = !folderFrame.contains(info.location)
        isExitDropTarget = isOutsideFolder
        return DropProposal(operation: isOutsideFolder ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        // Only the highlight resets here: entering a member tile's nested
        // drop area also triggers this callback, and clearing draggedAppID
        // there would break in-folder reordering.
        isExitDropTarget = false
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedAppID = nil
            isExitDropTarget = false
        }

        guard let draggedAppID,
              !folderFrame.contains(info.location) else {
            return false
        }

        removeFromFolder(draggedAppID)
        return true
    }
}

private struct FolderMemberDropDelegate: DropDelegate {
    let targetAppID: String
    @Binding var draggedAppID: String?
    @Binding var reorderTargetID: String?
    @Binding var livePlacement: LiveReorderPlacement?
    let move: (_ draggedID: String, _ targetID: String, _ placeAfter: Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggedAppID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let draggedAppID, draggedAppID != targetAppID else {
            reorderTargetID = nil
            return DropProposal(operation: .move)
        }

        // No per-tile highlight: the members parting to make room is the
        // feedback, and writing it every tick would thrash the grid.
        reorderTargetID = nil
        // Reorder live so the other members animate aside.
        requestLiveMove(
            of: draggedAppID,
            onto: targetAppID,
            pointerX: info.location.x,
            livePlacement: &livePlacement,
            move: move
        )
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if reorderTargetID == targetAppID {
            reorderTargetID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedAppID = nil
            reorderTargetID = nil
            livePlacement = nil
        }

        guard let draggedAppID, draggedAppID != targetAppID else {
            return false
        }

        requestLiveMove(
            of: draggedAppID,
            onto: targetAppID,
            pointerX: info.location.x,
            livePlacement: &livePlacement,
            move: move
        )
        return true
    }
}

private struct AppTileDropDelegate: DropDelegate {
    let targetAppID: String
    @Binding var draggedID: String?
    @Binding var folderTargetID: String?
    @Binding var edgeTargetID: String?
    @Binding var livePlacement: LiveReorderPlacement?
    let createFolder: (_ draggedID: String, _ targetID: String) -> Void
    let move: (_ draggedID: String, _ targetID: String, _ placeAfter: Bool) -> Void

    // Folders cannot nest, so dragging a folder over an app only ever
    // reorders; the folder-creation center zone stays inert.
    private var isDraggingFolder: Bool {
        draggedID?.hasPrefix("folder:") == true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // After a live move the dragged item's own tile sits under the
        // pointer; it must not highlight itself as a drop target.
        guard let draggedID, draggedID != targetAppID else {
            folderTargetID = nil
            edgeTargetID = nil
            return DropProposal(operation: .move)
        }

        let isCenter = !isDraggingFolder && isCenterDrop(info.location)
        folderTargetID = isCenter ? targetAppID : nil
        // No edge highlight during reorder: the tiles parting to make room is
        // the feedback, and setting this every tick would thrash the grid.
        edgeTargetID = nil

        // Hovering an edge zone reorders live so the following tiles animate
        // aside, Launchpad-style.
        if !isCenter {
            requestLiveMove(
                of: draggedID,
                onto: targetAppID,
                pointerX: info.location.x,
                livePlacement: &livePlacement,
                move: move
            )
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if folderTargetID == targetAppID {
            folderTargetID = nil
        }
        if edgeTargetID == targetAppID {
            edgeTargetID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID, draggedID != targetAppID else {
            clearState()
            return false
        }

        if !isDraggingFolder && isCenterDrop(info.location) {
            createFolder(draggedID, targetAppID)
        } else {
            requestLiveMove(
                of: draggedID,
                onto: targetAppID,
                pointerX: info.location.x,
                livePlacement: &livePlacement,
                move: move
            )
        }

        clearState()
        return true
    }

    private func clearState() {
        draggedID = nil
        folderTargetID = nil
        edgeTargetID = nil
        livePlacement = nil
    }

    private func isCenterDrop(_ location: CGPoint) -> Bool {
        location.x > 24
            && location.x < 74
            && location.y > 15
            && location.y < 82
    }
}

private struct FolderTileDropDelegate: DropDelegate {
    let folderID: String
    @Binding var draggedID: String?
    @Binding var folderTargetID: String?
    @Binding var edgeTargetID: String?
    @Binding var livePlacement: LiveReorderPlacement?
    let addToFolder: (_ appID: String, _ folderID: String) -> Void
    let move: (_ draggedID: String, _ targetID: String, _ placeAfter: Bool) -> Void

    private var isDraggingFolder: Bool {
        draggedID?.hasPrefix("folder:") == true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let draggedID, draggedID != folderID else {
            folderTargetID = nil
            edgeTargetID = nil
            return DropProposal(operation: .move)
        }

        // Center drop of an app joins the folder; edges (or any folder drag)
        // reorder relative to this folder's slot, moving live so the grid
        // parts to make room.
        let isCenter = !isDraggingFolder && isCenterDrop(info.location)
        folderTargetID = isCenter ? folderID : nil
        edgeTargetID = nil

        if !isCenter {
            requestLiveMove(
                of: draggedID,
                onto: folderID,
                pointerX: info.location.x,
                livePlacement: &livePlacement,
                move: move
            )
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if folderTargetID == folderID {
            folderTargetID = nil
        }
        if edgeTargetID == folderID {
            edgeTargetID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID, draggedID != folderID else {
            clearState()
            return false
        }

        if !isDraggingFolder && isCenterDrop(info.location) {
            addToFolder(draggedID, folderID)
        } else {
            requestLiveMove(
                of: draggedID,
                onto: folderID,
                pointerX: info.location.x,
                livePlacement: &livePlacement,
                move: move
            )
        }

        clearState()
        return true
    }

    private func clearState() {
        draggedID = nil
        folderTargetID = nil
        edgeTargetID = nil
        livePlacement = nil
    }

    private func isCenterDrop(_ location: CGPoint) -> Bool {
        location.x > 24
            && location.x < 74
            && location.y > 15
            && location.y < 82
    }
}

/// Shared hysteresis for live reordering. The first hover over a target
/// decides before/after by the tile midline; after that, the same target
/// only flips once the pointer crosses well past the opposite threshold.
/// Anything inside the dead band issues no model call at all, which keeps
/// the continuous dropUpdated stream free and the animation uninterrupted.
private func requestLiveMove(
    of draggedID: String,
    onto targetID: String,
    pointerX: CGFloat,
    livePlacement: inout LiveReorderPlacement?,
    move: (_ draggedID: String, _ targetID: String, _ placeAfter: Bool) -> Void
) {
    let flipToBeforeThreshold: CGFloat = 36
    let flipToAfterThreshold: CGFloat = 62

    let placeAfter: Bool
    if let placement = livePlacement,
       placement.draggedID == draggedID,
       placement.targetID == targetID {
        if placement.placeAfter {
            guard pointerX < flipToBeforeThreshold else { return }
            placeAfter = false
        } else {
            guard pointerX > flipToAfterThreshold else { return }
            placeAfter = true
        }
    } else {
        placeAfter = pointerX >= 49
    }

    livePlacement = LiveReorderPlacement(
        draggedID: draggedID,
        targetID: targetID,
        placeAfter: placeAfter
    )
    move(draggedID, targetID, placeAfter)
}

/// Catches drops that land on the grid's blank space (including the area
/// after the last tile) and moves the dragged item to the end.
private struct LauncherBlankAreaDropDelegate: DropDelegate {
    @Binding var draggedID: String?
    let canReorder: Bool
    let moveToEnd: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: canReorder && draggedID != nil ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard canReorder, let draggedID else { return false }

        self.draggedID = nil
        moveToEnd(draggedID)
        return true
    }
}

/// A drag-hover strip along the pager's edge: dwelling on it while dragging
/// flips to the previous/next page so the item can be dropped there.
private struct LauncherEdgePagingZone: View {
    let symbol: String
    let isAvailable: Bool
    let onPage: () -> Void

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(isTargeted && isAvailable ? 0.18 : 0),
                    .clear
                ],
                startPoint: symbol.contains("left") ? .leading : .trailing,
                endPoint: symbol.contains("left") ? .trailing : .leading
            )

            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(
                    isTargeted && isAvailable ? Color.accentColor : .secondary
                )
                .opacity(isAvailable ? 1 : 0.25)
        }
        .frame(width: 34)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.text], isTargeted: $isTargeted) { _ in
            // Releasing here isn't a meaningful drop; the zone only flips
            // pages while hovered.
            false
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .task(id: isTargeted) {
            guard isTargeted, isAvailable else { return }

            try? await Task.sleep(for: .milliseconds(320))
            while !Task.isCancelled {
                onPage()
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
            }
        }
    }
}
