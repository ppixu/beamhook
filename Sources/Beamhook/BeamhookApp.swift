import SwiftUI
import AppKit

@main
struct BeamhookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Beamhook is a menu-bar (agent) app; its UI is the status-item popover set up
    // in the AppDelegate. This empty Settings scene just satisfies the Scene
    // requirement.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.startInput()

        let hosting = NSHostingController(rootView: MenuContentView().environmentObject(state))
        hosting.sizingOptions = [.preferredContentSize]   // popover sizes to the content
        popover.contentViewController = hosting
        // .transient dismisses on any click OUTSIDE the popover, but not while you
        // interact inside it (e.g. dragging a volume slider). We activate the app
        // when showing it so that dismissal is reliable for an agent app.
        popover.behavior = .transient
        popover.animates = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true          // let macOS tint it for light/dark menu bars
            button.image = image
            button.imageScaling = .scaleProportionallyDown
            button.action = #selector(togglePopover)
            button.target = self
            button.toolTip = "Beamhook"
        }
        statusItem = item

        // Let the Add-an-app window ask the popover to close when it opens.
        NotificationCenter.default.addObserver(
            forName: .closeBeamhookMenu, object: nil, queue: .main
        ) { [weak self] _ in self?.popover.performClose(nil) }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
