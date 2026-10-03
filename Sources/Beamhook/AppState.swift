import AppKit
import Combine
import os
import BeamhookKit

/// Identifies one specific hooked playback destination at one point in time.
/// `revision` distinguishes Safari → Spotify → Safari from the original Safari
/// selection, so an old asynchronous result can never become current again.
struct PlaybackTargetContext: Hashable, Sendable {
    let targetID: String?
    let browserMediaID: String?
    let revision: UInt64
}

/// Tags one playback read with the local menu-state revision at which it began.
/// This is separate from `PlaybackTargetContext`: clicking play/pause does not
/// change the target, but it must still invalidate a poll already in flight.
struct PlaybackObservation: Equatable {
    fileprivate let context: PlaybackTargetContext
    fileprivate let revision: UInt64
}

/// Small, testable state machine for the menu's optimistic play/pause control.
/// Every mutation is tagged with its playback context; late polls and command
/// completions from an earlier hook are ignored.
struct PlaybackStatus {
    private(set) var context: PlaybackTargetContext?
    private(set) var isPlaying: Bool?
    private(set) var commandContext: PlaybackTargetContext?
    private var revision: UInt64 = 0

    var commandInFlight: Bool { commandContext != nil }

    mutating func reset(for context: PlaybackTargetContext) {
        revision &+= 1
        self.context = context
        isPlaying = nil
        commandContext = nil
    }

    func observation(for context: PlaybackTargetContext) -> PlaybackObservation? {
        guard self.context == context, commandContext == nil else { return nil }
        return PlaybackObservation(context: context, revision: revision)
    }

    mutating func accept(_ value: Bool?, from observation: PlaybackObservation) {
        guard context == observation.context,
              revision == observation.revision,
              commandContext == nil
        else { return }
        isPlaying = value
    }

    mutating func beginToggle(for context: PlaybackTargetContext) -> Bool {
        guard self.context == context, commandContext == nil else { return false }
        // A poll may already be awaiting AppleScript. Make its observation token
        // stale before optimistically changing the displayed state.
        revision &+= 1
        commandContext = context
        isPlaying = !(isPlaying == true)
        return true
    }

    mutating func finishToggle(
        succeeded: Bool,
        confirmedState: Bool?,
        previousState: Bool?,
        for context: PlaybackTargetContext
    ) {
        guard self.context == context, commandContext == context else { return }
        if succeeded {
            // Apps such as Spotify can briefly return their pre-command state even
            // after the play/pause Apple event has completed. That contradictory
            // value is not useful confirmation and caused play → pause → play
            // flicker. Keep the immediate optimistic state; the next fresh poll
            // remains authoritative if the command did not actually take effect.
            let expectedState = previousState.map { !$0 }
            if let confirmedState,
               expectedState == nil || confirmedState == expectedState {
                isPlaying = confirmedState
            }
        } else {
            isPlaying = previousState
        }
        commandContext = nil
    }
}

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
    /// A SEPARATE serial queue for background/best-effort work (the 1.5s play-state
    /// poll, initial volume reads, browser-selection bookkeeping). Kept apart from
    /// `scripting` so slow maintenance can never sit in front of a user's key press.
    private let pollRunner = ScriptRunner()
    private let browserMediaController = BrowserMediaController()
    /// Launches the hooked app for a play/pause press it would otherwise swallow.
    private let targetLauncher: TargetLauncher
    /// Per-browser playback recency used to keep the menu bounded to the three
    /// most relevant source tabs even when a browser has hundreds of media tabs.
    private var browserSourceRecency: [String: UInt64] = [:]
    private var playingBrowserSourceIDs = Set<String>()
    private var browserSourceRecencySequence: UInt64 = 0
    /// Coalescing state for volume-key repeats (main-actor isolated → race-free):
    /// each key press bumps `pendingVolumeSteps`; a single drain task applies the
    /// net delta off-main, so a held key never stacks up blocked Apple-event sends.
    private var pendingVolumeSteps = 0
    private var volumeDrainInFlight = false
    /// Same coalescing shape for ⌘+Mute: each press bumps `pendingMuteToggles`
    /// and a single drain task runs them one at a time. Unlike volume steps these
    /// aren't summed into a net delta — each toggle must fully complete (including
    /// `muteMemory.record`) before the next one reads `restoreVolume`, otherwise a
    /// quick double-press races the first toggle's Apple-event round trip and
    /// reads the fallback restore value instead of what the first press saved.
    private var pendingMuteToggles = 0
    private var muteToggleInFlight = false
    /// Pre-mute volumes, so ⌘+Mute can undo itself. Outlives sessions.
    private var muteMemory = MuteMemory()
    /// Non-nil while the source list is on screen — the spec's "volume session".
    /// While set, every volume key and ⌘+Mute follow its selection.
    private var volumeSession: VolumeSourceList? {
        didSet { tap.volumeSessionActive = volumeSession != nil }
    }
    /// The session's background refresh (volumes, browser tabs).
    private var volumeSessionRefresh: Task<Void, Never>?
    /// Whether the volume HUD is currently on screen. Guards against a ⌘↑/⌘↓
    /// that reaches the main queue just after the HUD hid and the picker tap
    /// was disarmed — without this, a stale key would open a session and
    /// re-show the HUD with no keyboard tap behind it.
    private var volumeHUDVisible = false
    /// Exists for the app's lifetime; only *installed* while a volume HUD is up.
    private lazy var sourcePickerTap = SourcePickerKeyTap { [weak self] key in
        MainActor.assumeIsolated { self?.handleSourcePickerKey(key) }
    }

    /// Incremented whenever the hooked app or selected browser source changes.
    /// It deliberately is not reset, even if the same destination is selected
    /// again, because outstanding work from its previous selection is stale.
    private var playbackContextRevision: UInt64 = 0
    @Published var selectedTargetID: String? {
        didSet {
            if selectedTargetID != oldValue { playbackContextRevision &+= 1 }
            updateMenuBarGlyph()
        }
    }
    @Published var availableApps: [AppDefinition]
    /// Bundle ids from `availableApps` that resolve to something on disk.
    /// Refreshed when the popover opens; see `refreshInstalledApps`.
    @Published private(set) var installedBundleIDs: Set<String> = []
    @Published var hasAccessibility: Bool = false
    /// Passive AppleScript reads are useful only while the user can see their
    /// results. Keeping the real popover lifecycle here prevents a newly launched
    /// target from causing an Automation permission prompt in the background.
    @Published private(set) var isMenuVisible: Bool = false
    @Published var loginItemEnabled: Bool = LoginItem.isEnabled
    /// Whether play/pause may start the hooked app when it isn't running.
    @Published var launchTargetOnPlay: Bool = LaunchOnPlayPreference.isEnabled(.standard)
    /// Whether a hooked play/pause press flashes the overlay.
    @Published var showPlayPauseHUD: Bool = PlayPauseHUDPreference.isEnabled(.standard)
    /// Per-app opt-in for volume-key control. Absent (nil) means OFF — the volume
    /// keys are never taken over unless the user explicitly turns them on for that
    /// app. There is no automatic/silent hijack.
    @Published var volumeKeyOverride: [String: Bool] = [:]
    /// Latest known volume (0...100) per bundle id, so sliders update live.
    @Published var volumeByBundle: [String: Int] = [:]
    @Published var browserMediaInjectionAvailable: Bool?
    @Published var browserTargetRunning: Bool?
    @Published var browserMediaCandidates: [BrowserMediaCandidate] = [] {
        didSet {
            updateMenuBarGlyph()
            updateTargetHasVolume()
        }
    }
    @Published var selectedBrowserMediaID: String? {
        didSet {
            if selectedBrowserMediaID != oldValue { playbackContextRevision &+= 1 }
            updateMenuBarGlyph()
            updateTargetHasVolume()
        }
    }
    /// Volume-controllable browser tabs for browsers whose Core Audio process
    /// currently has an output stream. Populated while the menu is visible, and
    /// also kept fresh by the volume-source picker's session refresh.
    @Published var activeBrowserMediaCandidates: [BrowserMediaCandidate] = []
    /// Whether the current output device's volume is adjustable. Informational only
    /// (drives a UI hint); it does NOT auto-enable the volume-key hijack.
    @Published private(set) var outputVolumeControllable: Bool = true
    /// Which template image the status item should show. Derived state — see
    /// `updateMenuBarGlyph()` for the inputs that keep it current.
    @Published private(set) var menuBarGlyph: MenuBarGlyph = .hook

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
                                   presser: AXMenuItemPresser(),
                                   presence: WorkspacePresenceChecker())
        let targetManager = TargetManager(defaults: .standard, resolver: registry, runner: scripting)
        self.targetLauncher = TargetLauncher(launcher: WorkspaceAppLauncher(), runner: scripting)

        self.store = store
        self.registry = registry
        self.targetManager = targetManager
        self.selectedTargetID = targetManager.selectedTargetID
        self.availableApps = store.allDefinitions()

        // Default the target to Spotify on first run — or if the persisted target no
        // longer resolves (e.g. a built-in was removed/renamed, like Swinsian), so a
        // stale selection can't silently strand the user with a dead target.
        let savedTargetIsMissing = targetManager.selectedTargetID.map {
            registry.app(withID: $0) == nil
        } ?? false
        if !targetManager.hasSavedSelection || savedTargetIsMissing {
            targetManager.selectedTargetID = BuiltInApps.spotify.id
            self.selectedTargetID = BuiltInApps.spotify.id
        }

        // The tap invokes its handler on the main queue. We can't capture `self` in a
        // closure until init finishes, so route through a box whose reference we set
        // at the end of init; it's only ever read/written on the main queue.
        let handlerBox = KeyHandlerBox()
        let tap = MediaKeyTap(
            handler: { key in
                MainActor.assumeIsolated { handlerBox.state?.handleKey(key) }
            },
            passthroughHandler: { key in
                MainActor.assumeIsolated { handlerBox.state?.handlePassedThroughKey(key) }
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
        // Seed this now rather than waiting for the first popover: the target menu
        // disables uninstalled apps, and an empty set would disable every one of
        // them if the menu were ever built before `setMenuVisible(true)` lands.
        refreshInstalledApps()
        configureBrowserTransportForPendingScan()
        // Explicit rather than left to the didSet above: property observers don't
        // fire for assignments made before `self` is fully initialized, so the
        // launch target would otherwise never reach the status item.
        updateMenuBarGlyph()
    }

    /// Entry point for a media key from the tap (already on the main queue). Volume
    /// keys are coalesced; transport keys are routed to the target off the main thread.
    func handleKey(_ key: MediaKey) {
        switch key {
        case .volumeUp:   nudgeVolume(up: true)
        case .volumeDown: nudgeVolume(up: false)
        case .mute:       toggleMute()
        default:
            guard let command = key.command else { return }
            if selectedTargetIsBrowser, browserMediaInjectionAvailable == true {
                guard let candidate = selectedBrowserMediaCandidate,
                      candidate.supportsTransport
                else { return }
                Task {
                    let performed = await self.performBrowserCommand(command, on: candidate)
                    guard performed, command == .playPause else { return }
                    await self.announcePlayPause()
                }
            } else {
                Task {
                    let routed = await self.targetManager.route(key)
                    guard command == .playPause else { return }
                    // route() returning false means nothing was delivered — no
                    // target, or the app isn't ready. Only play/pause gets the
                    // launch fallback: next/previous on a quit app have no
                    // meaningful target.
                    if routed {
                        await self.announcePlayPause()
                    } else {
                        await self.launchTargetAndPlay()
                    }
                }
            }
        }
    }

    /// A transport key the tap handed back to macOS (browser hooked, no tab
    /// control). macOS gives it to whichever app most recently owned the
    /// now-playing session — often not the hooked browser — so without feedback
    /// the press looks like Beamhook controlling the wrong app. Only play/pause
    /// gets the notice, matching the routed-press overlay, and the same
    /// preference governs both.
    func handlePassedThroughKey(_ key: MediaKey) {
        guard key == .playPause, showPlayPauseHUD,
              let browser = BrowserKind.target(id: selectedTargetID) else { return }
        let runningNow = isRunning(bundleID: browser.bundleID)
        let notice = PassthroughNotice.resolve(
            browserRunningNow: runningNow,
            scanSawBrowserRunning: browserTargetRunning,
            injectionAvailable: browserMediaInjectionAvailable)
        let name = currentTargetDefinition()?.displayName ?? browser.applicationName
        HookHUD.shared.showPassthrough(notice, appName: name)
        // A press against a stale picture (browser launched since the last
        // scan, or no scan yet) is also the moment to refresh it, so a browser
        // with tab JavaScript enabled converges to real tab control without
        // the menu ever being opened.
        if runningNow, browserTargetRunning != true {
            Task { await refreshBrowserMedia() }
        }
    }

    /// Flash the overlay for a play/pause press that reached the hooked app —
    /// the only feedback that the key went where the user hooked it rather than
    /// to whatever macOS would have picked.
    ///
    /// The resulting state is read on the command lane, queued directly behind
    /// the toggle that just ran, so the glyph shows what actually happened
    /// instead of a guess. That costs one round-trip before the overlay appears
    /// (the volume overlay already waits the same way); an app that reports no
    /// state at all still gets an overlay, just a direction-neutral one.
    private func announcePlayPause() async {
        guard showPlayPauseHUD, let def = currentTargetDefinition() else { return }
        let context = playbackTargetContext
        // A menu-driven target reports its state through the play/pause menu
        // item's own title, and that title can lag the press that changed it.
        // Reading it right away would sometimes draw the state we just left, so
        // let it settle first; scripted targets answer for themselves at once.
        if def.menuControl != nil {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard context == playbackTargetContext else { return }
        }
        let isPlaying = await confirmTargetPlaying(in: context)
        guard context == playbackTargetContext else { return }   // hook changed meanwhile
        HookHUD.shared.showPlayback(appName: def.displayName, isPlaying: isPlaying)
    }

    /// Start the hooked app, wait for it, then play. Browser targets are
    /// excluded: when a browser isn't running Beamhook hands the transport keys
    /// back to macOS (`refreshBrowserMedia`), and a freshly launched browser has
    /// no media tab to act on anyway.
    private func launchTargetAndPlay() async {
        guard launchTargetOnPlay,
              !selectedTargetIsBrowser,
              let id = selectedTargetID,
              let app = registry.app(withID: id) else { return }
        let displayName = availableApps.first { $0.id == id }?.displayName ?? app.displayName
        let outcome = await targetLauncher.launchAndPlay(
            app,
            isStillHooked: { [weak self] in self?.selectedTargetID == id },
            onLaunchStarted: { HookHUD.shared.showLaunching(appName: displayName) })
        // Only the two failure modes a user can actually report ("I pressed play
        // and nothing happened") are worth a log line; .skipped/.alreadyPlaying/
        // .played are all either silent by design or already visible via the HUD.
        switch outcome {
        case .notInstalled:
            Self.log.error("launch-on-play: \(displayName, privacy: .public) is not installed")
        case .timedOut:
            Self.log.error("launch-on-play: \(displayName, privacy: .public) timed out waiting for readiness")
        case .played:
            // Close the loop opened by the "Starting …" overlay: the app is up
            // and playing. No state read needed — the launcher only reports
            // .played once it has sent play to a ready app.
            if showPlayPauseHUD, selectedTargetID == id {
                HookHUD.shared.showPlayback(appName: displayName, isPlaying: true)
            }
        case .skipped, .alreadyPlaying:
            break
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
        HookHUD.shared.onVolumeVisibilityChange = { [weak self] visible in
            self?.volumeHUDVisibilityChanged(visible)
        }
        if selectedTargetIsBrowser {
            Task { await refreshBrowserMedia() }
        }

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
                        HookHUD.shared.show(appName: def.displayName,
                                            volumeKeysHijacked: self.tap.volumeKeysHijacked)
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
        // The app-target tests run the app as their host process, and that host
        // is built unsigned (`CODE_SIGNING_ALLOWED=NO`), so it can never hold the
        // Accessibility grant the real build has: every test run would call
        // `requestAccessibility()` and pop the system prompt at whoever is
        // running the suite. Worse, an unsigned process asking for the same
        // bundle id can leave the granted build's own entry stale. A test host
        // has nobody to serve, so it starts no input at all.
        guard !AppEnvironment.isRunningTests else { return }

        hasAccessibility = permissions.hasAccessibility
        // Developer-only, and inert unless the BHProbeBundleID default is set.
        MenuProbe.runIfRequested(accessibilityGranted: hasAccessibility)
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

    func setMenuVisible(_ visible: Bool) {
        isMenuVisible = visible
        if visible { refreshInstalledApps() }
    }

    /// Which of the listed apps are actually installed.
    ///
    /// Resolved in one pass when the popover opens rather than per menu item:
    /// the target menu rebuilds on every state change, and a LaunchServices
    /// lookup per app per rebuild is a lot of work to answer a question that
    /// only changes when the user installs something.
    private func refreshInstalledApps() {
        installedBundleIDs = Set(
            availableApps.map(\.bundleID).filter {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }
        )
    }

    func isInstalled(bundleID: String) -> Bool {
        installedBundleIDs.contains(bundleID)
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

    /// Snapshot used to tag every asynchronous playback read and command. The
    /// revision makes the context unique across A → B → A target switches.
    var playbackTargetContext: PlaybackTargetContext {
        PlaybackTargetContext(
            targetID: selectedTargetID,
            browserMediaID: selectedTargetIsBrowser ? selectedBrowserMediaID : nil,
            revision: playbackContextRevision
        )
    }

    // Play/pause helpers used by the in-menu control. Reads run off the main
    // thread and are accepted only while their exact target context is current.
    // Browser reads address the cached page-owned source directly instead of
    // rescanning every tab.
    func isTargetPlaying(in context: PlaybackTargetContext) async -> Bool? {
        await targetPlayingState(in: context, using: pollRunner)
    }

    /// Read immediately after a user command on the command lane. Since the toggle
    /// has already completed, this is queued directly behind it and authoritatively
    /// reconciles the optimistic icon without waiting for the periodic poll.
    func confirmTargetPlaying(in context: PlaybackTargetContext) async -> Bool? {
        await targetPlayingState(in: context, using: scripting)
    }

    private func targetPlayingState(
        in context: PlaybackTargetContext,
        using runner: ScriptRunner
    ) async -> Bool? {
        guard context == playbackTargetContext, let id = context.targetID else { return nil }

        let result: Bool?
        if let browser = BrowserKind.target(id: id) {
            guard browserMediaInjectionAvailable == true,
                  let candidate = browserMediaCandidates.first(where: {
                      $0.id == context.browserMediaID && $0.browser == browser
                  })
            else { return nil }
            result = await runner.run { [browserMediaController] in
                browserMediaController.isPlaying(candidate)
            }
        } else {
            guard let app = registry.app(withID: id) else { return nil }
            result = await runner.run { app.isPlaying() }
        }

        guard context == playbackTargetContext else { return nil }
        return result
    }

    func togglePlayPauseTarget(in context: PlaybackTargetContext) async -> Bool {
        guard context == playbackTargetContext else { return false }
        if selectedTargetIsBrowser, browserMediaInjectionAvailable != true {
            MediaKeyTap.postNativePlayPause()
            return true
        }
        if selectedTargetIsBrowser {
            guard let candidate = browserMediaCandidates.first(where: {
                      $0.id == context.browserMediaID
                  }),
                  candidate.supportsTransport
            else { return false }
            return await performBrowserCommand(.playPause, on: candidate)
        } else {
            guard let id = context.targetID, let app = registry.app(withID: id) else {
                return false
            }
            let performed = await scripting.run {
                guard app.isReady else { return false }
                app.perform(.playPause)
                return true
            }
            // Nothing delivered: the app isn't running. Kick off the launch
            // fallback without awaiting it — awaiting here would hold
            // commandInFlight (and the disabled button) for the whole launch
            // timeout, and would prevent the periodic poll from ever reporting
            // that playback started. Returning false immediately releases the
            // button; TargetLauncher's single-flight guard stops a second press
            // from starting a second launch.
            if !performed { Task { await launchTargetAndPlay() } }
            return performed
        }
    }

    /// Read and toggle a non-target app without changing where the hardware media
    /// keys are hooked. Reads stay on the low-priority polling queue; the user
    /// command uses the command queue.
    func isPlaying(bundleID: String) async -> Bool? {
        guard let app = registry.allApps().first(where: { $0.bundleID == bundleID }) else {
            return nil
        }
        return await pollRunner.run { app.isPlaying() }
    }

    func togglePlayPause(bundleID: String) async -> Bool {
        await targetManager.route(.playPause, toBundleID: bundleID)
    }

    /// Toggle one exact browser media source. BrowserMediaController resolves the
    /// stable page-owned source ID at action time, so tab reordering cannot make
    /// this control act on a different tab.
    func toggleBrowserPlayPause(_ candidate: BrowserMediaCandidate) async -> Bool {
        await performBrowserCommand(.playPause, on: candidate)
    }

    private func performBrowserCommand(
        _ command: MediaCommand,
        on candidate: BrowserMediaCandidate
    ) async -> Bool {
        await scripting.run { [browserMediaController] in
            browserMediaController.perform(command, on: candidate)
        }
    }

    func setTarget(_ id: String?) {
        selectedTargetID = id
        targetManager.selectedTargetID = id
        configureBrowserTransportForPendingScan()
        updateVolumeHijack()
        // Scan the hooked browser now instead of leaving it to the menu's
        // visible-poll loop: the popover can close before that loop fires,
        // which would strand a JS-enabled browser in macOS passthrough until
        // the menu is next opened. User-initiated, so a first-time Automation
        // prompt lands while the user is still looking at their choice.
        if selectedTargetIsBrowser {
            Task { await refreshBrowserMedia() }
        }
        // Confirm the new hook with a centre-screen HUD (user-initiated, so always).
        if let def = currentTargetDefinition() {
            HookHUD.shared.show(appName: def.displayName,
                                volumeKeysHijacked: tap.volumeKeysHijacked)
        }
    }

    var selectedTargetIsBrowser: Bool { BrowserKind.target(id: selectedTargetID) != nil }

    private var selectedBrowserMediaCandidate: BrowserMediaCandidate? {
        guard let id = selectedBrowserMediaID else { return nil }
        return browserMediaCandidates.first { $0.id == id }
    }

    /// Recompute the status-item glyph from the hooked target and, for a browser,
    /// the tab it is pointed at. Tabs are only scanned at launch, while the menu is
    /// open, and on an explicit tab choice — so a browser badge can lag a tab the
    /// user switched away from until the menu is next opened. Polling Apple events
    /// on a timer to close that gap would cost battery for a glanceable icon.
    private func updateMenuBarGlyph() {
        let host = selectedTargetIsBrowser ? selectedBrowserMediaCandidate?.host : nil
        menuBarGlyph = MenuBarGlyph.forTarget(id: selectedTargetID, browserHost: host)
    }

    /// Whether the hooked browser source can act on the transport keys. A call
    /// tab cannot: pausing a live MediaStream only freezes the user's view of the
    /// meeting. Anything else — including a non-browser target — can.
    var selectedBrowserSourceSupportsTransport: Bool {
        guard selectedTargetIsBrowser, browserMediaInjectionAvailable == true else {
            return true
        }
        return selectedBrowserMediaCandidate?.supportsTransport == true
    }

    /// Probe browser injection and enumerate media tabs. Called periodically while
    /// the menu is visible, so granting permission takes effect without relaunching.
    func refreshBrowserMedia() async {
        guard let browser = BrowserKind.target(id: selectedTargetID) else {
            browserMediaInjectionAvailable = nil
            browserTargetRunning = nil
            browserMediaCandidates = []
            selectedBrowserMediaID = nil
            tap.transportKeysHijacked = selectedTargetID != nil
            return
        }

        guard isRunning(bundleID: browser.bundleID) else {
            browserTargetRunning = false
            browserMediaInjectionAvailable = false
            browserMediaCandidates = []
            selectedBrowserMediaID = nil
            tap.transportKeysHijacked = false
            return
        }
        browserTargetRunning = true

        let scan = await pollRunner.run { [browserMediaController] in
            browserMediaController.scan(browser)
        }
        guard BrowserKind.target(id: selectedTargetID) == browser else { return }

        browserMediaInjectionAvailable = scan.injectionAvailable
        browserMediaCandidates = scan.candidates
        tap.transportKeysHijacked = scan.injectionAvailable

        guard scan.injectionAvailable, !scan.candidates.isEmpty else {
            selectedBrowserMediaID = nil
            return
        }

        // Older builds persisted window/tab indexes. Those are positions, not
        // identities, and can point at a different tab after any reordering.
        UserDefaults.standard.removeObject(forKey: "browserMediaSelection.\(browser.rawValue)")
        // An explicit user choice always wins — including a deliberately hooked
        // call tab, which the user may want for volume-key control. Failing that,
        // prefer a source that can actually act on the transport keys: a meeting
        // reports `isPlaying` for hours and would otherwise claim them silently.
        let chosen = scan.candidates.first(where: { $0.isSelected })
            ?? scan.candidates.first(where: { $0.isPlaying && $0.supportsTransport })
            ?? scan.candidates.first(where: { $0.supportsTransport })
            ?? scan.candidates.first(where: { $0.isPlaying })
            ?? scan.candidates.first
        selectedBrowserMediaID = chosen?.id
        if let chosen, !chosen.isSelected {
            // This is background bookkeeping, not a user command. Keep its required
            // all-tab marker cleanup off the command lane so it cannot delay a play
            // click for this browser or another app such as Spotify.
            _ = await pollRunner.run { [browserMediaController] in
                browserMediaController.select(chosen)
            }
        }
    }

    func selectBrowserMedia(_ id: String) {
        guard let candidate = browserMediaCandidates.first(where: { $0.id == id }) else { return }
        selectedBrowserMediaID = id
        Task {
            _ = await scripting.run { [browserMediaController] in
                browserMediaController.select(candidate)
            }
            await refreshBrowserMedia()
        }
    }

    /// Discover volume-controllable tabs in browsers that Core Audio currently
    /// reports as producing output. The selected browser's regular scan is reused
    /// when possible so opening the menu doesn't send duplicate Apple events.
    func refreshActiveBrowserMedia(bundleIDs: Set<String>) async {
        let browsers = BrowserKind.allCases.filter { bundleIDs.contains($0.bundleID) }
        guard !browsers.isEmpty else {
            activeBrowserMediaCandidates = []
            browserSourceRecency = [:]
            playingBrowserSourceIDs = []
            return
        }

        let activePrefixes = browsers.map { "\($0.rawValue):" }
        browserSourceRecency = browserSourceRecency.filter { entry in
            activePrefixes.contains { entry.key.hasPrefix($0) }
        }
        playingBrowserSourceIDs = Set(playingBrowserSourceIDs.filter { id in
            activePrefixes.contains { id.hasPrefix($0) }
        })

        var candidates: [BrowserMediaCandidate] = []
        for browser in browsers {
            guard !Task.isCancelled else { return }
            let scanCandidates: [BrowserMediaCandidate]
            if BrowserKind.target(id: selectedTargetID) == browser,
               browserMediaInjectionAvailable == true {
                scanCandidates = browserMediaCandidates
            } else {
                let scan = await pollRunner.run { [browserMediaController] in
                    browserMediaController.scan(browser)
                }
                guard !Task.isCancelled else { return }
                scanCandidates = scan.injectionAvailable ? scan.candidates : []
            }
            candidates.append(contentsOf: recentBrowserSources(
                from: scanCandidates,
                browser: browser
            ))
        }
        activeBrowserMediaCandidates = candidates
    }

    /// Rank a browser's sources with currently playing tabs first, then the selected
    /// target, then previously observed playback recency. Only three survive.
    /// Ranking decides *which* three; the rows are then shown in name order, so
    /// pausing a source can't make it jump past its neighbours under the cursor.
    private func recentBrowserSources(
        from candidates: [BrowserMediaCandidate],
        browser: BrowserKind
    ) -> [BrowserMediaCandidate] {
        let prefix = "\(browser.rawValue):"
        let candidateIDs = Set(candidates.map(\.id))
        browserSourceRecency = browserSourceRecency.filter { entry in
            !entry.key.hasPrefix(prefix) || candidateIDs.contains(entry.key)
        }

        let previouslyPlaying = Set(playingBrowserSourceIDs.filter { $0.hasPrefix(prefix) })
        let nowPlaying = Set(candidates.lazy.filter(\.isPlaying).map(\.id))
        for candidate in candidates where candidate.isPlaying
            && !previouslyPlaying.contains(candidate.id) {
            browserSourceRecencySequence &+= 1
            browserSourceRecency[candidate.id] = browserSourceRecencySequence
        }
        playingBrowserSourceIDs.subtract(previouslyPlaying)
        playingBrowserSourceIDs.formUnion(nowPlaying)

        let ranked = candidates
            .filter {
                $0.volume != nil
                    && ($0.isPlaying || $0.isSelected || browserSourceRecency[$0.id] != nil)
            }
            .sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
                if lhs.isSelected != rhs.isSelected { return lhs.isSelected }
                let lhsRecency = browserSourceRecency[lhs.id] ?? 0
                let rhsRecency = browserSourceRecency[rhs.id] ?? 0
                if lhsRecency != rhsRecency { return lhsRecency > rhsRecency }
                return lhs.id < rhs.id
            }
        let displayed = Array(ranked.prefix(3)).sorted { lhs, rhs in
            switch lhs.label.localizedStandardCompare(rhs.label) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.id < rhs.id
            }
        }

        // Keep only the recency needed for future three-row rankings.
        let retainedIDs = Set(displayed.map(\.id))
        browserSourceRecency = browserSourceRecency.filter { entry in
            !entry.key.hasPrefix(prefix) || retainedIDs.contains(entry.key)
        }
        return displayed
    }

    func setBrowserVolume(_ percent: Int, for candidate: BrowserMediaCandidate) {
        let clamped = min(max(percent, 0), 100)
        if let index = activeBrowserMediaCandidates.firstIndex(where: { $0.id == candidate.id }) {
            activeBrowserMediaCandidates[index].volume = clamped
        }
        if let index = browserMediaCandidates.firstIndex(where: { $0.id == candidate.id }) {
            browserMediaCandidates[index].volume = clamped
        }
        Task {
            _ = await scripting.run { [browserMediaController] in
                browserMediaController.setVolume(clamped, for: candidate)
            }
        }
    }

    private func configureBrowserTransportForPendingScan() {
        if selectedTargetID == nil {
            browserMediaInjectionAvailable = nil
            browserTargetRunning = nil
            browserMediaCandidates = []
            selectedBrowserMediaID = nil
            tap.transportKeysHijacked = false
        } else if selectedTargetIsBrowser {
            browserMediaInjectionAvailable = nil
            browserTargetRunning = nil
            browserMediaCandidates = []
            selectedBrowserMediaID = nil
            tap.transportKeysHijacked = false
        } else {
            tap.transportKeysHijacked = true
        }
    }

    func reloadApps() {
        availableApps = store.allDefinitions()
        refreshInstalledApps()
    }

    func setLoginItem(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        loginItemEnabled = LoginItem.isEnabled
    }

    func setLaunchTargetOnPlay(_ on: Bool) {
        launchTargetOnPlay = on
        LaunchOnPlayPreference.setEnabled(on, in: .standard)
    }

    func setShowPlayPauseHUD(_ on: Bool) {
        showPlayPauseHUD = on
        PlayPauseHUDPreference.setEnabled(on, in: .standard)
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
            let delta = steps * targetManager.volumeStep
            await changeVolume(of: currentVolumeSource) { $0 + delta }
        }
    }

    /// The session's selected source, otherwise the hooked target.
    private var currentVolumeSource: VolumeSource {
        volumeSession?.selected?.source ?? .hookedTarget
    }

    /// Read-modify-write one source's volume (AppleScript off main), update the
    /// caches the menu and HUD read, then show the HUD. Returns the change, or nil
    /// when nothing was changed (source gone, not ready, no volume).
    @discardableResult
    private func changeVolume(of source: VolumeSource,
                              _ transform: @escaping (Int) -> Int) async -> VolumeChange? {
        let change: VolumeChange?
        switch source {
        case .hookedTarget:
            // Capture what "hooked" meant at the moment this RMW started — by the
            // time it returns, the user may have switched tabs or re-hooked, and
            // writing into today's selection with yesterday's result would land
            // one source's volume on another's row.
            let wasBrowser = selectedTargetIsBrowser
            let browserTabID = selectedBrowserMediaID
            change = await targetManager.updateVolume(transform)
            if let change {
                volumeByBundle[change.bundleID] = change.volume
                if wasBrowser, let id = browserTabID,
                   let index = browserMediaCandidates.firstIndex(where: { $0.id == id }),
                   browserMediaCandidates[index].browser.bundleID == change.bundleID {
                    browserMediaCandidates[index].volume = change.volume
                }
            }
        case .app(let bundleID):
            change = await targetManager.updateVolume(ofBundleID: bundleID, transform)
            if let change { volumeByBundle[bundleID] = change.volume }
        case .browserTab(let id):
            if let candidate = browserCandidate(id: id), let current = candidate.volume {
                let next = min(100, max(0, transform(current)))
                setBrowserVolume(next, for: candidate)   // updates both caches, sends off main
                change = VolumeChange(bundleID: candidate.browser.bundleID, previous: current, volume: next)
            } else {
                change = nil
            }
        }
        guard let change else { return nil }
        if volumeSession != nil {
            showVolumeSessionHUD()
        } else {
            let appName = availableApps.first { $0.bundleID == change.bundleID }?.displayName
                ?? change.bundleID
            HookHUD.shared.showVolume(appName: appName, percent: change.volume,
                                      systemVolumeHint: tap.volumeKeysHijacked)
        }
        return change
    }

    private func browserCandidate(id: String) -> BrowserMediaCandidate? {
        activeBrowserMediaCandidates.first { $0.id == id }
            ?? browserMediaCandidates.first { $0.id == id }
    }

    /// ⌘+Mute: silence the current volume source, or put back what muting took.
    /// Queued like `nudgeVolume`/`drainVolumeSteps`, so a quick double-press can't
    /// read `restoreVolume` before the first press has recorded it.
    private func toggleMute() {
        pendingMuteToggles += 1
        guard !muteToggleInFlight else { return }
        muteToggleInFlight = true
        Task { await drainMuteToggles() }
    }

    private func drainMuteToggles() async {
        defer { muteToggleInFlight = false }
        while pendingMuteToggles > 0 {
            pendingMuteToggles -= 1
            await performMuteToggle()
        }
    }

    /// One full mute toggle: source, key, and the restore value are all resolved
    /// here — at the moment this toggle actually runs — not when it was queued,
    /// so it always sees the previous toggle's recorded result.
    private func performMuteToggle() async {
        let source = currentVolumeSource
        let key = muteMemoryKey(for: source)
        let restore = muteMemory.restoreVolume(for: key)
        guard let change = await changeVolume(of: source, {
            MuteMemory.toggled(from: $0, restore: restore)
        }) else { return }
        muteMemory.record(sourceID: key, previous: change.previous, new: change.volume)
    }

    /// Mute memory follows the thing actually silenced, not the "hooked target"
    /// role — re-hooking another app must not make it inherit a restore value.
    private func muteMemoryKey(for source: VolumeSource) -> String {
        guard source == .hookedTarget else { return source.id }
        if selectedTargetIsBrowser, let id = selectedBrowserMediaID {
            return VolumeSource.browserTab(id: id).id
        }
        return VolumeSource.app(bundleID: targetManager.targetBundleID ?? "").id
    }

    // MARK: - Volume source picker

    private func volumeHUDVisibilityChanged(_ visible: Bool) {
        volumeHUDVisible = visible
        if visible {
            sourcePickerTap.arm()
        } else {
            sourcePickerTap.disarm()
            volumeSessionRefresh?.cancel()
            volumeSessionRefresh = nil
            volumeSession = nil
        }
    }

    /// ⌘↑/⌘↓ while a volume HUD is up. The first press opens the session (the
    /// HUD grows into the list) and moves the selection one row.
    private func handleSourcePickerKey(_ key: SourcePickerKey) {
        // A key can reach the main queue just after the HUD hid and the picker
        // tap was disarmed. Ignore it — otherwise a stale key would open a
        // session and re-show the HUD with no keyboard tap behind it.
        guard volumeHUDVisible else { return }
        if volumeSession == nil {
            let audible = audibleBundleIDs()
            volumeSession = VolumeSourceList(target: hookedVolumeEntry(),
                                             apps: playingVolumeApps(audible: audible),
                                             tabs: browserVolumeTabs())
            startVolumeSessionRefresh(audible: audible)
        }
        switch key {
        case .previous: volumeSession?.selectPrevious()
        case .next: volumeSession?.selectNext()
        }
        showVolumeSessionHUD()
    }

    private func showVolumeSessionHUD() {
        guard let session = volumeSession else { return }
        let rows = session.entries.map {
            HookHUD.SourceRow(name: $0.name, percent: currentVolume(of: $0.source))
        }
        HookHUD.shared.showVolumeSources(rows, selectedIndex: session.selectedIndex)
    }

    /// Cached volume for a row; the session refresh fills these in.
    private func currentVolume(of source: VolumeSource) -> Int? {
        switch source {
        case .hookedTarget:
            if selectedTargetIsBrowser, let volume = selectedBrowserMediaCandidate?.volume {
                return volume
            }
            return targetManager.targetBundleID.flatMap { volumeByBundle[$0] }
        case .app(let bundleID):
            return volumeByBundle[bundleID]
        case .browserTab(let id):
            return browserCandidate(id: id)?.volume
        }
    }

    private func hookedVolumeEntry() -> VolumeSourceEntry? {
        guard tap.targetHasVolume, let def = currentTargetDefinition() else { return nil }
        let name = selectedTargetIsBrowser
            ? (selectedBrowserMediaCandidate?.label ?? def.displayName)
            : def.displayName
        return VolumeSourceEntry(source: .hookedTarget, name: name)
    }

    /// Bundle ids with a live audio output stream. Before macOS 14.2 there's no
    /// per-process audio API, so every running supported browser stands in (its
    /// tabs are still scanned) and no other apps are offered.
    private func audibleBundleIDs() -> Set<String> {
        if #available(macOS 14.2, *) {
            let monitor = AudioProcessMonitor()
            monitor.refresh()
            return Set(monitor.playingApps.map(\.bundleID))
        }
        return Set(BrowserKind.allCases.map(\.bundleID).filter { isRunning(bundleID: $0) })
    }

    /// Other playing apps Beamhook can script the volume of, by name. The hooked
    /// target is row 1 already, and browsers contribute tabs instead.
    private func playingVolumeApps(audible: Set<String>) -> [VolumeSourceEntry] {
        let targetBundleID = targetManager.targetBundleID
        return audible
            .filter { $0 != targetBundleID
                && BrowserKind.browser(bundleID: $0) == nil
                && volumeScriptable(bundleID: $0) }
            .map { bundleID in
                VolumeSourceEntry(source: .app(bundleID: bundleID),
                                  name: availableApps.first { $0.bundleID == bundleID }?.displayName
                                      ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Tabs with a volume from the last active-browser scan, minus the hooked tab.
    private func browserVolumeTabs() -> [VolumeSourceEntry] {
        let hookedTabID = selectedTargetIsBrowser ? selectedBrowserMediaID : nil
        return activeBrowserMediaCandidates
            .filter { $0.volume != nil && $0.id != hookedTabID }
            .map { VolumeSourceEntry(source: .browserTab(id: $0.id),
                                     name: "\($0.label) · \($0.browser.applicationName)") }
    }

    /// Read every row's volume and scan browser tabs, off main, then redraw. The
    /// list shows immediately from caches; this only fills it in.
    private func startVolumeSessionRefresh(audible: Set<String>) {
        volumeSessionRefresh?.cancel()
        volumeSessionRefresh = Task { [weak self] in
            guard let self else { return }
            for entry in self.volumeSession?.entries ?? [] {
                guard !Task.isCancelled else { return }
                let bundleID: String?
                switch entry.source {
                case .hookedTarget:
                    bundleID = self.selectedTargetIsBrowser ? nil : self.targetManager.targetBundleID
                case .app(let id):
                    bundleID = id
                case .browserTab:
                    bundleID = nil
                }
                if let bundleID, let volume = await self.volume(for: bundleID) {
                    self.volumeByBundle[bundleID] = volume
                }
            }
            guard !Task.isCancelled, self.volumeSession != nil else { return }
            self.showVolumeSessionHUD()

            await self.refreshActiveBrowserMedia(bundleIDs: audible)
            guard !Task.isCancelled, self.volumeSession != nil else { return }
            self.volumeSession?.replace(target: self.hookedVolumeEntry(),
                                        apps: self.playingVolumeApps(audible: audible),
                                        tabs: self.browserVolumeTabs())
            self.showVolumeSessionHUD()
        }
    }

    /// Can we control this app's volume via AppleScript? (Independent of whether
    /// it's running — reflects whether a matching definition supports volume.)
    func volumeScriptable(bundleID: String) -> Bool {
        registry.allApps().contains { $0.bundleID == bundleID && $0.supportsVolume }
    }

    /// Why a volume read came back empty. Only called after one has failed, so it
    /// can afford the extra permission check — and that check is what separates an
    /// app with no volume control from one macOS is blocking us from reaching.
    func volumeAvailability(for bundleID: String) async -> VolumeAvailability {
        let supportsVolume = volumeScriptable(bundleID: bundleID)
        guard supportsVolume else { return .systemVolumeOnly }
        let allowed = await pollRunner.run { AutomationPermission.isAllowed(bundleID: bundleID) }
        return VolumeAvailability.resolve(definitionSupportsVolume: true,
                                          readSucceeded: false,
                                          automationAllowed: allowed)
    }

    /// Is an app with this bundle id currently running?
    func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Bring a listed app to the front. Deliberately unlike `TargetLauncher`,
    /// which starts a quit app *without* stealing focus because a media key must
    /// never move the user: this is a click asking to go there. Every row in the
    /// popover names a running app, so a miss here means it quit since the last
    /// refresh — the row is about to disappear anyway, so do nothing.
    func activate(bundleID: String) {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first?
            .activate()
    }

    /// Land the user on one exact browser tab. The tab is raised on the script
    /// queue, off main like every other AppleScript, and then the browser is
    /// activated whether or not that succeeded — someone who asked for Safari's
    /// YouTube tab is better served by arriving in Safari than by nothing
    /// happening when the tab has since closed.
    func focusBrowserSource(_ candidate: BrowserMediaCandidate) async {
        await scripting.run { [browserMediaController] in
            _ = browserMediaController.focus(candidate)
        }
        activate(bundleID: candidate.browser.bundleID)
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
        VolumeKeyRouting.isEnabled(for: bundleID, preferences: volumeKeyOverride)
    }

    func setVolumeKeysEnabled(_ on: Bool, bundleID: String) {
        volumeKeyOverride[bundleID] = on
        UserDefaults.standard.set(volumeKeyOverride, forKey: Self.volumeOverrideKey)
        updateVolumeHijack()
        if on,
           tap.volumeKeysHijacked,
           let def = currentTargetDefinition(),
           def.bundleID == bundleID {
            HookHUD.shared.show(appName: def.displayName, volumeKeysHijacked: true)
        }
    }

    /// The volume keys are hijacked for the target only when it exposes a scriptable
    /// volume AND the user has explicitly enabled it for that app.
    private func updateVolumeHijack() {
        tap.volumeKeysHijacked = VolumeKeyRouting.shouldHijack(
            targetBundleID: targetManager.targetBundleID,
            targetSupportsVolume: targetManager.targetSupportsVolume,
            preferences: volumeKeyOverride
        )
        updateTargetHasVolume()
    }

    /// Whether ⌘+Volume / ⌘+Mute have something to act on. A browser target only
    /// does once a scan found a tab with a volume; until then the keys stay with
    /// macOS rather than being swallowed for nothing.
    private func updateTargetHasVolume() {
        let browserReady = !selectedTargetIsBrowser || selectedBrowserMediaCandidate?.volume != nil
        tap.targetHasVolume = targetManager.targetSupportsVolume && browserReady
    }
}

/// Bridges the media-key tap's handler to `AppState` without capturing `self` during
/// `AppState.init`. Only touched on the main queue, where the tap dispatches its
/// handler, so the plain `weak var` needs no further synchronization.
private final class KeyHandlerBox {
    weak var state: AppState?
}
