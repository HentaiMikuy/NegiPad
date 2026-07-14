import SwiftUI

enum LibraryFilter: Hashable {
    case all
    case favorites
    case category(AppCategory)

    var title: String {
        switch self {
        case .all: "全部应用"
        case .favorites: "我的收藏"
        case let .category(category): category.rawValue
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var library: AppLibrary
    @State private var selection: LibraryFilter? = .all
    @State private var searchText = ""

    private var activeFilter: LibraryFilter {
        selection ?? .all
    }

    private var displayedApps: [AppItem] {
        library.orderedApps(library.apps.filter { app in
            let matchesFilter: Bool
            switch activeFilter {
            case .all:
                matchesFilter = true
            case .favorites:
                matchesFilter = library.isFavorite(app)
            case let .category(category):
                matchesFilter = library.category(for: app) == category
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
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                appGrid
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索应用、分类或 Bundle ID")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.refresh()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(library.isLoading)
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
            }

            Section("应用分类") {
                ForEach(AppCategory.allCases) { category in
                    sidebarRow(
                        title: category.rawValue,
                        symbol: category.symbol,
                        count: library.apps.filter {
                            library.category(for: $0) == category
                        }.count,
                        tint: category.tint
                    )
                    .tag(LibraryFilter.category(category))
                }
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
                Text(activeFilter.title)
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
