import CoreGraphics
import Foundation
import ImageIO

actor AppIconLoader {
    static let shared = AppIconLoader()

    private var images: [String: CGImage] = [:]
    private var loadingTasks: [String: Task<CGImage?, Never>] = [:]
    private var failedKeys = Set<String>()
    private var cacheGeneration: UInt64 = 0

    func image(for app: AppItem, pixelSize: Int) async -> CGImage? {
        guard let iconURL = app.iconURL else { return nil }

        let cacheKey = "\(app.id)|\(app.version ?? "")|\(pixelSize)"
        if let image = images[cacheKey] {
            return image
        }
        if failedKeys.contains(cacheKey) {
            return nil
        }
        if let loadingTask = loadingTasks[cacheKey] {
            let generation = cacheGeneration
            let image = await loadingTask.value
            return generation == cacheGeneration ? image : nil
        }

        let generation = cacheGeneration
        let loadingTask: Task<CGImage?, Never> = Task.detached(priority: .utility) {
            await iconDecodeLimiter.acquire()
            guard !Task.isCancelled else {
                await iconDecodeLimiter.release()
                return nil
            }
            let image = Self.decodeIcon(at: iconURL, pixelSize: pixelSize)
            await iconDecodeLimiter.release()
            return image
        }
        loadingTasks[cacheKey] = loadingTask

        let image = await loadingTask.value
        guard generation == cacheGeneration else { return nil }

        loadingTasks[cacheKey] = nil
        if let image {
            images[cacheKey] = image
        } else {
            failedKeys.insert(cacheKey)
        }
        return image
    }

    func removeAll() {
        cacheGeneration &+= 1
        for task in loadingTasks.values {
            task.cancel()
        }
        loadingTasks.removeAll(keepingCapacity: true)
        images.removeAll(keepingCapacity: true)
        failedKeys.removeAll(keepingCapacity: true)
    }

    private nonisolated static func decodeIcon(
        at url: URL,
        pixelSize: Int
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ), hasVisibleContent(image) else {
            return nil
        }
        return image
    }

    private nonisolated static func hasVisibleContent(_ image: CGImage) -> Bool {
        let sampleSize = 32
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var pixels = [UInt8](
            repeating: 0,
            count: sampleSize * sampleSize * bytesPerPixel
        )

        guard let context = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        context.interpolationQuality = .low
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize)
        )

        var nonzeroByteCount = 0
        for byte in pixels where byte > 2 {
            nonzeroByteCount += 1
            if nonzeroByteCount >= 32 {
                return true
            }
        }
        return false
    }
}

private let iconDecodeLimiter = IconDecodeLimiter(limit: 4)

private actor IconDecodeLimiter {
    private let limit: Int
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if activeCount < limit {
            activeCount += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            activeCount -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
