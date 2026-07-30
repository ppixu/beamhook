import AppKit
import SwiftUI

/// Opens Settings in a real window and asks the popover to close first — a sheet
/// would dismiss the popover with it. Reuses one window across shows;
/// `AgentWindowPresenter` owns the activation-policy handling.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(state: AppState) {
        NotificationCenter.default.post(name: .closeBeamhookMenu, object: nil)

        let hosting = NSHostingController(rootView: SettingsView().environmentObject(state))

        let w: NSWindow
        if let existing = window {
            w = existing
            w.contentViewController = hosting
        } else {
            w = NSWindow(contentViewController: hosting)
            w.title = "Beamhook Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }

        AgentWindowPresenter.shared.present(w)
    }

    func hide() { window?.close() }
}
