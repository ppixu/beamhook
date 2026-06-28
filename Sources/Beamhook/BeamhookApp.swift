import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.startInput()
    }
}

@main
struct BeamhookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Beamhook", image: "MenuBarIcon") {
            MenuContentView()
                .environmentObject(appDelegate.state)
        }
        .menuBarExtraStyle(.window)
    }
}
