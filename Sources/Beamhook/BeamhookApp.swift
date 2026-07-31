import SwiftUI
import AppKit
import Combine
import BeamhookKit

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
    let updater = UpdaterModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var glyphObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater.start()

        let hosting = NSHostingController(rootView: MenuContentView()
            .environmentObject(state)
            .environmentObject(updater))
        hosting.sizingOptions = [.preferredContentSize]   // popover sizes to the content
        popover.contentViewController = hosting
        // .transient dismisses on any click OUTSIDE the popover, but not while you
        // interact inside it (e.g. dragging a volume slider). We activate the app
        // when showing it so that dismissal is reliable for an agent app.
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imageScaling = .scaleProportionallyDown
            button.action = #selector(togglePopover)
            button.target = self
            button.toolTip = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "Beamhook"
        }
        statusItem = item

        // The glyph badges the hook with the current target's mark. `@Published`
        // delivers its current value on subscribe, so this also sets the launch icon.
        glyphObserver = state.$menuBarGlyph
            .removeDuplicates()
            .sink { [weak self] glyph in self?.applyStatusIcon(glyph) }

        // Let the hook HUD anchor itself just below this status item, and give
        // the icon a little fishing bob whenever the HUD appears.
        HookHUD.shared.menuBarAnchor = { [weak self] in self?.statusItem?.button?.window?.frame }
        HookHUD.shared.menuPopoverFrame = { [weak self] in
            guard let self, self.popover.isShown else { return nil }
            return self.popover.contentViewController?.view.window?.frame
        }
        HookHUD.shared.onPresent = { [weak self] in self?.bobStatusIcon() }
        // Fully initialize the glass compositor before input startup can emit
        // its first hook notification. This keeps the launch HUD from being
        // dropped or drawing an uninitialized black frame.
        HookHUD.shared.prewarm { [weak self] in
            self?.state.startInput()
        }

        // Let the Add-an-app window ask the popover to close when it opens.
        NotificationCenter.default.addObserver(
            forName: .closeBeamhookMenu, object: nil, queue: .main
        ) { [weak self] _ in self?.popover.performClose(nil) }

        // Deferred a runloop turn so SwiftUI has finished building the app menu
        // (mirrors the startup-hook dispatch above, which needs the same delay
        // for the same reason).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.retargetSettingsMenuItem() }
        }
    }

    /// The placeholder `Settings { EmptyView() }` scene in `BeamhookApp` exists only
    /// to satisfy SwiftUI's Scene requirement, but it still makes the app menu grow
    /// a "Settings…" (⌘,) item that opens its own — blank — window, titled exactly
    /// like `SettingsWindow`'s real one. Point that item at our own Settings window
    /// instead of leaving it live. The item's action selector name differs across
    /// OS versions, so search by name rather than assume which one exists; if
    /// neither is found (a future OS rename, or the menu not built yet) this is a
    /// silent no-op rather than a crash — worst case ⌘, still opens the old blank
    /// window, which is the status quo today.
    private func retargetSettingsMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        let settingsSelectors: Set<Selector> = [
            NSSelectorFromString("showSettingsWindow:"),
            NSSelectorFromString("showPreferencesWindow:"),
        ]
        guard let item = appMenu.items.first(where: { menuItem in
            menuItem.action.map(settingsSelectors.contains) ?? false
        }) else { return }
        item.target = self
        item.action = #selector(openSettingsWindow(_:))
    }

    @objc private func openSettingsWindow(_ sender: Any?) {
        SettingsWindow.shared.show(state: state)
    }

    /// Swap the status-item image. A badged glyph that fails to load falls back to
    /// the plain hook rather than leaving an empty, unclickable status item.
    private func applyStatusIcon(_ glyph: MenuBarGlyph) {
        guard let button = statusItem?.button else { return }
        let image = NSImage(named: glyph.rawValue) ?? NSImage(named: MenuBarGlyph.hook.rawValue)
        image?.isTemplate = true          // let macOS tint it for light/dark menu bars
        button.image = image
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            settleBackdrop()
        }
    }

    /// Give the popover the appearance it will settle on *before* it animates in.
    ///
    /// The backdrop is the popover's frame view (`NSPopoverFrame`), which is an
    /// `NSVisualEffectView` left in `.followsWindowActiveState`. The window only
    /// became key in `popoverDidShow` — which fires once the show animation has
    /// finished — so the popover animated in wearing the material's flat, more
    /// transparent inactive form and then visibly brightened just as it landed.
    ///
    /// `show(relativeTo:…)` has already created the window by the time it
    /// returns, so promote it here instead, and pin the vibrancy so the backdrop
    /// no longer depends on key state at all. `.active` is the right constant to
    /// pin: a `.transient` popover closes as soon as the app deactivates, so it
    /// is never on screen while genuinely inactive.
    ///
    /// Note the frame view is the content view's *superview*. Walking down from
    /// `contentView` finds no effect view at all.
    private func settleBackdrop() {
        guard let window = popover.contentViewController?.view.window else { return }
        window.makeKey()
        func pin(_ view: NSView) {
            (view as? NSVisualEffectView)?.state = .active
            view.subviews.forEach(pin)
        }
        if let frameView = window.contentView?.superview ?? window.contentView {
            pin(frameView)
        }
    }

    /// `NSApp.activate` can complete before NSPopover has created its window,
    /// especially on the first click after login. Promote the actual popover
    /// window once it exists so its controls never inherit the inactive state.
    /// `settleBackdrop()` already did this at show time; this is the backstop for
    /// a first click where activation hadn't landed yet.
    func popoverDidShow(_ notification: Notification) {
        state.setMenuVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        settleBackdrop()
    }

    func popoverDidClose(_ notification: Notification) {
        state.setMenuVisible(false)
    }

    // MARK: - Status-icon "fishing bob"

    private var isBobbing = false

    /// Dip the menu-bar hook a few points and let it spring back up, like a
    /// bobber getting a bite. The button's frame is animated inside the status
    /// item's own window; `home` is restored at the end no matter what.
    private func bobStatusIcon() {
        guard !isBobbing, let button = statusItem?.button, let superview = button.superview else { return }
        isBobbing = true
        let down: CGFloat = superview.isFlipped ? 1 : -1   // toward the screen bottom
        let home = button.frame.origin

        func move(_ dy: CGFloat, _ duration: TimeInterval, _ timing: CAMediaTimingFunctionName,
                  then: (() -> Void)? = nil) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: timing)
                button.animator().setFrameOrigin(NSPoint(x: home.x, y: home.y + dy * down))
            }, completionHandler: { MainActor.assumeIsolated { then?() } })
        }
        move(3.5, 0.16, .easeIn) {           // dip…
            move(-1.5, 0.22, .easeOut) {     // …spring a touch past home…
                move(0, 0.16, .easeInEaseOut) { [weak self] in self?.isBobbing = false }   // …settle
            }
        }
    }
}
