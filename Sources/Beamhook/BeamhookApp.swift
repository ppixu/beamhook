import SwiftUI
import AppKit

@main
struct BeamhookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Beamhook is a menu-bar (agent) app; its UI is the status-item popover set up
    // in the AppDelegate. This empty Settings scene just satisfies App's Scene
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

        // Host the SwiftUI menu in an NSPopover ourselves (instead of
        // MenuBarExtra) so it uses `.transient` behavior: it dismisses only when
        // you click away, and NOT while you drag a volume slider — a drag that
        // starts inside the popover is captured, so the popover stays open.
        let hosting = NSHostingController(rootView: MenuContentView().environmentObject(state))
        hosting.sizingOptions = [.preferredContentSize]   // popover sizes to the content
        popover.contentViewController = hosting
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
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
