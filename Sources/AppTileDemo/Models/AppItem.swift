import Foundation

struct AppItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let iconURL: URL?
    let automaticCategory: AppCategory
}
