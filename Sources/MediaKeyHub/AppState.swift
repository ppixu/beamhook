import AppKit
import Combine
import MediaKeyKit

@MainActor
final class AppState: ObservableObject {
    let store: AppDefinitionStore
    let registry: AppRegistry
    let targetManager: TargetManager
    let permissions = PermissionsManager()

    private let tap: MediaKeyTap
    private let watchdog: TapWatchdog

    @Published var selectedTargetID: String?
    @Published var availableApps: [AppDefinition]
    @Published var hasAccessibility: Bool = false
    @Published var loginItemEnabled: Bool = LoginItem.isEnabled

    init() {
        let store = AppDefinitionStore()
        let registry = AppRegistry(store: store,
                                   executor: AppleScriptExecutor(),
                                   presence: WorkspacePresenceChecker())
        let targetManager = TargetManager(defaults: .standard, resolver: registry)

        self.store = store
        self.registry = registry
        self.targetManager = targetManager
        self.selectedTargetID = targetManager.selectedTargetID
        self.availableApps = store.allDefinitions()

        // Default the target to Spotify on first run if nothing chosen yet.
        if targetManager.selectedTargetID == nil {
            targetManager.selectedTargetID = BuiltInApps.spotify.id
            self.selectedTargetID = BuiltInApps.spotify.id
        }

        let tap = MediaKeyTap(handler: { [weak targetManager] key in
            targetManager?.handle(key)
        })
        self.tap = tap
        self.watchdog = TapWatchdog(tap: tap)
    }

    private func activateInput() { tap.start(); watchdog.start() }

    func startInput() {
        hasAccessibility = permissions.hasAccessibility
        if hasAccessibility { activateInput() } else { permissions.requestAccessibility() }
    }

    func refreshPermission() {
        hasAccessibility = permissions.hasAccessibility
        if hasAccessibility { activateInput() }
    }

    func setTarget(_ id: String) {
        selectedTargetID = id
        targetManager.selectedTargetID = id
    }

    func reloadApps() {
        availableApps = store.allDefinitions()
    }

    func setLoginItem(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        loginItemEnabled = LoginItem.isEnabled
    }

    // Volume helpers used by the sliders.
    func volume(for bundleID: String) -> Int? {
        registry.allApps().first { $0.bundleID == bundleID }?.currentVolume()
    }

    func setVolume(_ percent: Int, for bundleID: String) {
        registry.allApps().first { $0.bundleID == bundleID }?.setVolume(percent)
    }
}
