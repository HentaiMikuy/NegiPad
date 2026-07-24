import Foundation

/// Launch history for a single app, used to weight search ranking and to
/// build the "recently used" list.
struct AppUsage: Codable, Hashable, Sendable {
    var launchCount: Int
    var lastLaunch: Date

    init(launchCount: Int = 0, lastLaunch: Date) {
        self.launchCount = launchCount
        self.lastLaunch = lastLaunch
    }
}
