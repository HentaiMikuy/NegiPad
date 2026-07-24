import SwiftUI

/// Settings page that manages keyword → apps bindings: create a keyword
/// like "数据库", bind any apps to it, and the launcher search surfaces
/// those apps whenever the query matches the keyword (exact, fuzzy, or via
/// pinyin), regardless of app names and categories.
struct KeywordSettingsView: View {
    @EnvironmentObject private var library: AppLibrary

    @State private var keywordEditor: KeywordEditorRequest?
    @State private var groupPendingDeletion: SearchKeywordGroup?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("搜索关键字")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("为一组应用绑定统一的关键字，在启动器中输入关键字即可直接找到它们，无需依赖应用名称或分类。支持拼音、首字母与模糊匹配。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button {
                        keywordEditor = KeywordEditorRequest(group: nil)
                    } label: {
                        Label("添加关键字", systemImage: "plus")
                    }

                    Spacer()

                    if !library.keywordGroups.isEmpty {
                        Text("共 \(library.keywordGroups.count) 个关键字")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if library.keywordGroups.isEmpty {
                    GroupBox {
                        VStack(spacing: 10) {
                            Image(systemName: "text.magnifyingglass")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("还没有关键字")
                                .font(.headline)
                            Text("例如：创建“数据库”并绑定几个数据库客户端，之后在启动器中输入“数据库”“shujuku”或“sjk”都能直接找到它们。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }
                } else {
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(Array(library.keywordGroups.enumerated()), id: \.element.id) {
                                index, group in
                                keywordRow(group)

                                if index < library.keywordGroups.count - 1 {
                                    Divider()
                                        .padding(.leading, 10)
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $keywordEditor) { request in
            KeywordGroupEditorSheet(group: request.group)
        }
        .alert(
            "删除关键字？",
            isPresented: Binding(
                get: { groupPendingDeletion != nil },
                set: { if !$0 { groupPendingDeletion = nil } }
            ),
            presenting: groupPendingDeletion
        ) { group in
            Button("删除", role: .destructive) {
                library.deleteKeywordGroup(group.id)
                groupPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                groupPendingDeletion = nil
            }
        } message: { group in
            Text("删除“\(group.keyword)”后，搜索该关键字将不再显示绑定的应用，绑定的应用本身不受影响。")
        }
    }

    private func keywordRow(_ group: SearchKeywordGroup) -> some View {
        let boundApps = group.appIDs.compactMap(library.app(withID:))

        return HStack(spacing: 14) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(group.keyword)
                    .font(.headline)

                if boundApps.isEmpty {
                    Text("未绑定应用，编辑后才会出现在搜索结果中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(boundApps.prefix(8)) { app in
                            AppIconView(app: app, size: 20)
                                .help(app.name)
                        }
                        Text(
                            boundApps.count > 8
                                ? "等 \(boundApps.count) 个应用"
                                : boundApps.map(\.name).joined(separator: "、")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            }

            Spacer()

            Button("编辑") {
                keywordEditor = KeywordEditorRequest(group: group)
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                groupPendingDeletion = group
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除关键字")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                keywordEditor = KeywordEditorRequest(group: group)
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                groupPendingDeletion = group
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

private struct KeywordEditorRequest: Identifiable {
    let group: SearchKeywordGroup?

    var id: String {
        group?.id ?? "new-keyword"
    }
}

private struct KeywordGroupEditorSheet: View {
    @EnvironmentObject private var library: AppLibrary
    @Environment(\.dismiss) private var dismiss

    let group: SearchKeywordGroup?

    @State private var keyword: String
    @State private var selectedAppIDs: Set<String>
    @State private var filterText = ""

    init(group: SearchKeywordGroup?) {
        self.group = group
        _keyword = State(initialValue: group?.keyword ?? "")
        _selectedAppIDs = State(initialValue: Set(group?.appIDs ?? []))
    }

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasDuplicateKeyword: Bool {
        !trimmedKeyword.isEmpty
            && !library.isKeywordAvailable(trimmedKeyword, excluding: group?.id)
    }

    private var canSave: Bool {
        !trimmedKeyword.isEmpty && !hasDuplicateKeyword && !selectedAppIDs.isEmpty
    }

    /// The pick list reuses the launcher's match ladder, so the filter box
    /// understands pinyin and fuzzy input just like the real search will.
    private var filteredApps: [AppItem] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.apps }

        let queryKey = AppSearchEngine.normalize(query)
        return library.apps
            .compactMap { app -> (app: AppItem, score: Double)? in
                let score = AppSearchEngine.matchScore(
                    normalizedQuery: queryKey,
                    appName: app.name,
                    pinyinName: app.pinyinName,
                    pinyinInitials: app.pinyinInitials,
                    aliases: library.aliases(for: app.id),
                    bundleIdentifier: app.bundleIdentifier,
                    categoryName: library.category(for: app).rawValue
                )
                return score.map { (app, $0) }
            }
            .sorted { $0.score > $1.score }
            .map(\.app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(group == nil ? "新建关键字" : "编辑关键字")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("关键字")
                    .font(.headline)
                TextField("例如：数据库", text: $keyword)
                    .textFieldStyle(.roundedBorder)

                if hasDuplicateKeyword {
                    Text("已存在同名关键字，请使用其他名称。")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("搜索时输入该关键字（含拼音、首字母或模糊输入）即可显示绑定的应用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("绑定应用")
                        .font(.headline)
                    Spacer()
                    Text("已选 \(selectedAppIDs.count) 个")
                        .font(.caption)
                        .foregroundStyle(selectedAppIDs.isEmpty ? .red : .secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("过滤应用（支持拼音与模糊输入）", text: $filterText)
                        .textFieldStyle(.plain)
                    if !filterText.isEmpty {
                        Button {
                            filterText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                }

                appPickList
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(group == nil ? "创建" : "保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 520, height: 620)
    }

    @ViewBuilder
    private var appPickList: some View {
        if filteredApps.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
                Text("没有匹配的应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredApps) { app in
                        appPickRow(app)
                        Divider()
                            .padding(.leading, 46)
                    }
                }
            }
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
        }
    }

    private func appPickRow(_ app: AppItem) -> some View {
        let isSelected = selectedAppIDs.contains(app.id)

        return Button {
            if isSelected {
                selectedAppIDs.remove(app.id)
            } else {
                selectedAppIDs.insert(app.id)
            }
        } label: {
            HStack(spacing: 10) {
                AppIconView(app: app, size: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .foregroundStyle(.primary)
                    if let bundleIdentifier = app.bundleIdentifier {
                        Text(bundleIdentifier)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.45)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        guard canSave else { return }

        // Persist in the scanner's (name-sorted) order so the row preview
        // stays stable no matter the order apps were ticked in.
        let orderedAppIDs = library.apps
            .filter { selectedAppIDs.contains($0.id) }
            .map(\.id)

        if let group {
            library.updateKeywordGroup(group.id, keyword: trimmedKeyword, appIDs: orderedAppIDs)
        } else {
            library.createKeywordGroup(keyword: trimmedKeyword, appIDs: orderedAppIDs)
        }
        dismiss()
    }
}
