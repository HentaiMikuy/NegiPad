import AppKit
import Combine
import Foundation

@MainActor
final class AppLibrary: ObservableObject {
    @Published private(set) var apps: [AppItem] = []
    @Published private(set) var favoriteIDs = Set<String>()
    @Published private(set) var categoryOverrides: [String: AppCategory] = [:]
    @Published private(set) var customCategories: [AppCategory] = []
    @Published private(set) var appOrder: [String] = []
    @Published private(set) var folders: [AppFolder] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let preferencesKey = "AppTileDemo.Preferences"
    private var appsByID: [String: AppItem] = [:]
    private var orderIndex: [String: Int] = [:]
    private var foldersByID: [String: AppFolder] = [:]
    private var folderByAppID: [String: AppFolder] = [:]
    private var cachedLauncherItems: [LauncherItem] = []
    private var cachedSearchQuery: String?
    private var cachedSearchItems: [LauncherItem] = []

    init() {
        loadPreferences()
        refresh()
    }

    var categories: [AppCategory] {
        AppCategory.builtInCategories + customCategories
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
            rebuildOrderIndex()
            reconcileFolders(with: result)
            rebuildDerivedData()
            if appOrder != previousOrder || folders != previousFolders {
                savePreferences()
            }
            isLoading = false
        }
    }

    func category(for app: AppItem) -> AppCategory {
        guard let override = categoryOverrides[app.id] else {
            return app.automaticCategory
        }
        return category(withID: override.id) ?? app.automaticCategory
    }

    func category(withID id: String) -> AppCategory? {
        categories.first { $0.id == id }
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
        invalidateSearchCache()
        savePreferences()
    }

    func isCategoryNameAvailable(_ name: String, excluding categoryID: String? = nil) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return false }

        return !categories.contains { category in
            category.id != categoryID
                && category.name.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }
    }

    @discardableResult
    func createCustomCategory(name: String, symbol: String) -> AppCategory? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCategoryNameAvailable(trimmedName) else { return nil }

        let category = AppCategory.custom(name: trimmedName, symbol: symbol)
        customCategories.append(category)
        invalidateSearchCache()
        savePreferences()
        return category
    }

    @discardableResult
    func updateCustomCategory(_ categoryID: String, name: String, symbol: String) -> AppCategory? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = customCategories.firstIndex(where: { $0.id == categoryID }),
              isCategoryNameAvailable(trimmedName, excluding: categoryID) else {
            return nil
        }

        let updatedCategory = customCategories[index].updating(
            name: trimmedName,
            symbol: symbol
        )
        customCategories[index] = updatedCategory

        let affectedAppIDs = categoryOverrides.compactMap { appID, category in
            category.id == categoryID ? appID : nil
        }
        for appID in affectedAppIDs {
            categoryOverrides[appID] = updatedCategory
        }

        invalidateSearchCache()
        savePreferences()
        return updatedCategory
    }

    func deleteCustomCategory(_ categoryID: String) {
        guard customCategories.contains(where: { $0.id == categoryID }) else { return }

        customCategories.removeAll { $0.id == categoryID }
        categoryOverrides = categoryOverrides.filter { $0.value.id != categoryID }
        invalidateSearchCache()
        savePreferences()
    }

    func orderedApps(_ source: [AppItem]) -> [AppItem] {
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
        cachedLauncherItems
    }

    func launcherItems(matching query: String) -> [LauncherItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return cachedLauncherItems }

        if cachedSearchQuery == normalizedQuery {
            return cachedSearchItems
        }

        let matchingApps = apps.filter { app in
            app.name.localizedCaseInsensitiveContains(normalizedQuery)
                || (app.bundleIdentifier?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                || category(for: app).rawValue.localizedCaseInsensitiveContains(normalizedQuery)
        }
        let items = orderedApps(matchingApps).map(LauncherItem.app)

        cachedSearchQuery = normalizedQuery
        cachedSearchItems = items
        return items
    }

    func folder(withID id: String) -> AppFolder? {
        foldersByID[id]
    }

    func apps(in folder: AppFolder) -> [AppItem] {
        return folder.appIDs.compactMap { appsByID[$0] }
    }

    @discardableResult
    func createFolder(containing draggedID: String, and targetID: String) -> String? {
        guard draggedID != targetID,
              let draggedApp = appsByID[draggedID],
              let targetApp = appsByID[targetID] else {
            return nil
        }

        let draggedFolderIndex = folderByAppID[draggedID].flatMap { draggedFolder in
            folders.firstIndex { $0.id == draggedFolder.id }
        }
        let targetFolderIndex = folderByAppID[targetID].flatMap { targetFolder in
            folders.firstIndex { $0.id == targetFolder.id }
        }

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
        rebuildDerivedData()
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
        rebuildDerivedData()
        savePreferences()
    }

    @discardableResult
    func removeApp(_ appID: String, fromFolder folderID: String) -> Bool {
        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }),
              folders[folderIndex].appIDs.contains(appID) else {
            return false
        }

        folders[folderIndex].appIDs.removeAll { $0 == appID }
        if folders[folderIndex].appIDs.count < 2 {
            folders.remove(at: folderIndex)
        } else {
            folders[folderIndex].appIDs.sort(by: comesBeforeInAppOrder)
        }

        rebuildDerivedData()
        savePreferences()
        return true
    }

    func renameFolder(_ folderID: String, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[index].name = trimmedName.isEmpty ? "应用文件夹" : trimmedName
        rebuildDerivedData()
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
        rebuildDerivedData()
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
        customCategories = preferences.customCategories ?? []
        appOrder = preferences.appOrder ?? []
        folders = preferences.folders ?? []
        rebuildDerivedData()
    }

    private func savePreferences() {
        let preferences = Preferences(
            favoriteIDs: favoriteIDs,
            categoryOverrides: categoryOverrides,
            customCategories: customCategories,
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
        let lhsIndex = orderIndex[lhs] ?? Int.max
        let rhsIndex = orderIndex[rhs] ?? Int.max
        return lhsIndex < rhsIndex
    }

    private func rebuildDerivedData() {
        rebuildOrderIndex()
        appsByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        folderByAppID.removeAll(keepingCapacity: true)

        for folder in folders {
            for appID in folder.appIDs {
                folderByAppID[appID] = folder
            }
        }

        var emittedFolderIDs = Set<String>()
        cachedLauncherItems = orderedApps(apps).compactMap { app in
            guard let folder = folderByAppID[app.id] else {
                return .app(app)
            }

            guard emittedFolderIDs.insert(folder.id).inserted else { return nil }
            let members = folder.appIDs.compactMap { appsByID[$0] }
            return .folder(folder, members)
        }
        invalidateSearchCache()
    }

    private func rebuildOrderIndex() {
        orderIndex.removeAll(keepingCapacity: true)
        for (index, id) in appOrder.enumerated() where orderIndex[id] == nil {
            orderIndex[id] = index
        }
    }

    private func invalidateSearchCache() {
        cachedSearchQuery = nil
        cachedSearchItems.removeAll(keepingCapacity: true)
    }
}

private struct Preferences: Codable {
    let favoriteIDs: Set<String>
    let categoryOverrides: [String: AppCategory]
    let customCategories: [AppCategory]?
    let appOrder: [String]?
    let folders: [AppFolder]?
}
