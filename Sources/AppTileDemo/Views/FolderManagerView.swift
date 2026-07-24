import SwiftUI

struct FolderManagerView: View {
    @EnvironmentObject private var library: AppLibrary

    @State private var selectedFolderID: String?
    @State private var editedName = ""
    @State private var folderPendingDissolve: AppFolder?

    private var selectedFolder: AppFolder? {
        selectedFolderID.flatMap { library.folder(withID: $0) }
    }

    private var trimmedEditedName: String {
        editedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if library.folders.isEmpty {
                ContentUnavailableView(
                    "还没有文件夹",
                    systemImage: "folder.badge.plus",
                    description: Text("在启动器中把一个应用拖到另一个应用的中央即可创建文件夹。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    folderList
                        .frame(width: 280)
                    Divider()
                    folderDetail
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            ensureSelection()
        }
        .onChange(of: library.folders) {
            ensureSelection()
        }
        .onChange(of: selectedFolderID) {
            editedName = selectedFolder?.name ?? ""
        }
        .alert(
            "解散文件夹？",
            isPresented: Binding(
                get: { folderPendingDissolve != nil },
                set: { if !$0 { folderPendingDissolve = nil } }
            ),
            presenting: folderPendingDissolve
        ) { folder in
            Button("解散", role: .destructive) {
                library.dissolveFolder(folder.id)
                folderPendingDissolve = nil
            }
            Button("取消", role: .cancel) {
                folderPendingDissolve = nil
            }
        } message: { folder in
            Text("“\(folder.name)”中的 \(folder.appIDs.count) 个应用将回到启动器顶层，该操作可撤销。")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("文件夹")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("共 \(library.folders.count) 个文件夹，可在此集中重命名、排序与解散")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                library.undoLastOrganize()
            } label: {
                Label("撤销整理", systemImage: "arrow.uturn.backward")
            }
            .disabled(!library.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销上一次整理操作（⌘Z）")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var folderList: some View {
        List(selection: $selectedFolderID) {
            ForEach(library.folders) { folder in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name)
                            .font(.body.weight(.medium))
                        Text("\(folder.appIDs.count) 个应用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(folder.id)
                .contextMenu {
                    Button(role: .destructive) {
                        folderPendingDissolve = folder
                    } label: {
                        Label("解散文件夹", systemImage: "folder.badge.minus")
                    }
                }
            }
            .onMove { source, destination in
                library.moveFolders(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .bottom) {
            Text("拖动可调整文件夹在启动器中的先后顺序")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    @ViewBuilder
    private var folderDetail: some View {
        if let folder = selectedFolder {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("文件夹名称", text: $editedName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .onSubmit {
                            commitRename(folder)
                        }

                    Button("重命名") {
                        commitRename(folder)
                    }
                    .disabled(trimmedEditedName.isEmpty || trimmedEditedName == folder.name)

                    Spacer()

                    Button(role: .destructive) {
                        folderPendingDissolve = folder
                    } label: {
                        Label("解散文件夹", systemImage: "folder.badge.minus")
                    }
                }

                Text("拖动应用调整文件夹内顺序；“移出”会把应用放回启动器顶层。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List {
                    ForEach(library.apps(in: folder)) { app in
                        HStack(spacing: 10) {
                            AppIconView(app: app, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                if let bundleIdentifier = app.bundleIdentifier {
                                    Text(bundleIdentifier)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Spacer()

                            Button("移出") {
                                library.removeApp(app.id, fromFolder: folder.id)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { source, destination in
                        library.moveApps(
                            inFolder: folder.id,
                            fromOffsets: source,
                            toOffset: destination
                        )
                    }
                }
                .listStyle(.inset)
            }
            .padding(20)
        } else {
            ContentUnavailableView(
                "选择一个文件夹",
                systemImage: "folder",
                description: Text("从左侧列表选择要编辑的文件夹。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func ensureSelection() {
        if let selectedFolderID,
           library.folder(withID: selectedFolderID) != nil {
            // Keep the current selection, but refresh the name field in case
            // the folder was renamed elsewhere (e.g. in the launcher).
            if !isEditingName() {
                editedName = selectedFolder?.name ?? editedName
            }
            return
        }
        selectedFolderID = library.folders.first?.id
        editedName = selectedFolder?.name ?? ""
    }

    private func isEditingName() -> Bool {
        guard let folder = selectedFolder else { return false }
        return trimmedEditedName != folder.name && !trimmedEditedName.isEmpty
    }

    private func commitRename(_ folder: AppFolder) {
        guard !trimmedEditedName.isEmpty else {
            editedName = folder.name
            return
        }
        library.renameFolder(folder.id, to: trimmedEditedName)
        editedName = trimmedEditedName
    }
}
