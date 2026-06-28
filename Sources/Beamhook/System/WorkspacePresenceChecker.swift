import AppKit
import BeamhookKit

final class WorkspacePresenceChecker: AppPresenceChecking {
    func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
