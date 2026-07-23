import AppKit
import Combine
import Sparkle

/// Thin ObservableObject wrapper around Sparkle's standard updater so SwiftUI
/// views can offer "Check for updates…" and disable it while a check runs.
/// Scheduled background checks are driven by Sparkle itself (SUFeedURL /
/// SUEnableAutomaticChecks in Info.plist).
@MainActor
final class UpdaterModel: ObservableObject {
    private let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                          updaterDelegate: nil,
                                                          userDriverDelegate: nil)

    @Published var canCheckForUpdates = false

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    func checkForUpdates() {
        // Beamhook is an agent app; bring it forward so Sparkle's update
        // window doesn't appear behind whatever the user is doing.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
