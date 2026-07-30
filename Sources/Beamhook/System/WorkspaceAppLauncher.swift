import AppKit
import BeamhookKit

/// Launches a target through NSWorkspace. Asynchronous by construction, so a
/// slow-starting app never blocks the main thread or the media-key tap.
@MainActor
final class WorkspaceAppLauncher: AppLaunching {
    func launch(bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false   // not installed
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Pressing play must not pull focus out of whatever the user is doing.
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            NSLog("WorkspaceAppLauncher: failed to launch \(bundleID): \(error)")
            return false
        }
    }
}
