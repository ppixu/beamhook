import AppKit
import Combine
import BeamhookKit

@MainActor
final class AppState: ObservableObject {
    let store: AppDefinitionStore
    let registry: AppRegistry
    let targetManager: TargetManager
    let permissions = PermissionsManager()

    private let tap: MediaKeyTap
    private let watchdog: TapWatchdog
    private var permissionTimer: Timer?

    @Published var selectedTargetID: String?
    @Published var availableApps: [AppDefinition]
    @Published var hasAccessibility: Bool = false
    @Published var loginItemEnabled: Bool = LoginItem.isEnabled
    /// Bundle ids the user opted into hardware-volume-key control for.
    @Published var volumeHookedBundleIDs: Set<String> = []
    /// Whether the current output device's volume is adjustable (false → auto-hijack).
    @Published private(set) var outputVolumeControllable: Bool = true
    /// True when the volume keys are currently being routed to the target app.
    @Published private(set) var volumeKeysActive: Bool = false

    let outputMonitor = AudioOutputMonitor()
    private var cancellables = Set<AnyCancellable>()
    private static let volumeHookKey = "volumeHookBundleIDs"

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
            guard let targetManager else { return }
            switch key {
            case .volumeUp:   targetManager.stepVolume(up: true)
            case .volumeDown: targetManager.stepVolume(up: false)
            default:          targetManager.handle(key)
            }
        })
        self.tap = tap
        self.watchdog = TapWatchdog(tap: tap)

        volumeHookedBundleIDs = Set((UserDefaults.standard.array(forKey: Self.volumeHookKey) as? [String]) ?? [])
        outputMonitor.$outputVolumeControllable
            .receive(on: RunLoop.main)
            .sink { [weak self] controllable in
                self?.outputVolumeControllable = controllable
                self?.updateVolumeHijack()
            }
            .store(in: &cancellables)
    }

    private func activateInput() {
        tap.start()
        watchdog.start()
        outputMonitor.start()
        updateVolumeHijack()
    }

    func startInput() {
        hasAccessibility = permissions.hasAccessibility
        if hasAccessibility {
            activateInput()
        } else {
            permissions.requestAccessibility()
            startPermissionPolling()
        }
    }

    func refreshPermission() {
        hasAccessibility = permissions.hasAccessibility
        if hasAccessibility { activateInput() }
    }

    /// Polls the Accessibility permission so the UI flips automatically once the
    /// user grants it in System Settings — no relaunch or manual "Re-check".
    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if self.permissions.hasAccessibility {
                    self.hasAccessibility = true
                    self.activateInput()
                    timer.invalidate()
                    self.permissionTimer = nil
                }
            }
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // Play/pause helpers used by the in-menu control.
    func isTargetPlaying() -> Bool? {
        guard let id = selectedTargetID else { return nil }
        return registry.app(withID: id)?.isPlaying()
    }

    func togglePlayPauseTarget() { targetManager.handle(.playPause) }

    func setTarget(_ id: String) {
        selectedTargetID = id
        targetManager.selectedTargetID = id
        updateVolumeHijack()
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

    /// Can we control this app's volume via AppleScript? (Independent of whether
    /// it's running — reflects whether a matching definition supports volume.)
    func volumeScriptable(bundleID: String) -> Bool {
        registry.allApps().contains { $0.bundleID == bundleID && $0.supportsVolume }
    }

    /// Is an app with this bundle id currently running?
    func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    // MARK: - Volume-key hijacking

    func isVolumeHooked(bundleID: String) -> Bool {
        volumeHookedBundleIDs.contains(bundleID)
    }

    func setVolumeHooked(_ on: Bool, bundleID: String) {
        if on { volumeHookedBundleIDs.insert(bundleID) } else { volumeHookedBundleIDs.remove(bundleID) }
        UserDefaults.standard.set(Array(volumeHookedBundleIDs), forKey: Self.volumeHookKey)
        updateVolumeHijack()
    }

    /// The volume keys are hijacked for the target when it exposes a scriptable
    /// volume AND either the user enabled it for that app, or the current output
    /// device has no adjustable volume (so the keys would otherwise do nothing).
    private func updateVolumeHijack() {
        let supported = targetManager.targetSupportsVolume
        let manual = targetManager.targetBundleID.map { volumeHookedBundleIDs.contains($0) } ?? false
        let active = supported && (manual || !outputVolumeControllable)
        tap.volumeKeysHijacked = active
        if volumeKeysActive != active { volumeKeysActive = active }
    }
}
