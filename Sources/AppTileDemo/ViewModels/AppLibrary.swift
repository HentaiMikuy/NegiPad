import AppKit
import Combine
import Foundation

@MainActor
final class AppLibrary: ObservableObject {
    @Published private(set) var apps: [AppItem] = []
    @Published private(set) var favoriteIDs = Set<String>()
    @Published private(set) var categoryOverrides: [String: AppCategory] = [:]
    @Published private(set) var appOrder: [String] = []
    @Published private(set) var folders: [AppFolder] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let preferencesKey = "AppTileDemo.Preferences"

    init() {
        loadPreferences()
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AppScanner.scan()
            }.value

            let previousOrder = appOrder
            let previousFolders = folders
            apps = result
            reconcileOrder(with: result)
            reconcileFolders(with: result)
            if appOrder != previousOrder || folders != previousFolders {
                savePreferences()
            }
            isLoading = false
        }
    }

    func category(for app: AppItem) -> AppCategory {
        categoryOverrides[app.id] ?? app.automaticCategory
    }

    func isFavorite(_ app: AppItem) -> Bool {
        favoriteIDs.contains(app.id)
    }

    func toggleFavorite(_ app: AppItem) {
        if favoriteIDs.contains(app.id) {
            favoriteIDs.remove(app.id)
        } else {
            favoriteIDs.insert(app.id)
        }
        savePreferences()
    }

    func setCategory(_ category: AppCategory?, for app: AppItem) {
        categoryOverrides[app.id] = category
        savePreferences()
    }

    func orderedApps(_ source: [AppItem]) -> [AppItem] {
        var orderIndex: [String: Int] = [:]
        for (index, id) in appOrder.enumerated() where orderIndex[id] == nil {
            orderIndex[id] = index
        }

        return source.sorted { lhs, rhs in
            let lhsIndex = orderIndex[lhs.id] ?? Int.max
            let rhsIndex = orderIndex[rhs.id] ?? Int.max

            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func launcherItems() -> [LauncherItem] {
        let ordered = orderedApps(apps)
        let appsByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        var folderByAppID: [String: AppFolder] = [:]

        for folder in folders {
            for appID in folder.appIDs {
                folderByAppID[appID] = folder
            }
        }

        var emittedFolderIDs = Set<String>()
        var items: [LauncherItem] = []

        for app in ordered {
            guard let folder = folderByAppID[app.id] else {
                items.append(.app(app))
                continue
            }

            guard emittedFolderIDs.insert(folder.id).inserted else { continue }
            let members = folder.appIDs.compactMap { appsByID[$0] }
            items.append(.folder(folder, members))
        }

        return items
    }

    func folder(withID id: String) -> AppFolder? {
        folders.first { $0.id == id }
    }

    func apps(in folder: AppFolder) -> [AppItem] {
        let appsByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        return folder.appIDs.compactMap { appsByID[$0] }
    }

    @discardableResult
    func createFolder(containing draggedID: String, and targetID: String) -> String? {
        guard draggedID != targetID,
              let draggedApp = apps.first(where: { $0.id == draggedID }),
              let targetApp = apps.first(where: { $0.id == targetID }) else {
            return nil
        }

        let draggedFolderIndex = folders.firstIndex { $0.appIDs.contains(draggedID) }
        let targetFolderIndex = folders.firstIndex { $0.appIDs.contains(targetID) }

        if let targetFolderIndex {
            let folderID = folders[targetFolderIndex].id
            addApp(draggedID, toFolder: folderID)
            return folderID
        }

        if let draggedFolderIndex {
            let folderID = folders[draggedFolderIndex].id
            addApp(targetID, toFolder: folderID)
            return folderID
        }

        moveApp(draggedID, relativeTo: targetID, placeAfter: true, save: false)
        let orderedIDs = [draggedID, targetID].sorted(by: comesBeforeInAppOrder)
        let category = category(for: draggedApp) == category(for: targetApp)
            ? category(for: targetApp).rawValue
            : "应用文件夹"
        let folder = AppFolder(name: category, appIDs: orderedIDs)

        folders.append(folder)
        savePreferences()
        return folder.id
    }

    func addApp(_ appID: String, toFolder folderID: String) {
        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }),
              !folders[folderIndex].appIDs.contains(appID) else {
            return
        }

        if let sourceFolderIndex = folders.firstIndex(where: { $0.appIDs.contains(appID) }) {
            folders[sourceFolderIndex].appIDs.removeAll { $0 == appID }
            if folders[sourceFolderIndex].appIDs.count < 2 {
                folders.remove(at: sourceFolderIndex)
            }
        }

        guard let updatedFolderIndex = folders.firstIndex(where: { $0.id == folderID }) else {
            return
        }

        if let lastMemberID = folders[updatedFolderIndex].appIDs.last {
            moveApp(appID, relativeTo: lastMemberID, placeAfter: true, save: false)
        }

        folders[updatedFolderIndex].appIDs.append(appID)
        folders[updatedFolderIndex].appIDs.sort(by: comesBeforeInAppOrder)
        savePreferences()
    }

    func renameFolder(_ folderID: String, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[index].name = trimmedName.isEmpty ? "应用文件夹" : trimmedName
        savePreferences()
    }

    func moveApp(
        _ draggedID: String,
        relativeTo targetID: String,
        placeAfter: Bool
    ) {
        moveApp(
            draggedID,
            relativeTo: targetID,
            placeAfter: placeAfter,
            save: true
        )
    }

    private func moveApp(
        _ draggedID: String,
        relativeTo targetID: String,
        placeAfter: Bool,
        save: Bool
    ) {
        guard draggedID != targetID else { return }

        reconcileOrder(with: apps)
        guard let sourceIndex = appOrder.firstIndex(of: draggedID) else { return }

        var newOrder = appOrder
        let movedID = newOrder.remove(at: sourceIndex)
        guard let targetIndex = newOrder.firstIndex(of: targetID) else { return }

        let insertionIndex = min(
            placeAfter ? targetIndex + 1 : targetIndex,
            newOrder.count
        )
        newOrder.insert(movedID, at: insertionIndex)

        appOrder = newOrder
        if save {
            savePreferences()
        }
    }

    func launch(_ app: AppItem) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(
            at: app.url,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastError = "无法打开 \(app.name)：\(error.localizedDescription)"
            }
        }
    }

    func revealInFinder(_ app: AppItem) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    private func loadPreferences() {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey),
              let preferences = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return
        }

        favoriteIDs = preferences.favoriteIDs
        categoryOverrides = preferences.categoryOverrides
        appOrder = preferences.appOrder ?? []
        folders = preferences.folders ?? []
    }

    private func savePreferences() {
        let preferences = Preferences(
            favoriteIDs: favoriteIDs,
            categoryOverrides: categoryOverrides,
            appOrder: appOrder,
            folders: folders
        )
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: preferencesKey)
    }

    private func reconcileOrder(with applications: [AppItem]) {
        let validIDs = Set(applications.map(\.id))
        var seenIDs = Set<String>()
        var reconciledOrder = appOrder.filter { id in
            validIDs.contains(id) && seenIDs.insert(id).inserted
        }

        for app in applications where seenIDs.insert(app.id).inserted {
            reconciledOrder.append(app.id)
        }

        appOrder = reconciledOrder
    }

    private func reconcileFolders(with applications: [AppItem]) {
        let validIDs = Set(applications.map(\.id))
        var assignedIDs = Set<String>()

        folders = folders.compactMap { folder in
            var updatedFolder = folder
            updatedFolder.appIDs = folder.appIDs.filter { id in
                validIDs.contains(id) && assignedIDs.insert(id).inserted
            }
            updatedFolder.appIDs.sort(by: comesBeforeInAppOrder)
            return updatedFolder.appIDs.count >= 2 ? updatedFolder : nil
        }
    }

    private func comesBeforeInAppOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lhsIndex = appOrder.firstIndex(of: lhs) ?? Int.max
        let rhsIndex = appOrder.firstIndex(of: rhs) ?? Int.max
        return lhsIndex < rhsIndex
    }
}

private struct Preferences: Codable {
    let favoriteIDs: Set<String>
    let categoryOverrides: [String: AppCategory]
    let appOrder: [String]?
    let folders: [AppFolder]?
}
