import Foundation

enum AppScanner {
    static func scan() -> [AppItem] {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        ]

        var applications: [AppItem] = []
        var seenPaths = Set<String>()

        for root in roots where fileManager.fileExists(atPath: root.path) {
            let candidates = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in candidates where url.pathExtension.lowercased() == "app" {
                let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
                let path = canonicalURL.path

                guard seenPaths.insert(path).inserted else { continue }

                let bundle = Bundle(url: canonicalURL)
                let localizedInfo = bundle?.localizedInfoDictionary ?? [:]
                let info = bundle?.infoDictionary ?? [:]
                let fallbackName = canonicalURL.deletingPathExtension().lastPathComponent
                let name = (localizedInfo["CFBundleDisplayName"] as? String)
                    ?? (localizedInfo["CFBundleName"] as? String)
                    ?? (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? fallbackName
                let rawCategory = info["LSApplicationCategoryType"] as? String
                let version = (info["CFBundleShortVersionString"] as? String)
                    ?? (info["CFBundleVersion"] as? String)

                applications.append(
                    AppItem(
                        id: path,
                        url: canonicalURL,
                        name: name,
                        bundleIdentifier: bundle?.bundleIdentifier,
                        version: version,
                        automaticCategory: AppCategory.infer(
                            from: rawCategory,
                            appName: name
                        )
                    )
                )
            }
        }

        return applications.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
