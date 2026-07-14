import SwiftUI

enum AppCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case productivity = "效率办公"
    case development = "开发工具"
    case creativity = "创意设计"
    case entertainment = "影音娱乐"
    case learning = "学习阅读"
    case lifestyle = "生活社交"
    case utilities = "系统工具"
    case other = "其他应用"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .productivity: "checkmark.circle"
        case .development: "hammer"
        case .creativity: "paintpalette"
        case .entertainment: "play.rectangle"
        case .learning: "books.vertical"
        case .lifestyle: "person.2"
        case .utilities: "wrench.and.screwdriver"
        case .other: "square.grid.2x2"
        }
    }

    var tint: Color {
        switch self {
        case .productivity: .blue
        case .development: .indigo
        case .creativity: .pink
        case .entertainment: .orange
        case .learning: .green
        case .lifestyle: .cyan
        case .utilities: .purple
        case .other: .gray
        }
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
}
