import SwiftUI

@main
struct MediaKeyHubApp: App {
    var body: some Scene {
        MenuBarExtra("MediaKeyHub", systemImage: "playpause.circle") {
            Text("MediaKeyHub")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
