import SwiftUI

struct AppCategory: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let symbol: String

    var rawValue: String { name }
    var isCustom: Bool { id.hasPrefix("custom:") }

    var tint: Color {
        switch id {
        case Self.productivity.id: .blue
        case Self.development.id: .indigo
        case Self.creativity.id: .pink
        case Self.entertainment.id: .orange
        case Self.learning.id: .green
        case Self.lifestyle.id: .cyan
        case Self.utilities.id: .purple
        case Self.other.id: .gray
        default: .accentColor
        }
    }

    static let productivity = AppCategory(
        id: "builtin:productivity",
        name: "效率办公",
        symbol: "checkmark.circle"
    )
    static let development = AppCategory(
        id: "builtin:development",
        name: "开发工具",
        symbol: "hammer"
    )
    static let creativity = AppCategory(
        id: "builtin:creativity",
        name: "创意设计",
        symbol: "paintpalette"
    )
    static let entertainment = AppCategory(
        id: "builtin:entertainment",
        name: "影音娱乐",
        symbol: "play.rectangle"
    )
    static let learning = AppCategory(
        id: "builtin:learning",
        name: "学习阅读",
        symbol: "books.vertical"
    )
    static let lifestyle = AppCategory(
        id: "builtin:lifestyle",
        name: "生活社交",
        symbol: "person.2"
    )
    static let utilities = AppCategory(
        id: "builtin:utilities",
        name: "系统工具",
        symbol: "wrench.and.screwdriver"
    )
    static let other = AppCategory(
        id: "builtin:other",
        name: "其他应用",
        symbol: "square.grid.2x2"
    )

    static let builtInCategories = [
        productivity,
        development,
        creativity,
        entertainment,
        learning,
        lifestyle,
        utilities,
        other
    ]

    static let defaultSymbols = [
        "tag",
        "folder",
        "briefcase",
        "building.2",
        "house",
        "cart",
        "gamecontroller",
        "music.note",
        "film",
        "camera",
        "paintpalette",
        "hammer",
        "terminal",
        "books.vertical",
        "graduationcap",
        "heart",
        "figure.run",
        "airplane",
        "globe",
        "leaf",
        "fork.knife",
        "cup.and.saucer",
        "wrench.and.screwdriver",
        "star"
    ]

    static func custom(name: String, symbol: String) -> AppCategory {
        AppCategory(
            id: "custom:\(UUID().uuidString)",
            name: name,
            symbol: symbol
        )
    }

    func updating(name: String, symbol: String) -> AppCategory {
        AppCategory(id: id, name: name, symbol: symbol)
    }

    static func infer(from rawCategory: String?, appName: String) -> AppCategory {
        let category = rawCategory?.lowercased() ?? ""

        if category.contains("developer-tools") {
            return .development
        }
        if category.contains("graphics-design")
            || category.contains("photography")
            || category.contains("music")
            || category.contains("video") {
            return .creativity
        }
        if category.contains("productivity")
            || category.contains("business")
            || category.contains("finance") {
            return .productivity
        }
        if category.contains("games") || category.contains("entertainment") {
            return .entertainment
        }
        if category.contains("education") || category.contains("reference") {
            return .learning
        }
        if category.contains("social-networking")
            || category.contains("lifestyle")
            || category.contains("news")
            || category.contains("travel")
            || category.contains("weather") {
            return .lifestyle
        }
        if category.contains("utilities") {
            return .utilities
        }

        let name = appName.lowercased()
        if ["xcode", "terminal", "iterm", "visual studio code", "android studio"]
            .contains(where: name.contains) {
            return .development
        }
        if ["pages", "numbers", "keynote", "notion", "obsidian", "microsoft word"]
            .contains(where: name.contains) {
            return .productivity
        }
        if ["photos", "photo", "figma", "sketch", "affinity", "adobe"]
            .contains(where: name.contains) {
            return .creativity
        }

        return .other
    }

    static func == (lhs: AppCategory, rhs: AppCategory) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case symbol
    }

    init(id: String, name: String, symbol: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let legacyName = try? singleValue.decode(String.self) {
            self = Self.builtInCategories.first {
                $0.name == legacyName || $0.id == legacyName
            } ?? AppCategory(
                id: "custom:legacy:\(legacyName)",
                name: legacyName,
                symbol: "tag"
            )
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "tag"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(symbol, forKey: .symbol)
    }
}
