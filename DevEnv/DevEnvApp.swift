import SwiftUI

@main
struct DevEnvApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1280, height: 820)
    }
}
