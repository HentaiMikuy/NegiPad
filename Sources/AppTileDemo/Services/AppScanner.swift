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
                let iconURL = appIconURL(
                    info: info,
                    appURL: canonicalURL,
                    fileManager: fileManager
                )

                applications.append(
                    AppItem(
                        id: path,
                        url: canonicalURL,
                        name: name,
                        bundleIdentifier: bundle?.bundleIdentifier,
                        version: version,
                        iconURL: iconURL,
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

    private static func appIconURL(
        info: [String: Any],
        appURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let resourcesURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let declaredNames = [
            info["CFBundleIconFile"] as? String,
            info["CFBundleIconName"] as? String
        ].compactMap { $0 }

        for declaredName in declaredNames {
            let names = URL(fileURLWithPath: declaredName).pathExtension.isEmpty
                ? [declaredName, "\(declaredName).icns"]
                : [declaredName]

            for name in names {
                let candidate = resourcesURL.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(
                    atPath: candidate.path,
                    isDirectory: &isDirectory
                ), !isDirectory.boolValue {
                    return candidate
                }
            }
        }

        let fallbackIcons = (try? fileManager.contentsOfDirectory(
            at: resourcesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            guard url.pathExtension.lowercased() == "icns" else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        } ?? []

        return fallbackIcons.first { iconURL in
            let name = iconURL.deletingPathExtension().lastPathComponent.lowercased()
            return name == "appicon" || name == "app" || name == "icon"
        } ?? fallbackIcons.first
    }
}
