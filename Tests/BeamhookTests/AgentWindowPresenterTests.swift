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
}
