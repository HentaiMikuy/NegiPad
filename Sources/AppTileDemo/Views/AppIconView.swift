import AppKit
import SwiftUI

struct AppIconView: View {
    let app: AppItem
    let size: CGFloat

    @State private var image: CGImage?
    @State private var fallbackImage: NSImage?
    @State private var reloadGeneration = 0

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else if let fallbackImage {
                Image(nsImage: fallbackImage)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(.quaternary)
                    Image(systemName: "app.fill")
                        .font(.system(size: size * 0.43, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .task(id: taskKey) {
            image = nil
            fallbackImage = nil

            let loadedImage = await AppIconLoader.shared.image(
                for: app,
                pixelSize: max(Int(size * 2), 128)
            )
            guard !Task.isCancelled else { return }

            if let loadedImage {
                image = loadedImage
            } else {
                fallbackImage = SystemAppIconCache.shared.icon(for: app.url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appIconsShouldReload)) { _ in
            image = nil
            fallbackImage = nil
            reloadGeneration &+= 1
        }
    }

    private var cacheKey: String {
        "\(app.id)|\(app.version ?? "")|\(Int(size))"
    }

    private var taskKey: String {
        "\(cacheKey)|\(reloadGeneration)"
    }
}

@MainActor
final class SystemAppIconCache {
    static let shared = SystemAppIconCache()

    private let images = NSCache<NSString, NSImage>()

    func icon(for appURL: URL) -> NSImage {
        let key = appURL.path as NSString
        if let image = images.object(forKey: key) {
            return image
        }

        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        images.setObject(image, forKey: key)
        return image
    }

    func removeAll() {
        images.removeAllObjects()
    }
}

extension Notification.Name {
    static let appIconsShouldReload = Notification.Name(
        "AppTileDemo.appIconsShouldReload"
    )
}
