import AppKit
import MediaKeyKit

final class WorkspacePresenceChecker: AppPresenceChecking {
    func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
