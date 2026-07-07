import AppKit
import BeamhookKit

final class WorkspacePresenceChecker: AppPresenceChecking {
    func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Running AND done launching. A just-launched app (isFinishedLaunching == false)
    /// can leave `tell application …` blocking on the Apple-event send for a while.
    /// This is now a latency optimization (avoid churning a launching app): the actual
    /// freeze-safety is off-main execution + the `with timeout` cap in AppleScriptExecutor.
    /// Trade-off: an app that never reports finished-launching stays uncontrollable —
    /// fine for the standard GUI media players Beamhook targets.
    func isReady(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.isFinishedLaunching }
    }
}
