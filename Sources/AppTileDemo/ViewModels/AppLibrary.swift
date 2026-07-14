import AppKit
import Combine
import Foundation

@MainActor
final class AppLibrary: ObservableObject {
    @Published private(set) var apps: [AppItem] = []
    @Published private(set) var favoriteIDs = Set<String>()
    @Published private(set) var categoryOverrides: [String: AppCategory] = [:]
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

            apps = result
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
    }

    private func savePreferences() {
        let preferences = Preferences(
            favoriteIDs: favoriteIDs,
            categoryOverrides: categoryOverrides
        )
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: preferencesKey)
    }
}

private struct Preferences: Codable {
    let favoriteIDs: Set<String>
    let categoryOverrides: [String: AppCategory]
}
