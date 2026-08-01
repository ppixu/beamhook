import XCTest
@testable import Beamhook

/// This suite runs inside the very process the check exists for: the app
/// launched as a test host. If the detection ever stops working, `startInput()`
/// resumes asking XCTest's host for Accessibility — a system prompt in the face
/// of anyone running the suite — and this test is what catches it.
final class AppEnvironmentTests: XCTestCase {
    func testDetectsTheTestHost() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
    }
}
