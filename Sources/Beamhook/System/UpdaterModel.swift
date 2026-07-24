import Foundation
import Combine
import Sparkle

/// Owns Sparkle's updater and exposes the app version to SwiftUI.
@MainActor
final class UpdaterModel: ObservableObject {
    private let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                          updaterDelegate: nil,
                                                          userDriverDelegate: nil)
    private var hasStarted = false

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        controller.startUpdater()

        // Sparkle recommends doing this immediately after startup when an app
        // intentionally checks on every launch. Respect the persisted setting.
        guard controller.updater.automaticallyChecksForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }
}
