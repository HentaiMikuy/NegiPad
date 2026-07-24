import AppKit
import Combine
import Foundation

@MainActor
final class AppLibrary: ObservableObject {
    @Published private(set) var apps: [AppItem] = []
    @Published private(set) var favoriteIDs = Set<String>()
    @Published private(set) var categoryOverrides: [String: AppCategory] = [:]
    @Published private(set) var customCategories: [AppCategory] = []
    /// User-defined keyword → apps bindings ("数据库" → three database
    /// clients); the launcher search treats each keyword as an extra match
    /// channel for every bound app.
    @Published private(set) var keywordGroups: [SearchKeywordGroup] = []
    /// Top-level launcher order. Entries are app IDs (apps outside any
    /// folder) or folder IDs, so a folder occupies its own reorderable slot
    /// instead of inheriting the position of its first member.
    @Published private(set) var topLevelOrder: [String] = []
    @Published private(set) var folders: [AppFolder] = []
    @Published private(set) var canUndo = false
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let preferencesKey = "AppTileDemo.Preferences"
    private let maxUndoDepth = 30
    private var appsByID: [String: AppItem] = [:]
    private var orderIndex: [String: Int] = [:]
    private var foldersByID: [String: AppFolder] = [:]
    private var folderIDByAppID: [String: String] = [:]
    /// Per-app launch history keyed by app ID, powering usage-weighted
    /// search ranking and the "recently used" list.
    private var usageStats: [String: AppUsage] = [:]
    /// User-defined search aliases keyed by app ID (e.g. "ps" → Photoshop).
    private var aliases: [String: [String]] = [:]
    private var cachedLauncherItems: [LauncherItem] = []
    /// Apps sorted newest-install-first, rebuilt after every scan; powers the
    /// launcher's "recently installed" strip.
    private var cachedRecentlyInstalledApps: [AppItem] = []
    private var cachedSearchQuery: String?
    private var cachedSearchItems: [LauncherItem] = []
    private var automaticRefreshTask: Task<Void, Never>?
    private var refreshRequestedWhileLoading = false
    private var undoStack: [OrganizeSnapshot] = []
    private var isOrganizeSessionActive = false
    private var organizeSessionHasChanges = false

    init() {
        loadPreferences()
        refresh()
    }

    var categories: [AppCategory] {
        AppCategory.builtInCategories + customCategories
    }

    func refresh() {
        guard !isLoading else {
            refreshRequestedWhileLoading = true
            return
        }
        isLoading = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AppScanner.scan()
            }.value

            let previousOrder = topLevelOrder
            let previousFolders = folders
            apps = result
            reconcile(with: result)
            rebuildDerivedData()
            if topLevelOrder != previousOrder || folders != previousFolders {
                savePreferences()
            }
            isLoading = false

            if refreshRequestedWhileLoading {
                refreshRequestedWhileLoading = false
                refresh()
            }
        }
    }

    func scheduleAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            self?.refresh()
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
    func createCustomCategory(
        name: String,
        symbol: String,
        tintChoice: AppCategoryTint
    ) -> AppCategory? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCategoryNameAvailable(trimmedName) else { return nil }

        let category = AppCategory.custom(
            name: trimmedName,
            symbol: symbol,
            tintChoice: tintChoice
        )
        customCategories.append(category)
        invalidateSearchCache()
        savePreferences()
        return category
    }

    @discardableResult
    func updateCustomCategory(
        _ categoryID: String,
        name: String,
        symbol: String,
        tintChoice: AppCategoryTint
    ) -> AppCategory? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = customCategories.firstIndex(where: { $0.id == categoryID }),
              isCategoryNameAvailable(trimmedName, excluding: categoryID) else {
            return nil
        }

        let updatedCategory = customCategories[index].updating(
            name: trimmedName,
            symbol: symbol,
            tintChoice: tintChoice
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

    /// The most recently installed apps, newest first. Apps whose install
    /// date could not be determined never appear.
    func recentlyInstalledApps(limit: Int) -> [AppItem] {
        Array(cachedRecentlyInstalledApps.prefix(limit))
    }

    func launcherItems(matching query: String) -> [LauncherItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return cachedLauncherItems }

        if cachedSearchQuery == normalizedQuery {
            return cachedSearchItems
        }

        let queryKey = AppSearchEngine.normalize(normalizedQuery)
        let now = Date()

        struct ScoredItem {
            let item: LauncherItem
            let score: Double
            let gridOrder: Int
        }
        var scoredItems: [ScoredItem] = []

        // Folders match on their name (same ladder as app names, including
        // pinyin computed on the fly — folder counts are tiny).
        var matchedFolderMemberIDs = Set<String>()
        for (position, item) in cachedLauncherItems.enumerated() {
            guard case let .folder(folder, members) = item else { continue }

            var folderScore = AppSearchEngine.nameMatchScore(
                normalizedQuery: queryKey,
                name: folder.name
            )
            if folderScore == nil,
               queryKey.allSatisfy(\.isASCII),
               let pinyin = AppSearchEngine.pinyinForms(of: folder.name) {
                folderScore = [
                    AppSearchEngine.nameMatchScore(normalizedQuery: queryKey, name: pinyin.full),
                    AppSearchEngine.nameMatchScore(normalizedQuery: queryKey, name: pinyin.initials)
                ].compactMap { $0 }.max().map { $0 - 10 }
            }

            guard let folderScore else { continue }
            matchedFolderMemberIDs.formUnion(folder.appIDs)
            scoredItems.append(
                ScoredItem(item: .folder(folder, members), score: folderScore, gridOrder: position)
            )
        }

        // User keyword bindings: each group's keyword is scored once against
        // the query (not per app), and every bound app inherits the best
        // score any of its groups earned.
        var keywordScoreByAppID: [String: Double] = [:]
        for group in keywordGroups {
            guard let score = AppSearchEngine.keywordMatchScore(
                normalizedQuery: queryKey,
                keyword: group.keyword
            ) else { continue }
            for appID in group.appIDs
            where score > (keywordScoreByAppID[appID] ?? -.infinity) {
                keywordScoreByAppID[appID] = score
            }
        }

        // Apps: best channel match + usage boost. Members of an already
        // matched folder stay hidden to avoid double listings.
        for app in apps where !matchedFolderMemberIDs.contains(app.id) {
            let channelScore = AppSearchEngine.matchScore(
                normalizedQuery: queryKey,
                appName: app.name,
                pinyinName: app.pinyinName,
                pinyinInitials: app.pinyinInitials,
                aliases: aliases[app.id] ?? [],
                bundleIdentifier: app.bundleIdentifier,
                categoryName: category(for: app).rawValue
            )
            guard let matchScore = [channelScore, keywordScoreByAppID[app.id]]
                .compactMap({ $0 })
                .max() else {
                continue
            }

            let usage = usageStats[app.id]
            let usageBoost = AppSearchEngine.usageBoost(
                launchCount: usage?.launchCount ?? 0,
                lastLaunch: usage?.lastLaunch,
                now: now
            )
            scoredItems.append(
                ScoredItem(
                    item: .app(app),
                    score: matchScore + usageBoost,
                    gridOrder: orderIndex[app.id] ?? Int.max
                )
            )
        }

        scoredItems.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.gridOrder < rhs.gridOrder
        }
        let items = scoredItems.map(\.item)

        cachedSearchQuery = normalizedQuery
        cachedSearchItems = items
        return items
    }

    func folder(withID id: String) -> AppFolder? {
        foldersByID[id]
    }

    func app(withID id: String) -> AppItem? {
        appsByID[id]
    }

    func folderContaining(_ appID: String) -> AppFolder? {
        folderIDByAppID[appID].flatMap { foldersByID[$0] }
    }

    func apps(in folder: AppFolder) -> [AppItem] {
        return folder.appIDs.compactMap { appsByID[$0] }
    }

    // MARK: - Organizing (all mutations below are undoable)

    /// Live drag reordering calls the move APIs continuously while the
    /// pointer hovers. A session groups everything that happens during one
    /// drag into a single undo step and defers persistence until the drag
    /// ends.
    func beginOrganizeSession() {
        endOrganizeSession()
        isOrganizeSessionActive = true
    }

    func endOrganizeSession() {
        guard isOrganizeSessionActive else { return }
        isOrganizeSessionActive = false
        if organizeSessionHasChanges {
            organizeSessionHasChanges = false
            savePreferences()
        }
    }

    func undoLastOrganize() {
        guard let snapshot = undoStack.popLast() else { return }
        topLevelOrder = snapshot.topLevelOrder
        folders = snapshot.folders
        canUndo = !undoStack.isEmpty
        // Apps may have been installed/removed since the snapshot was taken.
        reconcile(with: apps)
        rebuildDerivedData()
        savePreferences()
    }

    @discardableResult
    func createFolder(containing draggedID: String, and targetID: String) -> String? {
        guard draggedID != targetID,
              let draggedApp = appsByID[draggedID],
              let targetApp = appsByID[targetID] else {
            return nil
        }

        if let targetFolderID = folderIDByAppID[targetID] {
            addApp(draggedID, toFolder: targetFolderID)
            return targetFolderID
        }
        if let draggedFolderID = folderIDByAppID[draggedID] {
            addApp(targetID, toFolder: draggedFolderID)
            return draggedFolderID
        }

        guard let targetIndex = topLevelOrder.firstIndex(of: targetID) else { return nil }

        recordUndoSnapshot()
        let name = category(for: draggedApp) == category(for: targetApp)
            ? category(for: targetApp).rawValue
            : "应用文件夹"
        let folder = AppFolder(name: name, appIDs: [targetID, draggedID])

        var order = topLevelOrder
        order[targetIndex] = folder.id
        order.removeAll { $0 == draggedID }
        topLevelOrder = order
        folders.append(folder)
        rebuildDerivedData()
        savePreferences()
        return folder.id
    }

    func addApp(_ appID: String, toFolder folderID: String) {
        guard appsByID[appID] != nil,
              let folder = foldersByID[folderID],
              !folder.appIDs.contains(appID) else {
            return
        }

        recordUndoSnapshot()
        detachFromFolderIfNeeded(appID)
        topLevelOrder.removeAll { $0 == appID }

        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }) else {
            discardLastUndoSnapshot()
            rebuildDerivedData()
            return
        }
        folders[folderIndex].appIDs.append(appID)
        rebuildDerivedData()
        savePreferences()
    }

    @discardableResult
    func removeApp(_ appID: String, fromFolder folderID: String) -> Bool {
        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }),
              folders[folderIndex].appIDs.contains(appID) else {
            return false
        }

        recordUndoSnapshot()
        folders[folderIndex].appIDs.removeAll { $0 == appID }

        // The removed app lands right after the folder it came out of.
        if let entryIndex = topLevelOrder.firstIndex(of: folderID) {
            topLevelOrder.insert(appID, at: entryIndex + 1)
        } else {
            topLevelOrder.append(appID)
        }

        if folders[folderIndex].appIDs.count < 2 {
            let survivors = folders[folderIndex].appIDs
            if let entryIndex = topLevelOrder.firstIndex(of: folderID) {
                topLevelOrder.replaceSubrange(entryIndex...entryIndex, with: survivors)
            } else {
                topLevelOrder.append(contentsOf: survivors)
            }
            folders.remove(at: folderIndex)
        }

        rebuildDerivedData()
        savePreferences()
        return true
    }

    func dissolveFolder(_ folderID: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }

        recordUndoSnapshot()
        let members = folders[index].appIDs
        if let entryIndex = topLevelOrder.firstIndex(of: folderID) {
            topLevelOrder.replaceSubrange(entryIndex...entryIndex, with: members)
        } else {
            topLevelOrder.append(contentsOf: members)
        }
        folders.remove(at: index)
        rebuildDerivedData()
        savePreferences()
    }

    func renameFolder(_ folderID: String, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmedName.isEmpty ? "应用文件夹" : trimmedName
        guard folders[index].name != newName else { return }

        recordUndoSnapshot()
        folders[index].name = newName
        rebuildDerivedData()
        savePreferences()
    }

    /// Reorders a top-level entry (an app or a folder) relative to another
    /// top-level entry. When `targetID` names an app that lives inside a
    /// folder, the folder's slot is used as the target.
    func moveItem(_ draggedID: String, relativeTo targetID: String, placeAfter: Bool) {
        guard draggedID != targetID,
              topLevelOrder.contains(draggedID) else {
            return
        }
        let targetEntry = folderIDByAppID[targetID] ?? targetID
        guard targetEntry != draggedID else { return }

        var order = topLevelOrder
        order.removeAll { $0 == draggedID }
        guard let targetIndex = order.firstIndex(of: targetEntry) else { return }
        order.insert(draggedID, at: placeAfter ? targetIndex + 1 : targetIndex)

        // Live reordering re-invokes this on every pointer move; settled
        // arrangements must be a cheap no-op.
        guard order != topLevelOrder else { return }

        recordUndoSnapshot()
        topLevelOrder = order
        // Only the entry order changed — app/folder lookups are untouched, so
        // skip the full rebuild and reproject just the order.
        reprojectOrder()
        savePreferences()
    }

    /// Moves a top-level entry to the end of the launcher, used when the
    /// user drops onto blank space.
    func moveItemToEnd(_ draggedID: String) {
        guard topLevelOrder.contains(draggedID),
              topLevelOrder.last != draggedID else {
            return
        }

        recordUndoSnapshot()
        topLevelOrder.removeAll { $0 == draggedID }
        topLevelOrder.append(draggedID)
        rebuildDerivedData()
        savePreferences()
    }

    /// Reorders an app relative to another app inside the same folder.
    func moveApp(
        _ draggedID: String,
        relativeTo targetID: String,
        placeAfter: Bool,
        inFolder folderID: String
    ) {
        guard draggedID != targetID,
              let folderIndex = folders.firstIndex(where: { $0.id == folderID }),
              folders[folderIndex].appIDs.contains(draggedID) else {
            return
        }

        var memberIDs = folders[folderIndex].appIDs
        memberIDs.removeAll { $0 == draggedID }
        guard let targetIndex = memberIDs.firstIndex(of: targetID) else { return }
        memberIDs.insert(draggedID, at: placeAfter ? targetIndex + 1 : targetIndex)
        guard memberIDs != folders[folderIndex].appIDs else { return }

        recordUndoSnapshot()
        folders[folderIndex].appIDs = memberIDs
        // A single folder's membership order changed; refresh its cached copy
        // and reproject, skipping the app-dictionary rebuild.
        foldersByID[folderID] = folders[folderIndex]
        reprojectOrder()
        savePreferences()
    }

    /// Index-based folder reordering for the manager list. Folder IDs keep
    /// occupying the same launcher slots; only their sequence changes.
    func moveFolders(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty else { return }

        recordUndoSnapshot()
        var reordered = folders
        reordered.move(fromOffsets: source, toOffset: destination)
        folders = reordered

        var folderIDIterator = reordered.map(\.id).makeIterator()
        topLevelOrder = topLevelOrder.map { entry in
            foldersByID[entry] != nil ? (folderIDIterator.next() ?? entry) : entry
        }
        rebuildDerivedData()
        savePreferences()
    }

    /// Index-based member reordering for the manager list.
    func moveApps(inFolder folderID: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty,
              let folderIndex = folders.firstIndex(where: { $0.id == folderID }) else {
            return
        }

        recordUndoSnapshot()
        folders[folderIndex].appIDs.move(fromOffsets: source, toOffset: destination)
        rebuildDerivedData()
        savePreferences()
    }

    func launch(_ app: AppItem) {
        recordLaunch(of: app.id)

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

    // MARK: - Usage tracking

    func usage(for appID: String) -> AppUsage? {
        usageStats[appID]
    }

    func clearUsageHistory() {
        guard !usageStats.isEmpty else { return }
        usageStats.removeAll()
        invalidateSearchCache()
        savePreferences()
    }

    private func recordLaunch(of appID: String) {
        if var usage = usageStats[appID] {
            usage.launchCount += 1
            usage.lastLaunch = Date()
            usageStats[appID] = usage
        } else {
            usageStats[appID] = AppUsage(launchCount: 1, lastLaunch: Date())
        }
        // Ranking inputs changed, so any cached result set is stale.
        invalidateSearchCache()
        savePreferences()
    }

    // MARK: - Aliases

    func aliases(for appID: String) -> [String] {
        aliases[appID] ?? []
    }

    func setAliases(_ rawAliases: [String], for appID: String) {
        var seen = Set<String>()
        let cleaned = rawAliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { alias in
                !alias.isEmpty && seen.insert(alias.lowercased()).inserted
            }

        if cleaned.isEmpty {
            guard aliases[appID] != nil else { return }
            aliases[appID] = nil
        } else {
            guard aliases[appID] != cleaned else { return }
            aliases[appID] = cleaned
        }
        invalidateSearchCache()
        savePreferences()
    }

    // MARK: - Search keywords

    func isKeywordAvailable(_ keyword: String, excluding groupID: String? = nil) -> Bool {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return false }

        return !keywordGroups.contains { group in
            group.id != groupID
                && group.keyword.localizedCaseInsensitiveCompare(trimmedKeyword) == .orderedSame
        }
    }

    @discardableResult
    func createKeywordGroup(keyword: String, appIDs: [String]) -> SearchKeywordGroup? {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isKeywordAvailable(trimmedKeyword) else { return nil }

        let group = SearchKeywordGroup(
            keyword: trimmedKeyword,
            appIDs: deduplicated(appIDs)
        )
        keywordGroups.append(group)
        invalidateSearchCache()
        savePreferences()
        return group
    }

    @discardableResult
    func updateKeywordGroup(
        _ groupID: String,
        keyword: String,
        appIDs: [String]
    ) -> SearchKeywordGroup? {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = keywordGroups.firstIndex(where: { $0.id == groupID }),
              isKeywordAvailable(trimmedKeyword, excluding: groupID) else {
            return nil
        }

        var group = keywordGroups[index]
        group.keyword = trimmedKeyword
        group.appIDs = deduplicated(appIDs)
        guard group != keywordGroups[index] else { return group }

        keywordGroups[index] = group
        invalidateSearchCache()
        savePreferences()
        return group
    }

    func deleteKeywordGroup(_ groupID: String) {
        guard keywordGroups.contains(where: { $0.id == groupID }) else { return }

        keywordGroups.removeAll { $0.id == groupID }
        invalidateSearchCache()
        savePreferences()
    }

    private func deduplicated(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Undo stack

    private func recordUndoSnapshot() {
        if isOrganizeSessionActive {
            guard !organizeSessionHasChanges else { return }
            organizeSessionHasChanges = true
        }
        undoStack.append(OrganizeSnapshot(topLevelOrder: topLevelOrder, folders: folders))
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst(undoStack.count - maxUndoDepth)
        }
        canUndo = true
    }

    private func discardLastUndoSnapshot() {
        _ = undoStack.popLast()
        canUndo = !undoStack.isEmpty
    }

    /// Pulls an app out of whatever folder currently holds it, dissolving
    /// the folder in place if fewer than two members remain. Does NOT insert
    /// the app back into `topLevelOrder`; callers decide where it lands.
    private func detachFromFolderIfNeeded(_ appID: String) {
        guard let folderID = folderIDByAppID[appID],
              let folderIndex = folders.firstIndex(where: { $0.id == folderID }) else {
            return
        }

        folders[folderIndex].appIDs.removeAll { $0 == appID }
        if folders[folderIndex].appIDs.count < 2 {
            let survivors = folders[folderIndex].appIDs
            if let entryIndex = topLevelOrder.firstIndex(of: folderID) {
                topLevelOrder.replaceSubrange(entryIndex...entryIndex, with: survivors)
            } else {
                topLevelOrder.append(contentsOf: survivors)
            }
            folders.remove(at: folderIndex)
        }
        folderIDByAppID[appID] = nil
    }

    // MARK: - Persistence & reconciliation

    private func loadPreferences() {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey),
              let preferences = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return
        }

        favoriteIDs = preferences.favoriteIDs
        categoryOverrides = preferences.categoryOverrides
        customCategories = preferences.customCategories ?? []
        folders = preferences.folders ?? []
        usageStats = preferences.usageStats ?? [:]
        aliases = preferences.aliases ?? [:]
        keywordGroups = preferences.keywordGroups ?? []

        if let savedOrder = preferences.topLevelOrder {
            topLevelOrder = savedOrder
        } else {
            // Legacy preferences only stored a flat app order; folders were
            // implicitly placed at their first member's position.
            migrateLegacyOrder(preferences.appOrder ?? [])
        }
        rebuildDerivedData()
    }

    private func migrateLegacyOrder(_ appOrder: [String]) {
        var rank: [String: Int] = [:]
        for (index, id) in appOrder.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        for index in folders.indices {
            folders[index].appIDs.sort {
                (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max)
            }
        }

        var folderIDByApp: [String: String] = [:]
        for folder in folders {
            for appID in folder.appIDs {
                folderIDByApp[appID] = folder.id
            }
        }

        var seenEntries = Set<String>()
        var order: [String] = []
        for appID in appOrder {
            if let folderID = folderIDByApp[appID] {
                if seenEntries.insert(folderID).inserted {
                    order.append(folderID)
                }
            } else if seenEntries.insert(appID).inserted {
                order.append(appID)
            }
        }
        for folder in folders where seenEntries.insert(folder.id).inserted {
            order.append(folder.id)
        }
        topLevelOrder = order
    }

    private func savePreferences() {
        // Deferred until endOrganizeSession() while a drag is in flight.
        guard !isOrganizeSessionActive else { return }
        let preferences = Preferences(
            favoriteIDs: favoriteIDs,
            categoryOverrides: categoryOverrides,
            customCategories: customCategories,
            appOrder: flattenedAppOrder(),
            folders: folders,
            topLevelOrder: topLevelOrder,
            usageStats: usageStats,
            aliases: aliases,
            keywordGroups: keywordGroups
        )
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: preferencesKey)
    }

    /// Flat per-app order derived from the top-level order, kept only so a
    /// downgrade to a build that predates `topLevelOrder` stays coherent.
    private func flattenedAppOrder() -> [String] {
        topLevelOrder.flatMap { entry in
            foldersByID[entry]?.appIDs ?? [entry]
        }
    }

    private func reconcile(with applications: [AppItem]) {
        let validIDs = Set(applications.map(\.id))
        var assignedIDs = Set<String>()
        var droppedFolderSurvivors: [String: [String]] = [:]

        // Drop usage/alias records for apps that are no longer installed.
        usageStats = usageStats.filter { validIDs.contains($0.key) }
        aliases = aliases.filter { validIDs.contains($0.key) }

        folders = folders.compactMap { folder in
            var updatedFolder = folder
            updatedFolder.appIDs = folder.appIDs.filter { id in
                validIDs.contains(id) && assignedIDs.insert(id).inserted
            }
            if updatedFolder.appIDs.count >= 2 {
                return updatedFolder
            }
            droppedFolderSurvivors[folder.id] = updatedFolder.appIDs
            return nil
        }

        let folderIDs = Set(folders.map(\.id))
        let memberIDs = Set(folders.flatMap(\.appIDs))
        var seenEntries = Set<String>()
        var reconciledOrder: [String] = []

        for entry in topLevelOrder {
            if let survivors = droppedFolderSurvivors[entry] {
                for id in survivors
                where validIDs.contains(id) && !memberIDs.contains(id)
                    && seenEntries.insert(id).inserted {
                    reconciledOrder.append(id)
                }
            } else if folderIDs.contains(entry) {
                if seenEntries.insert(entry).inserted {
                    reconciledOrder.append(entry)
                }
            } else if validIDs.contains(entry),
                      !memberIDs.contains(entry),
                      seenEntries.insert(entry).inserted {
                reconciledOrder.append(entry)
            }
        }

        // Newly discovered apps land at the end; the scanner already sorts
        // them by name.
        for app in applications
        where !memberIDs.contains(app.id) && seenEntries.insert(app.id).inserted {
            reconciledOrder.append(app.id)
        }
        for folder in folders where seenEntries.insert(folder.id).inserted {
            reconciledOrder.append(folder.id)
        }

        topLevelOrder = reconciledOrder
    }

    private func rebuildDerivedData() {
        appsByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        cachedRecentlyInstalledApps = apps
            .compactMap { app in
                app.installDate.map { (app: app, installDate: $0) }
            }
            .sorted { lhs, rhs in
                if lhs.installDate != rhs.installDate {
                    return lhs.installDate > rhs.installDate
                }
                // System updates stamp whole batches with one date; keep the
                // strip stable across rescans with a name tie-break.
                return lhs.app.name.localizedStandardCompare(rhs.app.name)
                    == .orderedAscending
            }
            .map(\.app)
        rebuildFolderLookups()
        reprojectOrder()
    }

    private func rebuildFolderLookups() {
        foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        folderIDByAppID.removeAll(keepingCapacity: true)

        for folder in folders {
            for appID in folder.appIDs {
                folderIDByAppID[appID] = folder.id
            }
        }
    }

    /// Rebuilds only the order-derived projections (rank index and launcher
    /// items) from `topLevelOrder`, reusing the existing app/folder lookups.
    ///
    /// This is the hot path a live drag hits on every pointer tick, so it
    /// deliberately skips rebuilding `appsByID`, `foldersByID`, and
    /// `folderIDByAppID` — none of them change when items merely move — and
    /// folds the rank index and launcher-item builds into a single pass.
    private func reprojectOrder() {
        orderIndex.removeAll(keepingCapacity: true)
        var launcherItems: [LauncherItem] = []
        launcherItems.reserveCapacity(topLevelOrder.count)
        var rank = 0

        for entry in topLevelOrder {
            if let folder = foldersByID[entry] {
                for appID in folder.appIDs where orderIndex[appID] == nil {
                    orderIndex[appID] = rank
                    rank += 1
                }
                launcherItems.append(
                    .folder(folder, folder.appIDs.compactMap { appsByID[$0] })
                )
            } else if let app = appsByID[entry] {
                if orderIndex[entry] == nil {
                    orderIndex[entry] = rank
                    rank += 1
                }
                launcherItems.append(.app(app))
            }
        }

        cachedLauncherItems = launcherItems
        invalidateSearchCache()
    }

    private func invalidateSearchCache() {
        cachedSearchQuery = nil
        cachedSearchItems.removeAll(keepingCapacity: true)
    }
}

private struct OrganizeSnapshot {
    let topLevelOrder: [String]
    let folders: [AppFolder]
}

private struct Preferences: Codable {
    let favoriteIDs: Set<String>
    let categoryOverrides: [String: AppCategory]
    let customCategories: [AppCategory]?
    let appOrder: [String]?
    let folders: [AppFolder]?
    let topLevelOrder: [String]?
    let usageStats: [String: AppUsage]?
    let aliases: [String: [String]]?
    let keywordGroups: [SearchKeywordGroup]?
}
