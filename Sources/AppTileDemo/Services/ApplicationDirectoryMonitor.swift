import Darwin
import Dispatch
import Foundation

final class ApplicationDirectoryMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "AppTileDemo.ApplicationDirectoryMonitor",
        qos: .utility
    )
    private let eventMask: DispatchSource.FileSystemEvent = [
        .write,
        .delete,
        .rename,
        .extend,
        .attrib,
        .link,
        .revoke
    ]

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var reconcileWorkItem: DispatchWorkItem?
    private var onChange: (@MainActor @Sendable () -> Void)?
    private var isRunning = false

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.onChange = onChange
            self.reconcileSources()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.reconcileWorkItem?.cancel()
            self.reconcileWorkItem = nil
            self.onChange = nil

            for source in self.sources.values {
                source.cancel()
            }
            self.sources.removeAll()
        }
    }

    private func handleFileSystemEvent() {
        guard isRunning else { return }

        let changeHandler = onChange
        Task { @MainActor in
            changeHandler?()
        }

        reconcileWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.reconcileSources()
        }
        reconcileWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: workItem)
    }

    private func reconcileSources() {
        guard isRunning else { return }

        let desiredURLs = Set(
            AppScanner.applicationDirectories.compactMap(nearestExistingDirectory)
        )
        let desiredPaths = Set(desiredURLs.map(\.path))

        let obsoletePaths = sources.keys.filter { !desiredPaths.contains($0) }
        for path in obsoletePaths {
            sources.removeValue(forKey: path)?.cancel()
        }

        for url in desiredURLs where sources[url.path] == nil {
            addSource(for: url)
        }
    }

    private func nearestExistingDirectory(for targetURL: URL) -> URL? {
        var candidate = targetURL.standardizedFileURL
        let fileManager = FileManager.default

        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        return nil
    }

    private func addSource(for directoryURL: URL) {
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: eventMask,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleFileSystemEvent()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        sources[directoryURL.path] = source
        source.resume()
    }
}
