import XCTest
@testable import Beamhook

@MainActor
final class WorkspaceAppLauncherTests: XCTestCase {
    /// A bundle id with no app on disk resolves to no URL, so nothing is
    /// launched and the caller learns the target isn't installed.
    func testUninstalledBundleIDReportsNotInstalled() async {
        let launcher = WorkspaceAppLauncher()
        let launched = await launcher.launch(bundleID: "com.beamhook.tests.not.installed")
        XCTAssertFalse(launched)
    }
}
