import Foundation

/// Screen Sharing has no transport commands, but needs a row before audio starts
/// so the menu can watch it for audible samples even with Show All turned off.
enum ScreenSharingAudio {
    static let app = PlayingApp(id: "com.apple.ScreenSharing", displayName: "Screen Sharing",
                                bundleID: "com.apple.ScreenSharing")

    static func runningApps(in bundleIDs: Set<String>) -> [PlayingApp] {
        bundleIDs.contains(app.bundleID) ? [app] : []
    }

    /// High Performance Screen Sharing plays through avconferenced, which has no
    /// NSRunningApplication identity. HAL exposes the whole service, not sessions.
    /// When FaceTime is also open, keep the shared audio under its own identity
    /// rather than applying Screen Sharing's mute/volume to both apps.
    static func identity(for bundleID: String, runningBundleIDs: Set<String>) -> PlayingApp? {
        guard bundleID == "com.apple.avconferenced",
              runningBundleIDs.contains(app.bundleID) else { return nil }
        if runningBundleIDs.contains("com.apple.FaceTime") {
            return PlayingApp(id: bundleID, displayName: "Apple Conferencing Audio", bundleID: bundleID)
        }
        return app
    }
}
