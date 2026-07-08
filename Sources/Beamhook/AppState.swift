import AppKit
import Combine
import os
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

    /// Serial off-main queue for user-initiated commands (media keys → target, volume
    /// steps, slider writes), driven via the target manager.
    private let scripting: ScriptRunner
    /// A SEPARATE serial queue for background/best-effort reads (the 1.5s play-state
    /// poll, a row's initial volume read). Kept apart from `scripting` so a slow read
    /// against a wedged target can never sit in front of a user's key press.
    private let pollRunner = ScriptRunner()
    /// Coalescing state for volume-key repeats (main-actor isolated → race-free):
    /// each key press bumps `pendingVolumeSteps`; a single drain task applies the
    /// net delta off-main, so a held key never stacks up blocked Apple-event sends.
    private var pendingVolumeSteps = 0
    private var volumeDrainInFlight = false

    @Published var selectedTargetID: String?
    @Published var availableApps: [AppDefinition]
    @Published var hasAccessibility: Bool = false
    @Published var loginItemEnabled: Bool = LoginItem.isEnabled
    /// Per-app opt-in for volume-key control. Absent (nil) means OFF — the volume
    /// keys are never taken over unless the user explicitly turns them on for that
    /// app. There is no automatic/silent hijack.
    @Published var volumeKeyOverride: [String: Bool] = [:]
    /// Latest known volume (0...100) per bundle id, so sliders update live.
    @Published var volumeByBundle: [String: Int] = [:]
    /// Whether the current output device's volume is adjustable. Informational only
    /// (drives a UI hint); it does NOT auto-enable the volume-key hijack.
    @Published private(set) var outputVolumeControllable: Bool = true

    let outputMonitor = AudioOutputMonitor()
    private var cancellables = Set<AnyCancellable>()
    private static let volumeOverrideKey = "volumeKeyOverride"
    private static let legacyVolumeHookKey = "volumeHookBundleIDs"
    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "HUD")

    init() {
        let scripting = ScriptRunner()
        self.scripting = scripting

        let store = AppDefinitionStore()
        let registry = AppRegistry(store: store,
                                   executor: AppleScriptExecutor(),
                                   presence: WorkspacePresenceChecker())
        let targetManager = TargetManager(defaults: .standard, resolver: registry, runner: scripting)

        self.store = store
        self.registry = registry
        self.targetManager = targetManager
        self.selectedTargetID = targetManager.selectedTargetID
        self.availableApps = store.allDefinitions()

        // Default the target to Spotify on first run — or if the persisted target no
        // longer resolves (e.g. a built-in was removed/renamed, like Swinsian), so a
        // stale selection can't silently strand the user with a dead target.
        if targetManager.selectedTargetID == nil || registry.app(withID: targetManager.selectedTargetID!) == nil {
            targetManager.selectedTargetID = BuiltInApps.spotify.id
            self.selectedTargetID = BuiltInApps.spotify.id
        }

        // The tap invokes its handler on the main queue. We can't capture `self` in a
        // closure until init finishes, so route through a box whose reference we set
        // at the end of init; it's only ever read/written on the main queue.
        let handlerBox = KeyHandlerBox()
        let tap = MediaKeyTap(handler: { key in
            MainActor.assumeIsolated { handlerBox.state?.handleKey(key) }
        })
        self.tap = tap
        self.watchdog = TapWatchdog(tap: tap)

        loadVolumeOverrides()
        outputMonitor.$outputVolumeControllable
            .receive(on: RunLoop.main)
            .sink { [weak self] controllable in
                // Informational only: controllability no longer auto-enables the
                // volume-key hijack. It just powers a UI hint suggesting the user
                // turn it on. (Silent auto-takeover was removed.)
                self?.outputVolumeControllable = controllable
            }
            .store(in: &cancellables)

        handlerBox.state = self
    }

    /// Entry point for a media key from the tap (already on the main queue). Volume
    /// keys are coalesced; transport keys are routed to the target off the main thread.
    func handleKey(_ key: MediaKey) {
        switch key {
        case .volumeUp:   nudgeVolume(up: true)
        case .volumeDown: nudgeVolume(up: false)
        default:          Task { await targetManager.route(key) }
        }
    }

    /// Guards the one-shot "hooked" HUD shown at launch, so re-activations
    /// (e.g. after wake / fast user switch) don't re-flash it.
    private var didAnnounceStartupHook = false

    private func activateInput() {
        tap.start()
        watchdog.start()
        outputMonitor.start()
        updateVolumeHijack()

        // On first activation, confirm the default hook (Spotify) — but only if
        // that app is actually running, so we don't flash it on a bare login.
        // Deferred a runloop turn so the app is fully up before we show a panel
        // (showing one mid-launch left it invisible).
        if !didAnnounceStartupHook {
            didAnnounceStartupHook = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let def = self.currentTargetDefinition()
                    let running = def.map { self.isRunning(bundleID: $0.bundleID) } ?? false
                    Self.log.info("startup hook: target=\(def?.displayName ?? "nil", privacy: .public) running=\(running)")
                    if let def, running {
                        HookHUD.shared.show(appName: def.displayName, bundleID: def.bundleID)
                    }
                }
            }
        }
    }

    private func currentTargetDefinition() -> AppDefinition? {
        guard let id = selectedTargetID else { return nil }
        return availableApps.first { $0.id == id }
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

    // Play/pause helpers used by the in-menu control. Both run their AppleScript
    // off the main thread so a slow/launching target can't freeze the popover. The
    // read runs on the poll runner, so a slow status read can't delay key commands.
    func isTargetPlaying() async -> Bool? {
        guard let id = selectedTargetID, let app = registry.app(withID: id) else { return nil }
        return await pollRunner.run { app.isPlaying() }
    }

    func togglePlayPauseTarget() { Task { await targetManager.route(.playPause) } }

    func setTarget(_ id: String) {
        selectedTargetID = id
        targetManager.selectedTargetID = id
        updateVolumeHijack()
        // Confirm the new hook with a centre-screen HUD (user-initiated, so always).
        if let def = currentTargetDefinition() {
            HookHUD.shared.show(appName: def.displayName, bundleID: def.bundleID)
        }
    }

    func reloadApps() {
        availableApps = store.allDefinitions()
    }

    func setLoginItem(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        loginItemEnabled = LoginItem.isEnabled
    }

    // Volume helpers used by the sliders (AppleScript runs off the main thread).
    // The initial read uses the poll runner (best-effort); the write uses the command
    // runner since it's a user action.
    func volume(for bundleID: String) async -> Int? {
        guard let app = registry.allApps().first(where: { $0.bundleID == bundleID }) else { return nil }
        return await pollRunner.run { app.currentVolume() }
    }

    func setVolume(_ percent: Int, for bundleID: String) {
        volumeByBundle[bundleID] = percent   // optimistic: the slider reflects it at once
        guard let app = registry.allApps().first(where: { $0.bundleID == bundleID }) else { return }
        Task { await scripting.run { app.setVolume(percent) } }
    }

    // MARK: - Volume-key coalescing

    /// Records one volume-key press and kicks off the drain if it isn't already
    /// running. Presses that arrive mid-flight just accumulate, so holding the key
    /// collapses into a few off-main round-trips instead of one blocked send each.
    private func nudgeVolume(up: Bool) {
        pendingVolumeSteps += up ? 1 : -1
        guard !volumeDrainInFlight else { return }
        volumeDrainInFlight = true
        Task { await drainVolumeSteps() }
    }

    private func drainVolumeSteps() async {
        defer { volumeDrainInFlight = false }
        while pendingVolumeSteps != 0 {
            let steps = pendingVolumeSteps
            pendingVolumeSteps = 0
            // Key the cache to the app adjustVolume actually acted on (resolved inside
            // its off-main closure), not a separately-read target that may have changed
            // across the await.
            if let result = await targetManager.adjustVolume(bySteps: steps) {
                volumeByBundle[result.bundleID] = result.volume
            }
        }
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

    private func loadVolumeOverrides() {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.volumeOverrideKey) as? [String: Bool] {
            volumeKeyOverride = dict
        } else if let legacy = UserDefaults.standard.array(forKey: Self.legacyVolumeHookKey) as? [String] {
            // Migrate the old "manually on" set → explicit `true` overrides.
            volumeKeyOverride = Dictionary(uniqueKeysWithValues: legacy.map { ($0, true) })
        }
    }

    /// On only when the user has explicitly opted this app in. Defaults to OFF —
    /// Beamhook never silently takes over the volume keys.
    func volumeKeysEnabled(bundleID: String) -> Bool {
        volumeKeyOverride[bundleID] ?? false
    }

    func setVolumeKeysEnabled(_ on: Bool, bundleID: String) {
        volumeKeyOverride[bundleID] = on
        UserDefaults.standard.set(volumeKeyOverride, forKey: Self.volumeOverrideKey)
        updateVolumeHijack()
    }

    /// The volume keys are hijacked for the target only when it exposes a scriptable
    /// volume AND the user has explicitly enabled it for that app.
    private func updateVolumeHijack() {
        let supported = targetManager.targetSupportsVolume
        let enabled = targetManager.targetBundleID.map { volumeKeysEnabled(bundleID: $0) } ?? false
        tap.volumeKeysHijacked = supported && enabled
    }
}

/// Bridges the media-key tap's handler to `AppState` without capturing `self` during
/// `AppState.init`. Only touched on the main queue, where the tap dispatches its
/// handler, so the plain `weak var` needs no further synchronization.
private final class KeyHandlerBox {
    weak var state: AppState?
}
