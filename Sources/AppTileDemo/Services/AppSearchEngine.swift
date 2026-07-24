import Foundation

/// Pure scoring functions behind the launcher's search field.
///
/// A query matches an app through several channels — exact/prefix/word/
/// substring on the name, user aliases, pinyin (full and initials), a fuzzy
/// in-order subsequence, bundle identifier, and category name. Each channel
/// yields a base score on a shared ladder; the best channel wins. Usage
/// signals (launch count and recency) are added on top so, between
/// comparable matches, the apps the user actually opens rank first.
enum AppSearchEngine {
    // MARK: - Normalization

    /// Case-, diacritic-, and width-insensitive form used on both sides of
    /// every comparison.
    static func normalize(_ string: String) -> String {
        string.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
    }

    // MARK: - Pinyin

    /// Transliterates a name that contains Han characters into lowercase
    /// pinyin, e.g. "微信" → (full: "weixin", initials: "wx"). Returns nil
    /// for names without Han characters. Safe to call off the main thread.
    static func pinyinForms(of string: String) -> (full: String, initials: String)? {
        guard string.contains(where: isHanCharacter) else { return nil }

        let mutable = NSMutableString(string: string)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)

        let syllables = (mutable as String)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !syllables.isEmpty else { return nil }

        let full = syllables.joined()
        let initials = syllables.compactMap(\.first).map(String.init).joined()
        return (full, initials)
    }

    private static func isHanCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    // MARK: - Match scoring

    /// Best match score of `normalizedQuery` against one app, or nil when
    /// nothing matches. `normalizedQuery` must come from `normalize(_:)`.
    static func matchScore(
        normalizedQuery query: String,
        appName: String,
        pinyinName: String?,
        pinyinInitials: String?,
        aliases: [String],
        bundleIdentifier: String?,
        categoryName: String
    ) -> Double? {
        var best: Double?

        func consider(_ score: Double?) {
            guard let score else { return }
            if score > (best ?? -.infinity) {
                best = score
            }
        }

        consider(nameMatchScore(normalizedQuery: query, name: appName))

        for alias in aliases {
            consider(aliasMatchScore(normalizedQuery: query, alias: alias))
        }

        // Pinyin only ever contains ASCII letters, so skip it entirely for
        // Chinese (or otherwise non-ASCII) queries.
        if query.allSatisfy(\.isASCII) {
            if let pinyinName {
                consider(pinyinMatchScore(query: query, pinyin: pinyinName, isInitials: false))
            }
            if let pinyinInitials {
                consider(pinyinMatchScore(query: query, pinyin: pinyinInitials, isInitials: true))
            }
        }

        if let bundleIdentifier,
           normalize(bundleIdentifier).contains(query) {
            consider(40)
        }

        let normalizedCategory = normalize(categoryName)
        if normalizedCategory == query {
            consider(45)
        } else if normalizedCategory.contains(query) {
            consider(35)
        }

        return best
    }

    /// Match ladder for a display name (also used for folder names):
    /// exact > prefix > word prefix > substring > fuzzy subsequence.
    static func nameMatchScore(normalizedQuery query: String, name: String) -> Double? {
        let normalizedName = normalize(name)

        if normalizedName == query { return 100 }
        if normalizedName.hasPrefix(query) { return 90 }

        let tokens = normalizedName.components(
            separatedBy: CharacterSet.alphanumerics.inverted
        )
        if tokens.contains(where: { !$0.isEmpty && $0.hasPrefix(query) }) {
            return 80
        }

        if normalizedName.contains(query) { return 65 }

        return fuzzySubsequenceScore(query: query, in: normalizedName)
    }

    private static func aliasMatchScore(normalizedQuery query: String, alias: String) -> Double? {
        let normalizedAlias = normalize(alias)

        if normalizedAlias == query { return 95 }
        if normalizedAlias.hasPrefix(query) { return 85 }
        if normalizedAlias.contains(query) { return 70 }

        return fuzzySubsequenceScore(query: query, in: normalizedAlias).map { $0 + 3 }
    }

    private static func pinyinMatchScore(query: String, pinyin: String, isInitials: Bool) -> Double? {
        if pinyin == query { return isInitials ? 86 : 88 }
        if pinyin.hasPrefix(query) { return isInitials ? 76 : 78 }
        if pinyin.contains(query) { return isInitials ? 58 : 60 }

        guard !isInitials else { return nil }
        return fuzzySubsequenceScore(query: query, in: pinyin).map { $0 - 4 }
    }

    /// In-order subsequence match ("vsc" → "visual studio code"), scored by
    /// how tightly the matched characters cluster. Single-character queries
    /// are excluded — prefix/substring rungs already cover them and a lone
    /// subsequence character matches almost everything.
    static func fuzzySubsequenceScore(query: String, in candidate: String) -> Double? {
        guard query.count >= 2, query.count <= candidate.count else { return nil }

        var firstMatchOffset: Int?
        var lastMatchOffset = 0
        var queryIndex = query.startIndex

        for (offset, character) in candidate.enumerated() {
            guard queryIndex < query.endIndex else { break }
            if character == query[queryIndex] {
                if firstMatchOffset == nil {
                    firstMatchOffset = offset
                }
                lastMatchOffset = offset
                queryIndex = query.index(after: queryIndex)
            }
        }

        guard queryIndex == query.endIndex, let firstMatchOffset else { return nil }

        let span = Double(lastMatchOffset - firstMatchOffset + 1)
        let density = Double(query.count) / span
        let startBonus: Double = firstMatchOffset == 0 ? 6 : 0
        return 18 + density * 18 + startBonus
    }

    // MARK: - Usage weighting

    /// Bonus from launch history: a damped frequency term plus a recency
    /// bucket. Capped so usage reorders comparable matches but a frequently
    /// used fuzzy hit cannot outrank an exact-name match.
    static func usageBoost(launchCount: Int, lastLaunch: Date?, now: Date = Date()) -> Double {
        var boost: Double = 0

        if launchCount > 0 {
            boost += min(22, log2(Double(launchCount) + 1) * 5)
        }

        if let lastLaunch {
            let hours = now.timeIntervalSince(lastLaunch) / 3600
            if hours < 1 {
                boost += 18
            } else if hours < 24 {
                boost += 14
            } else if hours < 24 * 7 {
                boost += 9
            } else if hours < 24 * 30 {
                boost += 4
            }
        }

        return boost
    }
}
