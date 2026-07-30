import AppKit

/// Beamhook is an agent app (LSUIElement): its windows can only become key while
/// the activation policy is `.regular`. Windows therefore flip it on the way in —
/// but with more than one open, whichever closes first must NOT drop the app back
/// to `.accessory` while another is still up. This tracks them by identity, so
/// re-showing an already-open window (AddAppWindow reuses its window) is a no-op.
@MainActor
final class AgentWindowPresenter {
    static let shared = AgentWindowPresenter()

    private var open: Set<ObjectIdentifier> = []
    private var observed: Set<ObjectIdentifier> = []
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void

    init(setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = {
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
        if observed.insert(key).inserted {
            // queue: nil so the callback runs synchronously on the poster's
            // thread (willClose is always posted on main), which keeps the
            // bookkeeping — and its tests — free of ordering surprises.
            NotificationCenter.default.addObserver(
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
        if open.isEmpty { setPolicy(.accessory) }
    }
}
