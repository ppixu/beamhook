import Foundation
import Combine
#if OFFICIAL_BUILD
import Sparkle
#endif

/// Owns Sparkle's updater and exposes the app version to SwiftUI.
///
/// Auto-updating is compiled in **only for the official build** (`release.sh`
/// defines `OFFICIAL_BUILD`). A build made from a `git clone` is signed with
/// whatever identity the builder happens to have, so it can never accept the
/// officially signed update: Sparkle requires the replacement bundle to carry
/// the same code-signing identity as the running app, so the update would fail
/// validation *after* prompting — and silently swapping a source build for the
/// notarized one would hand out the paid artifact anyway. Source builds
/// therefore never contact the appcast; they update by pulling and rebuilding,
/// which is what someone building from source expects.
@MainActor
final class UpdaterModel: ObservableObject {
    #if OFFICIAL_BUILD
    private let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                          updaterDelegate: nil,
                                                          userDriverDelegate: nil)
    private var hasStarted = false
    #endif

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// True when this build can update itself — i.e. the official, notarized one.
    var canSelfUpdate: Bool {
        #if OFFICIAL_BUILD
        true
        #else
        false
        #endif
    }

    func start() {
        #if OFFICIAL_BUILD
        guard !hasStarted else { return }
        hasStarted = true

        controller.startUpdater()

        // Sparkle recommends doing this immediately after startup when an app
        // intentionally checks on every launch. Respect the persisted setting.
        guard controller.updater.automaticallyChecksForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
        #endif
    }
}
