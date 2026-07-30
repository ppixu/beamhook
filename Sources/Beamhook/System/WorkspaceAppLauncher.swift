import AppKit
import os
import BeamhookKit

/// Launches a target through NSWorkspace. Asynchronous by construction, so a
/// slow-starting app never blocks the main thread or the media-key tap.
@MainActor
final class WorkspaceAppLauncher: AppLaunching {
    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "launch")

    func launch(bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Self.log.error("WorkspaceAppLauncher: \(bundleID, privacy: .public) is not installed")
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
            Self.log.error("WorkspaceAppLauncher: failed to launch \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
