import Foundation

struct AppFolder: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var appIDs: [String]

    init(id: String = "folder:\(UUID().uuidString)", name: String, appIDs: [String]) {
        self.id = id
        self.name = name
        self.appIDs = appIDs
    }
}

enum LauncherItem: Identifiable, Hashable, Sendable {
    case app(AppItem)
    case folder(AppFolder, [AppItem])

    var id: String {
        switch self {
        case let .app(app): app.id
        case let .folder(folder, _): folder.id
        }
    }
}
