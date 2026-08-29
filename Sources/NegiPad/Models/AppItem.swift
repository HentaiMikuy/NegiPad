import Foundation

struct AppItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let iconURL: URL?
    let automaticCategory: AppCategory
    /// Lowercase ASCII pinyin of a Chinese name ("weixin"), nil otherwise.
    /// Computed once at scan time so searching never transliterates.
    let pinyinName: String?
    /// First letter of each pinyin syllable ("wx"), nil for non-Chinese names.
    let pinyinInitials: String?
    /// When the bundle landed in its application directory (the same signal
    /// Launchpad's "recently added" uses), falling back to the creation date.
    let installDate: Date?
}
