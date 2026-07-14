import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = AppLibrary()

    private var launcherPanel: LauncherPanel?
    private var launcherHostingController: NSHostingController<AnyView>?
    private var managerWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

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

        guard let launcherPanel, let launcherHostingController else { return }

        launcherHostingController.rootView = makeLauncherRootView()
        positionLauncher(launcherPanel)
        launcherPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    private func createLauncherPanel() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
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
        launcherHostingController = hostingController
    }

    private func createManagerWindow() {
        let rootView = ContentView()
            .environmentObject(library)
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
        )
    }

    private func positionLauncher(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main

        guard let visibleFrame = targetScreen?.visibleFrame else {
            panel.center()
            return
        }

        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.midY - panelSize.height / 2 + 44
        )
        panel.setFrameOrigin(origin)
    }
}

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
