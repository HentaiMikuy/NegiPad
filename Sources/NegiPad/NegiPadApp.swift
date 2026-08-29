import SwiftUI

@main
struct NegiPadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("显示启动器") {
                    appDelegate.toggleLauncher()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("应用管理…") {
                    appDelegate.showManager()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
