import AppKit
import Foundation

/// Asks macOS whether Beamhook is currently allowed to send Apple events to
/// another app — the "Automation" list in Privacy & Security.
///
/// This is a status check, not a request: `askUserIfNeeded` is false, so it never
/// raises a prompt of its own. That matters here, because it runs while the menu
/// is open to explain a failed volume read, and a permission dialog appearing at
/// that moment would be both startling and easy to dismiss by accident.
enum AutomationPermission {
    /// nil when the answer is not knowable right now — the app isn't running, or
    /// macOS returned something other than a clear allow/deny. Callers must treat
    /// nil as "no opinion" rather than as a denial.
    static func isAllowed(bundleID: String) -> Bool? {
        guard NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first != nil else { return nil }

        var target = AEAddressDesc()
        let created = bundleID.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return nil }
        defer { AEDisposeDesc(&target) }

        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) {
        case noErr:
            return true
        case OSStatus(errAEEventNotPermitted):
            return false          // -1743: the user said no.
        default:
            // Notably -1744 (consent not yet requested): the next real Apple event
            // will raise the prompt, so there is nothing to warn about yet.
            return nil
        }
    }
}
