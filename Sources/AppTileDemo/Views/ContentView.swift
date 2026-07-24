import SwiftUI

enum LibraryFilter: Hashable {
    case all
    case favorites
    case folders
    case category(String)
    case shortcutSettings
    case launcherSettings
    case generalSettings
    case toolboxSettings
}

private struct CategoryEditorRequest: Identifiable {
    let category: AppCategory?

    var id: String {
        category?.id ?? "new-category"
    }
}

struct ContentView: View {
    @EnvironmentObject private var library: AppLibrary
    @State private var selection: LibraryFilter? = .all
    @State private var searchText = ""
    @State private var categoryEditor: CategoryEditorRequest?
    @State private var categoryPendingDeletion: AppCategory?

    private var activeFilter: LibraryFilter {
        selection ?? .all
    }

    private var activeTitle: String {
        switch activeFilter {
        case .all:
            "全部应用"
        case .favorites:
            "我的收藏"
        case .folders:
            "文件夹"
        case let .category(categoryID):
            library.category(withID: categoryID)?.name ?? "应用分类"
        case .shortcutSettings:
            "快捷键"
        case .launcherSettings:
            "浏览方式"
        case .generalSettings:
            "通用"
        case .toolboxSettings:
            "小工具"
        }
    }

    private var isShowingSettings: Bool {
        switch activeFilter {
        case .shortcutSettings, .launcherSettings, .generalSettings, .toolboxSettings, .folders:
            true
        default:
            false
        }
    }

    private var displayedApps: [AppItem] {
        library.orderedApps(library.apps.filter { app in
            let matchesFilter: Bool
            switch activeFilter {
            case .all:
                matchesFilter = true
            case .favorites:
                matchesFilter = library.isFavorite(app)
            case let .category(categoryID):
                matchesFilter = library.category(for: app).id == categoryID
            case .folders, .shortcutSettings, .launcherSettings, .generalSettings,
                 .toolboxSettings:
                matchesFilter = false
            }

            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }

            return app.name.localizedCaseInsensitiveContains(searchText)
                || (app.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) ?? false)
                || library.category(for: app).rawValue.localizedCaseInsensitiveContains(searchText)
        })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            if activeFilter == .shortcutSettings {
                ShortcutSettingsView()
            } else if activeFilter == .launcherSettings {
                LauncherSettingsView()
            } else if activeFilter == .generalSettings {
                GeneralSettingsView()
            } else if activeFilter == .toolboxSettings {
                ToolboxSettingsView()
            } else if activeFilter == .folders {
                FolderManagerView()
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    appGrid
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .searchable(
                    text: $searchText,
                    placement: .toolbar,
                    prompt: "搜索应用、分类或 Bundle ID"
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            if !isShowingSettings {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        library.refresh()
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                    .disabled(library.isLoading)
                }
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { library.lastError != nil },
                set: { if !$0 { library.lastError = nil } }
            )
        ) {
            Button("好", role: .cancel) {
                library.lastError = nil
            }
        } message: {
            Text(library.lastError ?? "未知错误")
        }
        .alert(
            "删除自定义分类？",
            isPresented: Binding(
                get: { categoryPendingDeletion != nil },
                set: { if !$0 { categoryPendingDeletion = nil } }
            ),
            presenting: categoryPendingDeletion
        ) { category in
            Button("删除", role: .destructive) {
                if selection == .category(category.id) {
                    selection = .all
                }
                library.deleteCustomCategory(category.id)
                categoryPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                categoryPendingDeletion = nil
            }
        } message: { category in
            Text("“\(category.name)”中的应用将恢复为自动分类。")
        }
        .sheet(item: $categoryEditor) { request in
            CategoryEditorSheet(
                category: request.category,
                existingCategories: library.categories
            ) { name, symbol, tintChoice in
                if let category = request.category {
                    if let updatedCategory = library.updateCustomCategory(
                        category.id,
                        name: name,
                        symbol: symbol,
                        tintChoice: tintChoice
                    ) {
                        selection = .category(updatedCategory.id)
                    }
                } else if let newCategory = library.createCustomCategory(
                    name: name,
                    symbol: symbol,
                    tintChoice: tintChoice
                ) {
                    selection = .category(newCategory.id)
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                sidebarRow(
                    title: "全部应用",
                    symbol: "square.grid.2x2",
                    count: library.apps.count
                )
                .tag(LibraryFilter.all)

                sidebarRow(
                    title: "我的收藏",
                    symbol: "star",
                    count: library.apps.filter(library.isFavorite).count
                )
                .tag(LibraryFilter.favorites)

                sidebarRow(
                    title: "文件夹",
                    symbol: "folder",
                    count: library.folders.count
                )
                .tag(LibraryFilter.folders)
            }

            Section {
                ForEach(library.categories) { category in
                    sidebarRow(
                        title: category.name,
                        symbol: category.symbol,
                        count: library.apps.filter {
                            library.category(for: $0) == category
                        }.count,
                        tint: category.tint
                    )
                    .tag(LibraryFilter.category(category.id))
                    .contextMenu {
                        if category.isCustom {
                            Button {
                                categoryEditor = CategoryEditorRequest(category: category)
                            } label: {
                                Label("编辑分类", systemImage: "pencil")
                            }

                            Divider()

                            Button(role: .destructive) {
                                categoryPendingDeletion = category
                            } label: {
                                Label("删除分类", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("应用分类")
                    Spacer()
                    Button {
                        categoryEditor = CategoryEditorRequest(category: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("新建分类")
                    .accessibilityLabel("新建分类")
                }
            }

            Section("设置") {
                Label("通用", systemImage: "gearshape")
                    .tag(LibraryFilter.generalSettings)

                Label("小工具", systemImage: "wrench.and.screwdriver")
                    .tag(LibraryFilter.toolboxSettings)

                Label("快捷键", systemImage: "keyboard")
                    .tag(LibraryFilter.shortcutSettings)

                Label("浏览方式", systemImage: "rectangle.on.rectangle")
                    .tag(LibraryFilter.launcherSettings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("应用磁贴")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                Text("读取本机已安装应用")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(activeTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if library.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("正在扫描…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var headerSubtitle: String {
        if searchText.isEmpty {
            "共 \(displayedApps.count) 个应用，点击磁贴即可启动"
        } else {
            "找到 \(displayedApps.count) 个匹配结果"
        }
    }

    @ViewBuilder
    private var appGrid: some View {
        if displayedApps.isEmpty && !library.isLoading {
            ContentUnavailableView(
                searchText.isEmpty ? "这里还没有应用" : "没有搜索结果",
                systemImage: searchText.isEmpty ? "square.grid.2x2" : "magnifyingglass",
                description: Text(
                    searchText.isEmpty
                        ? "可以切换分类，或点击工具栏中的刷新按钮重新扫描。"
                        : "尝试更换应用名称、分类或 Bundle ID。"
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 156, maximum: 210), spacing: 16)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(displayedApps) { app in
                        AppTileView(app: app)
                    }
                }
                .padding(24)
            }
        }
    }

    private func sidebarRow(
        title: String,
        symbol: String,
        count: Int,
        tint: Color = .accentColor
    ) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
            }
            Spacer()
            Text(count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct CategoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let category: AppCategory?
    let existingCategories: [AppCategory]
    let onSave: (String, String, AppCategoryTint) -> Void

    @State private var name: String
    @State private var selectedSymbol: String
    @State private var selectedTint: AppCategoryTint

    init(
        category: AppCategory?,
        existingCategories: [AppCategory],
        onSave: @escaping (String, String, AppCategoryTint) -> Void
    ) {
        self.category = category
        self.existingCategories = existingCategories
        self.onSave = onSave
        _name = State(initialValue: category?.name ?? "")
        _selectedSymbol = State(initialValue: category?.symbol ?? AppCategory.defaultSymbols[0])
        _selectedTint = State(initialValue: category?.tintChoice ?? .blue)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasDuplicateName: Bool {
        existingCategories.contains { existingCategory in
            existingCategory.id != category?.id
                && existingCategory.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !hasDuplicateName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(category == nil ? "新建分类" : "编辑分类")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("分类名称")
                    .font(.headline)
                TextField("例如：工作应用", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)

                if hasDuplicateName {
                    Text("已存在同名分类，请使用其他名称。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("选择图标")
                        .font(.headline)
                    Spacer()
                    Label(trimmedName.isEmpty ? "分类预览" : trimmedName, systemImage: selectedSymbol)
                        .foregroundStyle(selectedTint.color)
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 8),
                    spacing: 10
                ) {
                    ForEach(AppCategory.defaultSymbols, id: \.self) { symbol in
                        Button {
                            selectedSymbol = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 38, height: 38)
                                .foregroundStyle(selectedSymbol == symbol ? Color.white : Color.primary)
                                .background {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(
                                            selectedSymbol == symbol
                                                ? selectedTint.color
                                                : Color(nsColor: .controlBackgroundColor)
                                        )
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(
                                            selectedSymbol == symbol
                                                ? selectedTint.color
                                                : Color.secondary.opacity(0.2),
                                            lineWidth: 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                        .accessibilityLabel("选择图标 \(symbol)")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("选择颜色")
                    .font(.headline)

                HStack(spacing: 10) {
                    ForEach(AppCategoryTint.allCases) { tintChoice in
                        Button {
                            selectedTint = tintChoice
                        } label: {
                            Circle()
                                .fill(tintChoice.color)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Circle()
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                }
                                .overlay {
                                    if selectedTint == tintChoice {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .padding(3)
                                .overlay {
                                    Circle()
                                        .stroke(
                                            selectedTint == tintChoice
                                                ? tintChoice.color
                                                : Color.clear,
                                            lineWidth: 2
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .help(tintChoice.name)
                        .accessibilityLabel("选择\(tintChoice.name)")
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(category == nil ? "创建" : "保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 480, height: 480)
    }

    private func save() {
        guard canSave else { return }
        onSave(trimmedName, selectedSymbol, selectedTint)
        dismiss()
    }
}
