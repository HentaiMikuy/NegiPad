import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = AppLibrary()
    let launcherSession = LauncherSession()
    let shortcutSettings = ShortcutSettings()

    private let launcherSize = NSSize(width: 760, height: 560)
    private var launcherPanel: LauncherPanel?
    private var managerWindow: NSWindow?
    private var iconRefreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        shortcutSettings.activate { [weak self] in
            self?.toggleLauncher()
        }

        DispatchQueue.main.async { [weak self] in
            self?.showLauncher()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showLauncher()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        iconRefreshTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc func toggleLauncher() {
        if launcherPanel?.isVisible == true {
            hideLauncher()
        } else {
            showLauncher()
        }
    }

    @objc func showLauncher() {
        if launcherPanel == nil {
            createLauncherPanel()
        }

        guard let launcherPanel else { return }

        NSApp.activate(ignoringOtherApps: true)
        launcherPanel.setContentSize(launcherSize)
        launcherPanel.contentView?.layoutSubtreeIfNeeded()
        launcherSession.beginPresentation()
        positionLauncher(launcherPanel)
        launcherPanel.makeKeyAndOrderFront(nil)

        // NSHostingController completes its initial sizing on the next run-loop
        // pass. Reapply the final size and position so the very first
        // presentation cannot be displaced by that deferred layout.
        DispatchQueue.main.async { [weak self, weak launcherPanel] in
            guard let self,
                  let launcherPanel,
                  launcherPanel.isVisible else {
                return
            }

            launcherPanel.setContentSize(self.launcherSize)
            launcherPanel.contentView?.layoutSubtreeIfNeeded()
            self.positionLauncher(launcherPanel)
        }
    }

    @objc func hideLauncher() {
        launcherPanel?.orderOut(nil)
    }

    @objc func showManager() {
        hideLauncher()

        if managerWindow == nil {
            createManagerWindow()
        }

        guard let managerWindow else { return }
        managerWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        iconRefreshTask?.cancel()
        iconRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            await AppIconLoader.shared.removeAll()
            SystemAppIconCache.shared.removeAll()
            NotificationCenter.default.post(name: .appIconsShouldReload, object: nil)
        }
    }

    private func createLauncherPanel() {
        let panel = LauncherPanel(
            contentRect: NSRect(origin: .zero, size: launcherSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let hostingController = NSHostingController(rootView: makeLauncherRootView())
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient
        ]

        launcherPanel = panel
    }

    private func createManagerWindow() {
        let rootView = ContentView()
            .environmentObject(library)
            .environmentObject(shortcutSettings)
            .frame(minWidth: 820, minHeight: 560)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "应用管理"
        window.contentViewController = NSHostingController(rootView: rootView)
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AppTileDemo.ManagerWindow")

        if !window.setFrameUsingName("AppTileDemo.ManagerWindow") {
            window.center()
        }

        managerWindow = window
    }

    private func makeLauncherRootView() -> AnyView {
        AnyView(
            LauncherView(
                onDismiss: { [weak self] in
                    self?.hideLauncher()
                },
                onOpenManager: { [weak self] in
                    self?.showManager()
                }
            )
            .environmentObject(library)
            .environmentObject(launcherSession)
        )
    }

    private func positionLauncher(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main

        guard let screenFrame = targetScreen?.frame else {
            panel.center()
            return
        }

        let frame = NSRect(
            x: (screenFrame.midX - launcherSize.width / 2).rounded(),
            y: (screenFrame.midY - launcherSize.height / 2).rounded(),
            width: launcherSize.width,
            height: launcherSize.height
        )
        panel.setFrame(frame, display: panel.isVisible, animate: false)
    }
}

@MainActor
final class LauncherSession: ObservableObject {
    @Published private(set) var presentationID = 0

    func beginPresentation() {
        presentationID &+= 1
    }
}

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
