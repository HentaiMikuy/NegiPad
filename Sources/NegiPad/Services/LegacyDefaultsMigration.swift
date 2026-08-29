import Foundation

/// One-time import of preferences written under the app's pre-rename
/// identity. Changing the bundle identifier (com.konomip.AppTileDemo →
/// com.konomip.NegiPad) also changes the standard defaults domain, so every
/// stored preference would look freshly reset without this copy step.
enum LegacyDefaultsMigration {
    private static let legacyDomainName = "com.konomip.AppTileDemo"
    private static let legacyKeyPrefix = "AppTileDemo."
    private static let importedFlagKey = "NegiPad.ImportedLegacyPreferences"

    /// Idempotent; must run before any settings object reads its keys.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: importedFlagKey) == false else { return }

        defer { defaults.set(true, forKey: importedFlagKey) }

        guard let legacy = defaults.persistentDomain(forName: legacyDomainName),
              !legacy.isEmpty else {
            return
        }

        for (key, value) in legacy {
            defaults.setValue(value, forKey: mappedKey(for: key))
        }
        defaults.removePersistentDomain(forName: legacyDomainName)
    }

    /// Renames the app's own "AppTileDemo.*" keys to "NegiPad.*" and carries
    /// NSWindow frame autosave keys (stored as "NSWindow Frame AppTileDemo.*")
    /// along with the rename; unrelated keys are copied verbatim.
    private static func mappedKey(for key: String) -> String {
        if key.hasPrefix(legacyKeyPrefix) {
            return "NegiPad." + key.dropFirst(legacyKeyPrefix.count)
        }

        let legacyFramePrefix = "NSWindow Frame " + legacyKeyPrefix
        if key.hasPrefix(legacyFramePrefix) {
            return "NSWindow Frame NegiPad." + key.dropFirst(legacyFramePrefix.count)
        }

        return key
    }
}
