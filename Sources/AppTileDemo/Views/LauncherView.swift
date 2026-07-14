import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    private let columnCount = 7

    @EnvironmentObject private var library: AppLibrary
    @FocusState private var searchIsFocused: Bool

    @State private var searchText = ""
    @State private var selectedID: LauncherItem.ID?
    @State private var draggedID: AppItem.ID?
    @State private var folderDropTargetID: String?
    @State private var edgeDropTargetID: String?
    @State private var openFolderID: String?

    let onDismiss: () -> Void
    let onOpenManager: () -> Void

    private var items: [LauncherItem] {
        guard !searchText.isEmpty else {
            return library.launcherItems()
        }

        let matchingApps = library.apps.filter { app in
            app.name.localizedCaseInsensitiveContains(searchText)
                || (app.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) ?? false)
                || library.category(for: app).rawValue.localizedCaseInsensitiveContains(searchText)
        }

        return library.orderedApps(matchingApps).map(LauncherItem.app)
    }

    private var itemIDs: [LauncherItem.ID] {
        items.map(\.id)
    }

    private var selectedItem: LauncherItem? {
        guard let selectedID else { return items.first }
        return items.first { $0.id == selectedID }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                searchHeader
                Divider().opacity(0.7)
                resultContent
                Divider().opacity(0.7)
                footer
            }

            if let openFolderID,
               let folder = library.folder(withID: openFolderID) {
                FolderOverlay(
                    folder: folder,
                    apps: library.apps(in: folder),
                    onRename: { name in
                        library.renameFolder(folder.id, to: name)
                    },
                    onLaunch: launch,
                    onClose: {
                        closeFolder()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: 760, height: 560)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 30, y: 16)
        .onAppear {
            selectedID = items.first?.id
            DispatchQueue.main.async {
                searchIsFocused = true
            }
        }
        .onChange(of: itemIDs) { _, newIDs in
            if let selectedID, newIDs.contains(selectedID) {
                return
            }
            selectedID = newIDs.first
        }
        .onChange(of: searchText) {
            openFolderID = nil
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

    private var searchHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索应用…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .focused($searchIsFocused)
                .onSubmit {
                    activateSelectedItem()
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(minimum: 78), spacing: 8),
                            count: columnCount
                        ),
                        spacing: 8
                    ) {
                        ForEach(items) { item in
                            launcherItemView(item)
                                .id(item.id)
                        }
                    }
                    .padding(12)
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
            .onDrag {
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
                        library.moveApp(
                            draggedID,
                            relativeTo: targetID,
                            placeAfter: placeAfter
                        )
                    }
                )
            )

        case let .folder(folder, apps):
            LauncherFolderTile(
                folder: folder,
                apps: apps,
                isSelected: selectedID == folder.id,
                isDropTarget: folderDropTargetID == folder.id,
                onOpen: {
                    selectedID = folder.id
                    openFolder(folder.id)
                }
            )
            .onDrop(
                of: [UTType.text],
                delegate: FolderTileDropDelegate(
                    folderID: folder.id,
                    draggedID: $draggedID,
                    folderTargetID: $folderDropTargetID,
                    addToFolder: { appID, folderID in
                        library.addApp(appID, toFolder: folderID)
                        selectedID = folderID
                    }
                )
            )
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

            Text("拖到图标中央可创建文件夹")
                .foregroundStyle(.tertiary)

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

    private func keyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced().weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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

    private func openFolder(_ folderID: String) {
        searchIsFocused = false
        withAnimation(.easeOut(duration: 0.16)) {
            openFolderID = folderID
        }
    }

    private func closeFolder() {
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
                Image(nsImage: AppIconCache.shared.icon(for: app.url))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
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
        if isSelected {
            return Color.accentColor.opacity(0.17)
        }
        if isEdgeTarget || isHovering {
            return Color.white.opacity(0.07)
        }
        return .clear
    }

    private var tileBorder: Color {
        if isFolderTarget {
            return Color.accentColor.opacity(0.9)
        }
        if isSelected {
            return Color.accentColor.opacity(0.52)
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
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 6) {
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(22), spacing: 3),
                        GridItem(.fixed(22), spacing: 3)
                    ],
                    spacing: 3
                ) {
                    ForEach(Array(apps.prefix(4))) { app in
                        Image(nsImage: AppIconCache.shared.icon(for: app.url))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 22, height: 22)
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
                            : Color.white.opacity(isHovering ? 0.07 : 0)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(
                        isDropTarget
                            ? Color.accentColor.opacity(0.9)
                            : (isSelected ? Color.accentColor.opacity(0.52) : .clear),
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
}

private struct FolderOverlay: View {
    @FocusState private var folderNameIsFocused: Bool
    @State private var folderName: String
    @State private var isEditingName = false

    let folder: AppFolder
    let apps: [AppItem]
    let onRename: (String) -> Void
    let onLaunch: (AppItem) -> Void
    let onClose: () -> Void

    init(
        folder: AppFolder,
        apps: [AppItem],
        onRename: @escaping (String) -> Void,
        onLaunch: @escaping (AppItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.folder = folder
        self.apps = apps
        self.onRename = onRename
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

                    HStack {
                        Spacer()
                        Button(action: close) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 30)

                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(minimum: 72), spacing: 12),
                            count: 5
                        ),
                        spacing: 12
                    ) {
                        ForEach(apps) { app in
                            Button {
                                onLaunch(app)
                            } label: {
                                VStack(spacing: 7) {
                                    Image(nsImage: AppIconCache.shared.icon(for: app.url))
                                        .resizable()
                                        .interpolation(.high)
                                        .frame(width: 48, height: 48)
                                    Text(app.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 82)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(22)
            .frame(width: 570, height: 350)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        }
        .onChange(of: folderNameIsFocused) { _, isFocused in
            if !isFocused && isEditingName {
                finishEditingName()
            }
        }
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
    }
}

private struct AppTileDropDelegate: DropDelegate {
    let targetAppID: String
    @Binding var draggedID: String?
    @Binding var folderTargetID: String?
    @Binding var edgeTargetID: String?
    let createFolder: (_ draggedID: String, _ targetID: String) -> Void
    let move: (_ draggedID: String, _ targetID: String, _ placeAfter: Bool) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let isCenter = isCenterDrop(info.location)

        folderTargetID = isCenter ? targetAppID : nil
        edgeTargetID = isCenter ? nil : targetAppID
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

        if isCenterDrop(info.location) {
            createFolder(draggedID, targetAppID)
        } else {
            move(draggedID, targetAppID, info.location.x >= 49)
        }

        clearState()
        return true
    }

    private func clearState() {
        draggedID = nil
        folderTargetID = nil
        edgeTargetID = nil
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
    let addToFolder: (_ appID: String, _ folderID: String) -> Void

    func dropEntered(info: DropInfo) {
        folderTargetID = folderID
    }

    func dropExited(info: DropInfo) {
        if folderTargetID == folderID {
            folderTargetID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID else { return false }
        addToFolder(draggedID, folderID)
        self.draggedID = nil
        folderTargetID = nil
        return true
    }
}
