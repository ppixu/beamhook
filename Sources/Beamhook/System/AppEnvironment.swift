import Foundation

/// Facts about how this process was started, for the few places the app must
/// behave differently outside a normal launch.
enum AppEnvironment {
    /// True when the app is running only as the host process for the app-target
    /// test bundle (`xcodebuild test -scheme Beamhook`) rather than for a user.
    ///
    /// XCTest exports `XCTestConfigurationFilePath` into the host's environment
    /// before injecting the bundle, so this is already true in
    /// `applicationDidFinishLaunching` — before any test code has run. The class
    /// check is a backstop for a future Xcode that stops setting it.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
