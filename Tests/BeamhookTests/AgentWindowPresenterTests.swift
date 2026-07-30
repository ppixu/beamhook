import AppKit
import XCTest
@testable import Beamhook

@MainActor
final class AgentWindowPresenterTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    /// The app must stay .regular until the LAST window closes, or the window
    /// still on screen loses its ability to become key.
    func testPolicyRevertsOnlyAfterTheLastWindowCloses() {
        var policies: [NSApplication.ActivationPolicy] = []
        let presenter = AgentWindowPresenter(setPolicy: { policies.append($0) })
        let first = makeWindow()
        let second = makeWindow()

        presenter.beginPresenting(first)
        presenter.beginPresenting(second)
        first.close()

        XCTAssertEqual(policies, [.regular, .regular])

        second.close()

        XCTAssertEqual(policies, [.regular, .regular, .accessory])
    }

    /// AddAppWindow reuses one window across shows, so re-presenting the same
    /// window must not leave a phantom open count behind.
    func testRepresentingTheSameWindowDoesNotDoubleCount() {
        var policies: [NSApplication.ActivationPolicy] = []
        let presenter = AgentWindowPresenter(setPolicy: { policies.append($0) })
        let window = makeWindow()

        presenter.beginPresenting(window)
        presenter.beginPresenting(window)
        window.close()

        XCTAssertEqual(policies, [.regular, .regular, .accessory])
    }

    /// Functional check of the *policy* sequence across a real close-then-
    /// reopen cycle (the shape AddAppWindow's single cached window goes
    /// through: show, close, show again). This is legitimate as a check of
    /// policy ordering, but it is NOT a regression guard for the
    /// observer-removal fix — see
    /// `testObserverIsDeregisteredOnCloseAndReregisteredOnRepresent` for that.
    /// A stale, never-removed observer produces this exact same sequence: a
    /// block-based NotificationCenter observer keeps firing for its `object:`
    /// on every subsequent post regardless of whether anything downstream
    /// still thinks it's registered, so this test alone cannot tell "removed
    /// and re-registered" apart from "never removed but still happens to
    /// relay the notification".
    ///
    /// Uses `present` (not `beginPresenting`) deliberately: AppKit only posts
    /// `willCloseNotification` once per "open" — a bare `close()` call with no
    /// intervening `orderFront`/`makeKeyAndOrderFront` is a silent no-op the
    /// second time, so exercising a real re-open requires actually putting the
    /// window back on screen, which `beginPresenting` intentionally does not
    /// do.
    func testPolicySequenceAcrossCloseAndRePresent() {
        var policies: [NSApplication.ActivationPolicy] = []
        let presenter = AgentWindowPresenter(setPolicy: { policies.append($0) })
        let window = makeWindow()

        presenter.present(window)
        window.close()

        XCTAssertEqual(policies, [.regular, .accessory])

        presenter.present(window)
        window.close()

        XCTAssertEqual(policies, [.regular, .accessory, .regular, .accessory])
    }

    /// The actual regression guard for the observer-removal fix. A pure
    /// policy-sequence test can't distinguish "observer removed and
    /// re-registered" from "observer never removed but still happens to
    /// work", because a block-based NotificationCenter observer registered
    /// for a given `object:` keeps firing on every subsequent post for that
    /// object whether or not it's ever removed — a reused window that's never
    /// deallocated lets a stale pre-fix observer keep relaying `willClose`
    /// correctly. This asserts the bookkeeping itself via
    /// `AgentWindowPresenter.observerTokenCount` (internal, exposed to tests
    /// through `@testable import`): it must drop to 0 when the window closes
    /// and climb back to 1 when the window is re-presented, which only holds
    /// if `didClose` actually deregisters the observer.
    func testObserverIsDeregisteredOnCloseAndReregisteredOnRepresent() {
        let presenter = AgentWindowPresenter(setPolicy: { _ in })
        let window = makeWindow()

        presenter.present(window)
        XCTAssertEqual(presenter.observerTokenCount, 1)

        window.close()
        XCTAssertEqual(presenter.observerTokenCount, 0)

        presenter.present(window)
        XCTAssertEqual(presenter.observerTokenCount, 1)
    }
}
