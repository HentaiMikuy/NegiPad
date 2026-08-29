import Foundation

/// A user-defined search keyword bound to a set of apps, e.g. "数据库" →
/// three database clients whose names never mention the word. Typing the
/// keyword (or a fuzzy/pinyin approximation of it) in the launcher surfaces
/// every bound app, independent of names, aliases, and categories.
struct SearchKeywordGroup: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var keyword: String
    var appIDs: [String]

    init(id: String = "keyword:\(UUID().uuidString)", keyword: String, appIDs: [String]) {
        self.id = id
        self.keyword = keyword
        self.appIDs = appIDs
    }
}
