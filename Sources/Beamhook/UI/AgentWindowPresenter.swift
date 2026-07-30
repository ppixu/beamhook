import AppKit

/// Beamhook is an agent app (LSUIElement): its windows can only become key while
/// the activation policy is `.regular`. Windows therefore flip it on the way in —
/// but with more than one open, whichever closes first must NOT drop the app back
/// to `.accessory` while another is still up. This tracks them by identity, so
/// re-showing an already-open window (AddAppWindow reuses its window) is a no-op,
/// and tears the observer down again on close so a window can be re-presented
/// (closed, then shown again) without leaking an observer per presentation.
@MainActor
final class AgentWindowPresenter {
    static let shared = AgentWindowPresenter()

    private var open: Set<ObjectIdentifier> = []
    private var observerTokens: [ObjectIdentifier: NSObjectProtocol] = [:]
    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void

    /// Number of windows with a live `willClose` observer registered right
    /// now. `internal` (not `private`) so tests can assert on it directly via
    /// `@testable import` — a pure policy-sequence test cannot distinguish
    /// "observer removed and re-registered on close" from "observer never
    /// removed but still happens to relay the notification", since a
    /// NotificationCenter block observer keeps firing for its `object:`
    /// whether or not anything downstream still considers it registered.
    var observerTokenCount: Int { observerTokens.count }

    // The closure type is annotated `@MainActor` so this default-argument
    // literal — which type-checks in a synchronous nonisolated context
    // regardless of the enclosing (@MainActor) declaration — is itself
    // main-actor-isolated, and can call `NSApp.setActivationPolicy` without a
    // warning.
    init(setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = {
        NSApp.setActivationPolicy($0)
    }) {
        self.setPolicy = setPolicy
    }

    /// Bring `window` up as a real, focusable window.
    func present(_ window: NSWindow) {
        beginPresenting(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Policy + lifecycle bookkeeping, without putting anything on screen.
    func beginPresenting(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if observerTokens[key] == nil {
            // queue: nil so the callback runs synchronously on the poster's
            // thread (willClose is always posted on main), which keeps the
            // bookkeeping — and its tests — free of ordering surprises.
            observerTokens[key] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.didClose(key) }
            }
        }
        open.insert(key)
        setPolicy(.regular)
    }

    private func didClose(_ key: ObjectIdentifier) {
        open.remove(key)
        if let token = observerTokens.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(token)
        }
        if open.isEmpty { setPolicy(.accessory) }
    }
}
