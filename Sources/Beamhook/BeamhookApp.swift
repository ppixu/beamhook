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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.startInput()

        let hosting = NSHostingController(rootView: MenuContentView().environmentObject(state))
        hosting.sizingOptions = [.preferredContentSize]   // popover sizes to the content
        popover.contentViewController = hosting
        // We manage dismissal ourselves so that dragging a volume slider never
        // closes the popover, while a click in any OTHER app does. (`.transient`
        // is unreliable for an agent app that isn't the active application.)
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self

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

        // Let the Add-an-app window (and anything else) ask the popover to close.
        NotificationCenter.default.addObserver(
            forName: .closeBeamhookMenu, object: nil, queue: .main
        ) { [weak self] _ in self?.popover.performClose(nil) }
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A GLOBAL monitor only sees events destined for OTHER processes, so clicks
        // and slider drags inside the popover never trigger it — only clicking away
        // (another app, the desktop, another menu-bar item) closes the popover.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in self?.popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }
}
