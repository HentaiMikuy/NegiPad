import SwiftUI

@main
struct AppTileDemoApp: App {
    @StateObject private var library = AppLibrary()

    var body: some Scene {
        WindowGroup("应用磁贴") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.titleBar)
    }
}
