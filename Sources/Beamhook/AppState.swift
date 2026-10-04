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
    var quickTimeMovieID: String? = nil
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
    static func symbol(for playing: Bool?) -> String {
        guard let playing else { return "playpause.fill" }
        return playing ? "pause.fill" : "play.fill"
    }

    static func actionLabel(for playing: Bool?, name: String) -> String {
        guard let playing else { return "Play or pause \(name) (playback state unavailable)" }
        return "\(playing ? "Pause" : "Play") \(name)"
    }

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
        isPlaying = isPlaying.map { !$0 }
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
    // Discovery must not wait behind row polling (or delay user commands).
    private let menuPlaybackRunner = ScriptRunner()
    private let metadataRunner = ScriptRunner()
    private let browserMediaController: BrowserMediaController
    private var menuBrowserHookRevision: UInt64 = 0
    private let quickTimeController = QuickTimeMediaController()
    @Published private(set) var quickTimeMovies: [QuickTimeMovie] = []
    @Published private(set) var quickTimeScanFailed = false
    @Published private(set) var selectedQuickTimeMovieID: String? {
        didSet {
            if selectedQuickTimeMovieID != oldValue { playbackContextRevision &+= 1 }
        }
    }
    var selectedTargetIsQuickTime: Bool { selectedTargetID == BuiltInApps.quickTime.id }

    func selectQuickTimeMovie(_ id: String) {
        guard quickTimeMovies.contains(where: { $0.id == id }) else { return }
        selectedQuickTimeMovieID = id
    }

    private static let quickTimeLog = Logger(subsystem: "com.github.ppixu.beamhook", category: "QuickTime")

    func refreshQuickTimeMovies() async {
        guard selectedTargetIsQuickTime else { return }
        let context = playbackTargetContext
        let movies = await pollRunner.run { [quickTimeController] in quickTimeController.scan() }
        guard context == playbackTargetContext else {
            Self.quickTimeLog.info("Movie scan discarded: playback target changed during the scan")
            return
        }
        Self.quickTimeLog.info("Movie scan: \(movies.map { "\($0.count) movies" } ?? "failed", privacy: .public)")
        quickTimeScanFailed = movies == nil
        quickTimeMovies = movies ?? []
        if !quickTimeMovies.contains(where: { $0.id == selectedQuickTimeMovieID }) {
            selectedQuickTimeMovieID = quickTimeMovies.first(where: { $0.isPlaying })?.id
                ?? quickTimeMovies.first?.id
        }
    }

    private func toggleQuickTimeMovie(_ movie: QuickTimeMovie) async -> Bool {
        await scripting.run { [quickTimeController] in quickTimeController.toggle(movie) }
    }
    /// Launches the hooked app for a play/pause press it would otherwise swallow.
    private let targetLauncher: TargetLauncher
    /// Per-browser playback recency used to keep the menu bounded to the three
    /// most relevant source tabs even when a browser has hundreds of media tabs.
    private var browserSourceRecency: [String: Date] = [:]
    private static let browserSourceRetention: TimeInterval = 2 * 60 * 60
    /// Volume-key presses for one source, coalesced into a net step count.
    private struct VolumeStepBatch {
        let source: VolumeSource
        /// The picker session the presses were made in (nil outside one). A
        /// batch from a session that has since ended is dropped, not redirected.
        let session: UInt64?
        var steps: Int
    }
    /// Coalescing state for volume-key repeats (main-actor isolated → race-free):
    /// each key press bumps the last pending batch for the same source and
    /// session, or starts a new one; a single drain task applies each batch's
    /// net delta off-main, so a held key never stacks up blocked Apple-event
    /// sends. The source is captured at press time, so presses for one row can
    /// never land on another.
    private var pendingVolumeBatches: [VolumeStepBatch] = []
    private var volumeDrainInFlight = false
    /// One mute press inside a picker session, with its source captured at
    /// press time.
    private struct SessionMuteToggle {
        let source: VolumeSource
        let session: UInt64
    }
    /// Same queue shape for mute inside a picker session, but unlike volume
    /// steps these aren't summed — each toggle must fully complete (including
    /// `muteMemory.record`) before the next one reads `restoreVolume`, otherwise
    /// a quick double-press races the first toggle's Apple-event round trip and
    /// reads the fallback restore value instead of what the first press saved.
    private var pendingMuteToggles: [SessionMuteToggle] = []
    private var muteToggleInFlight = false
    /// Incremented each time a picker session opens; identifies the session
    /// queued key work belongs to.
    private var volumeSessionGeneration: UInt64 = 0
    /// Tab levels the keys wrote during the current session, by tab id. A
    /// browser scan taken before a key's send can land after it and replace
    /// the caches wholesale; these win over scanned values until the session
    /// ends, so the next press steps from what was actually set.
    private var sessionTabVolumes: [String: Int] = [:]
    /// Pre-mute volumes of browser tabs, so a session's ⌘+Mute can undo itself.
    /// Apps use the process-tap mute instead. Outlives sessions.
    private var muteMemory = MuteMemory()
    /// Non-nil while the source list is on screen — the spec's "volume session".
    /// While set, every volume key and ⌘+Mute follow its selection.
    private var volumeSession: VolumeSourceList? {
        didSet {
            updateVolumeSessionRouting()
            updateMeterWatchlist()
        }
    }
    private var menuMeterWatchlist: Set<String> = []
    @Published var showAllMenuApps = false
    private var recentAppPlayback: [String: Date] = [:]

    func recordAppPlayback(_ bundleIDs: Set<String>, now: Date = Date()) {
        for id in bundleIDs { recentAppPlayback[id] = now }
    }

    func recentlyActiveAppIDs(now: Date = Date()) -> Set<String> {
        recentAppPlayback = recentAppPlayback.filter { now.timeIntervalSince($0.value) < 2 * 60 * 60 }
        // A displayed tab also keeps its browser parent visible. In particular,
        // an explicitly selected paused tab can survive without playback history;
        // the overlay already includes that parent when grouping its tab rows.
        let tabParents = Set(activeBrowserMediaCandidates.filter { $0.volume != nil }.map { $0.browser.bundleID })
        return Set(recentAppPlayback.keys).union(audibleApps)
            .union(recentBrowserBundleIDs(now: now)).union(tabParents)
    }

    /// Poll every running player, including those filtered out of the shortlist.
    /// Row-owned polling alone cannot discover a silent/muted video: its row
    /// would need to be visible before playback could make it visible.
    /// The optional app list allows discovery to be tested without live players.
    func refreshMenuPlayback(apps: [MediaApp]? = nil) async {
        guard isMenuVisible, !Task.isCancelled else { return }
        for app in apps ?? registry.allApps() {
            guard isMenuVisible, !Task.isCancelled else { return }
            // Browser sources have their own tab discovery and recency tracking.
            guard BrowserKind.browser(bundleID: app.bundleID) == nil else { continue }
            let playing = await menuPlaybackRunner.run {
                guard app.isReady else { return nil as Bool? }
                return app.isPlaying()
            }
            guard isMenuVisible, !Task.isCancelled else { return }
            if let playing {
                notePolledPlayback(bundleID: app.bundleID, playing: playing)
            }
        }
    }

    func recentAppRows(_ rows: [PlayingApp], now: Date = Date()) -> [PlayingApp] {
        let recent = recentlyActiveAppIDs(now: now)
        return rows.filter { recent.contains($0.bundleID) || $0.bundleID == targetManager.targetBundleID }
    }

    /// The session's background refresh (volumes, browser tabs).
    private var volumeSessionRefresh: Task<Void, Never>?
    private var spotifyTrackRefresh: Task<Void, Never>?
    @Published private(set) var spotifyTrack = ""
    /// Whether the volume HUD is currently on screen. Guards against a ⌘↑/⌘↓
    /// that reaches the main queue just after the HUD hid and the picker tap
    /// was disarmed — without this, a stale key would open a session and
    /// re-show the HUD with no keyboard tap behind it.
    private var hudVisible = false
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
    /// Synchronously close the menu before the picker measures its position.
    var dismissMenuForOverlay: (() -> Void)?
    @Published var loginItemEnabled: Bool = LoginItem.isEnabled
    /// Whether play/pause may start the hooked app when it isn't running.
    @Published var launchTargetOnPlay: Bool = LaunchOnPlayPreference.isEnabled(.standard)
    /// Whether a hooked play/pause press flashes the overlay.
    @Published var showPlayPauseHUD: Bool = PlayPauseHUDPreference.isEnabled(.standard)
    @Published var skipOnPodcasts: Bool = TrackKeyPreference.skipOnPodcasts(.standard)
    @Published var alwaysSkip: Bool = TrackKeyPreference.alwaysSkip(.standard)
    /// Whether ⌘ + a volume key reaches the hooked app when the plain keys don't.
    @Published var commandVolumeRouting: Bool = CommandVolumePreference.isEnabled(.standard)
    /// Whether the per-app mute buttons are shown. Default ON; the System Audio
    /// Recording permission behind them is asked for once, at first activation
    /// (see `requestMutePermissionOnce`).
    @Published var perAppMuteEnabled: Bool = PerAppMutePreference.isEnabled(.standard)
    /// Mirror of the mute controller's muted set, so rows observing AppState
    /// re-render on a mute without each observing the controller separately.
    @Published private(set) var mutedApps: Set<String> = [] {
        didSet { updateMenuBarGlyph() }
    }
    /// Mirror of the controller's permission verdict; nil until a tap has run.
    @Published private(set) var mutePermissionGranted: Bool?
    /// Mirror of the controller's live audibility meter (see setMeterWatchlist).
    @Published private(set) var audibleApps: Set<String> = []
    /// Per-app opt-in for volume-key control. Absent (nil) means OFF — the volume
    /// keys are never taken over unless the user explicitly turns them on for that
    /// app. There is no automatic/silent hijack.
    @Published var volumeKeyOverride: [String: Bool] = [:]
    /// Latest known volume (0...100) per bundle id, so sliders update live.
    @Published var volumeByBundle: [String: Int] = [:]
    @Published private(set) var processVolumeLevels: [String: Int] = [:]
    @Published private(set) var processVolumeErrors: [String: String] = [:]
    @Published var browserMediaInjectionAvailable: Bool?
    @Published var browserTargetRunning: Bool?
    @Published var browserMediaCandidates: [BrowserMediaCandidate] = [] {
        didSet {
            updateMenuBarGlyph()
            // Never mutate this property from here: on a @Published property an
            // inout write inside its own didSet re-fires the didSet. Scanned
            // data is patched with the session's tab levels before assignment
            // (see `applyingSessionTabVolumes`).
            updateVolumeRouting()
        }
    }
    @Published var selectedBrowserMediaID: String? {
        didSet {
            if selectedBrowserMediaID != oldValue { playbackContextRevision &+= 1 }
            updateMenuBarGlyph()
            updateVolumeRouting()
        }
    }
    /// Volume-controllable browser tabs for sounding or recently playing browsers. Populated while the menu is visible, and
    /// also kept fresh by the volume-source picker's session refresh.
    @Published var activeBrowserMediaCandidates: [BrowserMediaCandidate] = [] {
        didSet {
            // Read-only here for the same reason as `browserMediaCandidates`.
            if volumeSession != nil { updateVolumeSessionRouting() }
        }
    }
    /// Whether the current output device's volume is adjustable. Informational only
    /// (drives a UI hint); it does NOT auto-enable the volume-key hijack.
    @Published private(set) var outputVolumeControllable: Bool = true
    /// Which template image the status item should show. Derived state — see
    /// `updateMenuBarGlyph()` for the inputs that keep it current.
    @Published private(set) var menuBarGlyph: MenuBarGlyph = .hook
    /// The hooked app is process-tap muted right now; the status item draws its
    /// glyph with a slash through it. Derived alongside `menuBarGlyph`.
    @Published private(set) var menuBarMuted = false

    let outputMonitor = AudioOutputMonitor()
    /// Created on first use (which also keeps it off macOS 14.0/14.1, where the
    /// tap API doesn't exist). Typed AnyObject because a stored property can't
    /// carry the @available(macOS 14.2, *) the class needs.
    private var muteControllerStorage: AnyObject?
    private var cancellables = Set<AnyCancellable>()
    /// Workspace launch/terminate observers; see `observeTargetPresence()`.
    private var workspaceObservers: [NSObjectProtocol] = []
    private static let volumeOverrideKey = "volumeKeyOverride"
    private static let legacyVolumeHookKey = "volumeHookBundleIDs"
    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "HUD")

    init(browserMediaController: BrowserMediaController = BrowserMediaController()) {
        self.browserMediaController = browserMediaController
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
            },
            commandVolumeHandler: {
                MainActor.assumeIsolated { handlerBox.state?.showVolumePicker() }
            },
            pickerPlayPauseHandler: {
                MainActor.assumeIsolated { handlerBox.state?.togglePickerPlayback() }
            })
        self.tap = tap
        self.watchdog = TapWatchdog(tap: tap)

        loadVolumeOverrides()
        if !AppEnvironment.isRunningTests, PerAppMutePreference.isEnabled(.standard), #available(macOS 14.2, *) {
            // No permission probe here: this runs before Accessibility is
            // settled. `activateInput` asks once, on the first activation, so
            // a fresh install sees Accessibility first and System Audio
            // Recording second rather than both dialogs at once.
            muteController.start()
        }
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
        observeTargetPresence()
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
        case .mute:       handleMuteKey()
        default:
            guard let command = key.command else { return }
            if selectedTargetIsQuickTime {
                if command == .playPause {
                    let context = playbackTargetContext
                    Task {
                        if await togglePlayPauseTarget(in: context) { await announcePlayPause() }
                    }
                } else if skipOnPodcasts {
                    // A movie has no next to lose, so its track keys always skip.
                    Task { await seekQuickTime(by: command == .next ? 15 : -15) }
                }
            } else if selectedTargetIsBrowser, browserMediaInjectionAvailable == true {
                guard let candidate = selectedBrowserMediaCandidate,
                      candidate.supportsTransport
                else { return }
                Task {
                    if command != .playPause, await self.skipBrowserIfPodcast(command, on: candidate) {
                        return
                    }
                    let performed = await self.performBrowserCommand(command, on: candidate)
                    guard performed, command == .playPause else { return }
                    await self.announcePlayPause()
                }
            } else {
                Task {
                    let outcome = await self.targetManager.routeKey(key)
                    if case .skipped(let seconds, let byMenu) = outcome {
                        self.announceSkip(seconds: seconds, byMenu: byMenu)
                        return
                    }
                    guard command == .playPause else { return }
                    // routeKey returning .notDelivered means nothing was delivered —
                    // no target, or the app isn't ready. Only play/pause gets the
                    // launch fallback: next/previous on a quit app have no
                    // meaningful target.
                    if outcome != .notDelivered {
                        await self.announcePlayPause()
                    } else if let id = self.selectedTargetID,
                              let app = self.registry.app(withID: id), !app.isReady {
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
        guard let def = currentTargetDefinition() else { return }
        let context = playbackTargetContext
        // The press is the freshest knowledge there is: flip the last known
        // state now, so the speaker animation and the row buttons react to the
        // key rather than to the read that follows it.
        let previous = playbackHint(for: def.bundleID)
        if let previous { notePlayback(bundleID: def.bundleID, playing: !previous) }
        // Confirmed regardless of the overlay setting: the settled read also
        // corrects the hint if the guess above was wrong.
        let isPlaying = await confirmTargetPlaying(in: context, after: previous)
        guard showPlayPauseHUD, context == playbackTargetContext else { return }
        showPlaybackHUD(appName: def.displayName, bundleID: def.bundleID, isPlaying: isPlaying)
    }

    /// Same gate as the play/pause overlay: both confirm a transport key.
    private func announceSkip(seconds: Int, byMenu: Bool) {
        guard showPlayPauseHUD, let def = currentTargetDefinition() else { return }
        HookHUD.shared.showSkip(appName: def.displayName, seconds: seconds, byMenu: byMenu)
    }

    private func showPlaybackHUD(appName: String, bundleID: String, isPlaying: Bool?) {
        let isSpotify = bundleID == "com.spotify.client"
        let generation = HookHUD.shared.showPlayback(appName: appName, isPlaying: isPlaying,
                                                     subtitle: isSpotify ? spotifyTrack : "")
        guard isSpotify else { return }
        Task {
            await refreshSpotifyTrack()
            HookHUD.shared.updatePlaybackSubtitle(spotifyTrack, generation: generation)
        }
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
        // Report launch and command failures; successful playback has its HUD.
        switch outcome {
        case .notInstalled:
            Self.log.error("launch-on-play: \(displayName, privacy: .public) is not installed")
        case .timedOut:
            Self.log.error("launch-on-play: \(displayName, privacy: .public) timed out waiting for readiness")
        case .commandFailed:
            Self.log.error("launch-on-play: playback command failed for \(displayName, privacy: .public)")
        case .played:
            // Close the loop opened by the "Starting …" overlay: the app is up
            // and playing. No state read needed — the launcher only reports
            // .played once it has sent play to a ready app.
            if showPlayPauseHUD, selectedTargetID == id {
                showPlaybackHUD(appName: displayName, bundleID: app.bundleID, isPlaying: true)
            }
        case .skipped, .alreadyPlaying:
            break
        }
    }

    /// Guards the one-shot "hooked" HUD shown at launch, so re-activations
    /// (e.g. after wake / fast user switch) don't re-flash it.
    private var didAnnounceStartupHook = false

    private static let mutePermissionRequestedKey = "perAppMutePermissionRequested"

    /// With per-app mute on by default, the System Audio Recording prompt
    /// belongs at first launch — right here, once Accessibility is in place, so
    /// a fresh install meets the two dialogs one after the other — rather than
    /// at some later first mute. Persisted, so it happens once per install
    /// (macOS never re-prompts after an answer anyway; this just spares every
    /// later launch the probe). A later toggle in Settings still probes.
    private func requestMutePermissionOnce() {
        guard perAppMuteEnabled, #available(macOS 14.2, *),
              !UserDefaults.standard.bool(forKey: Self.mutePermissionRequestedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.mutePermissionRequestedKey)
        muteController.requestPermission()
    }

    private func activateInput() {
        tap.start()
        watchdog.start()
        outputMonitor.start()
        updateVolumeRouting()
        requestMutePermissionOnce()
        HookHUD.shared.onVolumeVisibilityChange = { [weak self] visible in
            self?.volumeHUDVisibilityChanged(visible)
        }
        HookHUD.shared.onVisibilityChange = { [weak self] visible in
            self?.hudVisibilityChanged(visible)
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
                                            commandHint: self.commandVolumeHint)
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
            revision: playbackContextRevision,
            quickTimeMovieID: selectedTargetIsQuickTime ? selectedQuickTimeMovieID : nil
        )
    }

    // MARK: - Fresh playback knowledge

    /// The freshest known play state per app — written by the user's own
    /// clicks and key presses (optimistically, then confirmed) and refreshed by
    /// every poll. It is what lets the speaker's EQ animation follow a pause or
    /// play the instant it happens rather than when the next 1.5s poll or 2s
    /// stream refresh notices. It never ages out on its own: a time-based
    /// expiry is invisible to SwiftUI, so polls overwrite it instead. Keyed by
    /// bundle id; browsers keep theirs per tab (see `performBrowserCommand`).
    struct PlaybackHint {
        let playing: Bool
        let at: Date
    }
    @Published private(set) var automationDeniedBundleIDs: Set<String> = []
    @Published private(set) var playbackHints: [String: PlaybackHint] = [:]
    /// Apps with a toggle in flight. A poll that lands mid-toggle would read
    /// the state we just left (Spotify keeps reporting "paused" for a beat
    /// after play while it buffers) and stomp the optimistic hint, so polled
    /// results are ignored for these until the confirm read settles them.
    private var playbackSettling: Set<String> = []

    /// Authoritative: a click, a key press, or a settled confirm read.
    func notePlayback(bundleID: String, playing: Bool) {
        if playing || playbackHints[bundleID]?.playing == true { recordAppPlayback([bundleID]) }
        playbackHints[bundleID] = PlaybackHint(playing: playing, at: Date())
        refreshVolumeSourceActivity()
    }

    /// From a periodic poll — dropped while that app's toggle is settling.
    func notePolledPlayback(bundleID: String, playing: Bool?) {
        guard !playbackSettling.contains(bundleID) else { return }
        if let playing {
            notePlayback(bundleID: bundleID, playing: playing)
        } else {
            playbackHints.removeValue(forKey: bundleID)
        }
    }

    func playbackHint(for bundleID: String) -> Bool? {
        playbackHints[bundleID]?.playing
    }

    /// A browser toggle just ran on one tab: flip that tab's cached play state
    /// so the rows react now instead of at the next 3s scan. Only the acted-on
    /// tab changes — with several tabs playing, the browser row keeps animating
    /// until the last of them stops, which is exactly right.
    private func noteBrowserPlaybackToggled(_ candidate: BrowserMediaCandidate) {
        func flipped(_ c: BrowserMediaCandidate) -> BrowserMediaCandidate {
            BrowserMediaCandidate(browser: c.browser, sourceID: c.sourceID,
                                  windowIndex: c.windowIndex, tabIndex: c.tabIndex,
                                  title: c.title, artist: c.artist, host: c.host,
                                  isPlaying: !c.isPlaying, isSelected: c.isSelected,
                                  supportsTransport: c.supportsTransport, volume: c.volume)
        }
        if let index = browserMediaCandidates.firstIndex(where: { $0.id == candidate.id }) {
            browserMediaCandidates[index] = flipped(browserMediaCandidates[index])
        }
        if let index = activeBrowserMediaCandidates.firstIndex(where: { $0.id == candidate.id }) {
            activeBrowserMediaCandidates[index] = flipped(activeBrowserMediaCandidates[index])
        }
    }

    // Play/pause helpers used by the in-menu control. Reads run off the main
    // thread and are accepted only while their exact target context is current.
    // Browser reads address the cached page-owned source directly instead of
    // rescanning every tab.
    func isTargetPlaying(in context: PlaybackTargetContext) async -> Bool? {
        await targetPlayingState(in: context, using: pollRunner)
    }

    /// Read after a user command, on the command lane, and authoritatively
    /// reconcile the optimistic state without waiting for the periodic poll.
    ///
    /// Not immediately, though: every kind of target can lag the press. A
    /// menu-driven app's item title updates late, and a scripted player still
    /// reports "paused" for a beat after play while it buffers (Spotify).
    /// Reading right away sometimes drew the state we just left — which is why
    /// play used to restart the speaker animation a poll later while pause
    /// stopped it at once. So: settle, read, and if the app still reports the
    /// state we came from (`after`), give it one more beat and read again.
    /// Polls are ignored for the app meanwhile (see `playbackSettling`).
    func confirmTargetPlaying(in context: PlaybackTargetContext,
                              after previous: Bool? = nil) async -> Bool? {
        let bundleID = currentTargetDefinition()?.bundleID
        if let bundleID { playbackSettling.insert(bundleID) }
        defer { if let bundleID { playbackSettling.remove(bundleID) } }

        try? await Task.sleep(nanoseconds: 350_000_000)
        guard context == playbackTargetContext else { return nil }
        var result = await targetPlayingState(in: context, using: scripting, notingHint: false)
        if let previous, result == previous {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard context == playbackTargetContext else { return nil }
            result = await targetPlayingState(in: context, using: scripting, notingHint: false)
        }
        if let result, let bundleID, context == playbackTargetContext {
            notePlayback(bundleID: bundleID, playing: result)
        }
        return result
    }

    /// `notingHint`: a poll records its result (unless the app is settling a
    /// toggle); the confirm read above writes the hint itself once settled.
    private func targetPlayingState(
        in context: PlaybackTargetContext,
        using runner: ScriptRunner,
        notingHint: Bool = true
    ) async -> Bool? {
        guard context == playbackTargetContext, let id = context.targetID else { return nil }

        let result: Bool?
        if id == BuiltInApps.quickTime.id, let movieID = context.quickTimeMovieID {
            guard let movie = quickTimeMovies.first(where: { $0.id == movieID }) else { return nil }
            result = await runner.run { [quickTimeController] in quickTimeController.isPlaying(movie) }
        } else if let browser = BrowserKind.target(id: id) {
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
            await refreshPlaybackPermission(bundleID: app.bundleID, state: result)
            if notingHint, context == playbackTargetContext {
                notePolledPlayback(bundleID: app.bundleID, playing: result)
            }
        }

        guard context == playbackTargetContext else { return nil }
        return result
    }

    func togglePlayPauseTarget(in context: PlaybackTargetContext) async -> Bool {
        guard context == playbackTargetContext else { return false }
        if selectedTargetIsQuickTime {
            if let movieID = context.quickTimeMovieID {
                guard let movie = quickTimeMovies.first(where: { $0.id == movieID }) else { return false }
                return await toggleQuickTimeMovie(movie)
            }
            // A hardware key can arrive before the menu's first scan. Resolve a
            // movie now, but never redirect a command for an explicit selection.
            let movies = await scripting.run { [quickTimeController] in quickTimeController.scan() }
            guard context == playbackTargetContext else { return false }
            quickTimeScanFailed = movies == nil
            quickTimeMovies = movies ?? []
            guard let movie = quickTimeMovies.first(where: { $0.isPlaying }) ?? quickTimeMovies.first else {
                if !isRunning(bundleID: BuiltInApps.quickTime.bundleID) {
                    Task { await launchTargetAndPlay() }
                }
                return false
            }
            selectedQuickTimeMovieID = movie.id
            return await toggleQuickTimeMovie(movie)
        }
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
                return app.perform(.playPause)
            }
            // Nothing delivered: the app isn't running. Kick off the launch
            // fallback without awaiting it — awaiting here would hold
            // commandInFlight (and the disabled button) for the whole launch
            // timeout, and would prevent the periodic poll from ever reporting
            // that playback started. Returning false immediately releases the
            // button; TargetLauncher's single-flight guard stops a second press
            // from starting a second launch.
            if !performed && !app.isReady { Task { await launchTargetAndPlay() } }
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
        let result = await pollRunner.run { app.isPlaying() }
        await refreshPlaybackPermission(bundleID: bundleID, state: result)
        return result
    }

    private func refreshPlaybackPermission(bundleID: String, state: Bool?) async {
        guard let definition = availableApps.first(where: { $0.bundleID == bundleID }),
              definition.menuControl == nil else { return }
        let denied: Bool
        if state != nil {
            denied = false
        } else {
            denied = await pollRunner.run { AutomationPermission.isAllowed(bundleID: bundleID) == false }
        }
        if denied {
            automationDeniedBundleIDs.insert(bundleID)
            playbackHints.removeValue(forKey: bundleID)
            volumeByBundle.removeValue(forKey: bundleID)
        } else {
            automationDeniedBundleIDs.remove(bundleID)
        }
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

    /// True when the key became a short skip. Any unreadable page or refused
    /// seek returns false so the caller sends the plain track command.
    private func skipBrowserIfPodcast(_ command: MediaCommand,
                                      on candidate: BrowserMediaCandidate) async -> Bool {
        guard skipOnPodcasts else { return false }
        let always = alwaysSkip
        let seconds: Int? = await scripting.run { [browserMediaController] in
            guard let facts = browserMediaController.transportFacts(candidate) else { return nil }
            let action = TransportDecision.decide(
                command: command, kind: BrowserPlaybackKind.classify(facts),
                canSeek: BrowserPlaybackKind.canSeek(facts),
                skip: BrowserPlaybackKind.skipSeconds(host: facts.host),
                skipOnPodcasts: true, alwaysSkip: always)
            guard case .seek(let seconds) = action,
                  browserMediaController.seek(by: seconds, on: candidate) else { return nil }
            return seconds
        }
        guard let seconds else { return false }
        announceSkip(seconds: seconds, byMenu: false)
        return true
    }

    private func seekQuickTime(by seconds: Int) async {
        guard let id = selectedQuickTimeMovieID,
              let movie = quickTimeMovies.first(where: { $0.id == id }) else { return }
        let moved = await scripting.run { [quickTimeController] in
            quickTimeController.seek(movie, by: seconds)
        }
        if moved { announceSkip(seconds: seconds, byMenu: false) }
    }

    private func performBrowserCommand(
        _ command: MediaCommand,
        on candidate: BrowserMediaCandidate
    ) async -> Bool {
        let performed = await scripting.run { [browserMediaController] in
            browserMediaController.perform(command, on: candidate)
        }
        if performed, command == .playPause {
            noteBrowserPlaybackToggled(candidate)
        }
        return performed
    }

    func setTarget(_ id: String?, showConfirmation: Bool = true) {
        menuBrowserHookRevision &+= 1
        if id != selectedTargetID {
            selectedQuickTimeMovieID = nil
            quickTimeMovies = []
            quickTimeScanFailed = false
        }
        selectedTargetID = id
        targetManager.selectedTargetID = id
        configureBrowserTransportForPendingScan()
        updateVolumeRouting()
        // Scan the hooked browser now instead of leaving it to the menu's
        // visible-poll loop: the popover can close before that loop fires,
        // which would strand a JS-enabled browser in macOS passthrough until
        // the menu is next opened. User-initiated, so a first-time Automation
        // prompt lands while the user is still looking at their choice.
        if selectedTargetIsBrowser {
            Task { await refreshBrowserMedia() }
        }
        if selectedTargetIsQuickTime {
            Task { await refreshQuickTimeMovies() }
        }
        // Confirm the new hook with a centre-screen HUD (user-initiated, so always).
        if showConfirmation, let def = currentTargetDefinition() {
            HookHUD.shared.show(appName: def.displayName,
                                commandHint: commandVolumeHint)
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
        let mutedNow = perAppMuteEnabled
            && (targetManager.targetBundleID.map { mutedApps.contains($0) } ?? false)
        if menuBarMuted != mutedNow { menuBarMuted = mutedNow }
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

        let context = playbackTargetContext
        let scan = await pollRunner.run { [browserMediaController] in
            browserMediaController.scan(browser)
        }
        // A tab hook can complete while this scan is in flight. Its older
        // selection markers must not overwrite the user's newer exact choice.
        guard context == playbackTargetContext else { return }

        browserMediaInjectionAvailable = scan.injectionAvailable
        if scan.injectionAvailable {
            _ = recentBrowserSources(from: scan.candidates, browser: browser)
        }
        browserMediaCandidates = Self.applyingSessionTabVolumes(sessionTabVolumes, to: scan.candidates)
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
        menuBrowserHookRevision &+= 1
        selectedBrowserMediaID = id
        Task {
            _ = await scripting.run { [browserMediaController] in
                browserMediaController.select(candidate)
            }
            await refreshBrowserMedia()
        }
    }

    /// Hook a visible tab even when another app owns the media keys. Mark the
    /// exact page before switching targets so a scan cannot pick a different
    /// playing tab in the meantime. A newer click/unhook wins over a late reply.
    @discardableResult
    func hookBrowserMedia(_ candidate: BrowserMediaCandidate,
                          showConfirmation: Bool = true) async -> Bool {
        guard let definition = availableApps.first(where: {
            BrowserKind.target(id: $0.id) == candidate.browser
        }) else { return false }
        menuBrowserHookRevision &+= 1
        let request = menuBrowserHookRevision
        let context = playbackTargetContext
        let selected = await scripting.run { [browserMediaController] in
            browserMediaController.select(candidate)
        }
        guard selected, request == menuBrowserHookRevision,
              context.targetID == selectedTargetID else { return false }

        var candidates = activeBrowserMediaCandidates.filter { $0.browser == candidate.browser }
        if !candidates.contains(where: { $0.id == candidate.id }) { candidates.append(candidate) }
        // This action already verified injection and selected the page. Do not
        // run setTarget's provisional scan/reset over that confirmed selection.
        selectedTargetID = definition.id
        targetManager.selectedTargetID = definition.id
        browserMediaCandidates = candidates
        browserMediaInjectionAvailable = true
        browserTargetRunning = true
        selectedBrowserMediaID = candidate.id
        tap.transportKeysHijacked = true
        updateVolumeRouting()
        if showConfirmation {
            HookHUD.shared.show(appName: candidate.label, commandHint: commandVolumeHint)
        }
        return true
    }

    /// Include recently playing browsers even after their output stream stops.
    /// Only live scans supply rows, so remembered IDs cannot resurrect closed tabs.
    func refreshActiveBrowserMedia(bundleIDs: Set<String>) async {
        let remembered = recentBrowserBundleIDs()
        let browsers = BrowserKind.allCases.filter {
            (bundleIDs.contains($0.bundleID) || remembered.contains($0.bundleID))
                && isRunning(bundleID: $0.bundleID)
        }
        let runningPrefixes = browsers.map { "\($0.rawValue):" }
        browserSourceRecency = browserSourceRecency.filter { entry in
            runningPrefixes.contains { entry.key.hasPrefix($0) }
        }

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
        activeBrowserMediaCandidates = Self.applyingSessionTabVolumes(sessionTabVolumes, to: candidates)
    }

    /// Rank a browser's sources with currently playing tabs first, then the selected
    /// target, then previously observed playback recency. Only three survive.
    /// Ranking decides *which* three; the rows are then shown in name order, so
    /// pausing a source can't make it jump past its neighbours under the cursor.
    func recentBrowserSources(
        from candidates: [BrowserMediaCandidate],
        browser: BrowserKind,
        now: Date = Date()
    ) -> [BrowserMediaCandidate] {
        let prefix = "\(browser.rawValue):"
        let candidateIDs = Set(candidates.map(\.id))
        browserSourceRecency = browserSourceRecency.filter { entry in
            !entry.key.hasPrefix(prefix) || candidateIDs.contains(entry.key)
        }

        for candidate in candidates where candidate.isPlaying {
            browserSourceRecency[candidate.id] = now
        }
        browserSourceRecency = browserSourceRecency.filter {
            now.timeIntervalSince($0.value) < Self.browserSourceRetention
        }

        let ranked = candidates
            .filter {
                $0.volume != nil
                    && ($0.isPlaying || $0.isSelected || browserSourceRecency[$0.id] != nil)
            }
            .sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
                if lhs.isSelected != rhs.isSelected { return lhs.isSelected }
                let lhsRecency = browserSourceRecency[lhs.id] ?? .distantPast
                let rhsRecency = browserSourceRecency[rhs.id] ?? .distantPast
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

        return displayed
    }

    /// Expiration is based on actual observed playback, never menu access.
    func recentBrowserBundleIDs(now: Date = Date()) -> Set<String> {
        browserSourceRecency = browserSourceRecency.filter {
            now.timeIntervalSince($0.value) < Self.browserSourceRetention
        }
        return Set(BrowserKind.allCases.filter { browser in
            browserSourceRecency.keys.contains { $0.hasPrefix("\(browser.rawValue):") }
        }.map(\.bundleID))
    }

    func setBrowserVolume(_ percent: Int, for candidate: BrowserMediaCandidate) {
        let clamped = min(max(percent, 0), 100)
        // A slider move during a picker session is the newest level: record it
        // so a key-written level from earlier in the session can't override it.
        if volumeSession != nil { sessionTabVolumes[candidate.id] = clamped }
        updateBrowserVolumeCaches(clamped, forTabID: candidate.id)
        Task {
            let sent = await scripting.run { [browserMediaController] in
                browserMediaController.setVolume(clamped, for: candidate)
            }
            if sent { unmuteForVolumeChange(clamped, bundleID: candidate.browser.bundleID) }
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

    func setSkipOnPodcasts(_ on: Bool) {
        skipOnPodcasts = on
        TrackKeyPreference.setSkipOnPodcasts(on, in: .standard)
    }

    func setAlwaysSkip(_ on: Bool) {
        alwaysSkip = on
        TrackKeyPreference.setAlwaysSkip(on, in: .standard)
    }

    func setCommandVolumeRouting(_ on: Bool) {
        commandVolumeRouting = on
        CommandVolumePreference.setEnabled(on, in: .standard)
        updateVolumeRouting()
    }

    // MARK: - Per-app mute

    @available(macOS 14.2, *)
    private var muteController: ProcessMuteController {
        if let existing = muteControllerStorage as? ProcessMuteController { return existing }
        let controller = ProcessMuteController()
        controller.$mutedBundleIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.mutedApps = $0 }
            .store(in: &cancellables)
        controller.$volumes
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.processVolumeLevels = $0 }
            .store(in: &cancellables)
        controller.$volumeErrors
            .receive(on: RunLoop.main)
            .sink { [weak self] errors in
                self?.processVolumeErrors = errors
                self?.updateVolumeRouting()
                if self?.volumeSession != nil { self?.showVolumeSessionHUD() }
            }
            .store(in: &cancellables)
        controller.$permissionGranted
            .receive(on: RunLoop.main)
            .sink { [weak self] granted in
                self?.mutePermissionGranted = granted
                self?.updateVolumeRouting()
            }
            .store(in: &cancellables)
        controller.$audibleApps
            .receive(on: RunLoop.main)
            .sink { [weak self] audible in
                if let self { self.recordAppPlayback(self.audibleApps.union(audible)) }
                self?.audibleApps = audible
                self?.refreshRecentOverlaySources()
                self?.refreshVolumeSourceActivity()
            }
            .store(in: &cancellables)
        muteControllerStorage = controller
        return controller
    }

    /// The popover's list of apps that need live audibility (no play state to
    /// ask for): while the menu is open the mute controller meters exactly
    /// these; an empty set tears the meters down.
    func setMeterWatchlist(_ bundleIDs: Set<String>) {
        menuMeterWatchlist = bundleIDs
        updateMeterWatchlist()
    }

    /// The menu and overlay can be visible independently. Closing either one
    /// must not stop the other's meters; closing both releases every watch.
    private func updateMeterWatchlist() {
        guard #available(macOS 14.2, *), perAppMuteEnabled else { return }
        let overlay = Set((volumeSession?.entries ?? []).compactMap { volumeSourceBundleID($0.source) })
        let candidates = volumeSession == nil ? Set<String>() : Set(volumePickerApps.map(\.bundleID))
        muteController.setMeterWatchlist(menuMeterWatchlist.union(overlay).union(candidates))
    }

    private func volumeSourceBundleID(_ source: VolumeSource) -> String? {
        switch source {
        case .hookedTarget: return targetManager.targetBundleID
        case .app(let bundleID): return bundleID
        case .browserTab(let id): return browserCandidate(id: id)?.browser.bundleID
        }
    }

    private func volumeSourceIsEmitting(_ source: VolumeSource) -> Bool {
        guard let bundleID = volumeSourceBundleID(source), !isAppMuted(bundleID),
              !perAppMuteEnabled || processVolumeLevels[bundleID] != 0 else { return false }
        if currentVolume(of: source) == 0 { return false }
        if let pending = pendingPickerPlayback, pending.source == source, pending.bundleID == bundleID {
            return pending.playing
        }
        let candidate: BrowserMediaCandidate?
        switch source {
        case .hookedTarget: candidate = selectedTargetIsBrowser ? selectedBrowserMediaCandidate : nil
        case .app: candidate = nil
        case .browserTab(let id): candidate = browserCandidate(id: id)
        }
        // Per-tab playback disambiguates siblings; the app meter alone cannot
        // tell which tab is sounding. A paused/zero-volume tab stays still.
        if let candidate { return candidate.isPlaying && tabVolume(id: candidate.id) != 0 }
        if BrowserKind.browser(bundleID: bundleID) == nil,
           canPlayPauseVolumeSource(source), let playing = playbackHint(for: bundleID) {
            return playing
        }
        if #available(macOS 14.2, *), perAppMuteEnabled {
            return audibleApps.contains(bundleID)
        }
        return candidate?.isPlaying ?? playbackHint(for: bundleID) ?? false
    }

    /// A sound-emitting process is not necessarily a media player. Only show
    /// transport indicators when we have a command that can control the source.
    func canPlayPauseVolumeSource(_ source: VolumeSource) -> Bool {
        switch source {
        case .browserTab(let id): return browserCandidate(id: id)?.supportsTransport == true
        case .hookedTarget:
            if selectedTargetIsBrowser {
                return browserMediaInjectionAvailable == true
                    && selectedBrowserMediaCandidate?.supportsTransport == true
            }
        case .app: break
        }
        guard let bundleID = volumeSourceBundleID(source) else { return false }
        // Browser parent rows represent all tabs for volume/mute only.
        // Playback belongs to a specific tab, never the whole browser.
        if BrowserKind.browser(bundleID: bundleID) != nil { return false }
        return availableApps.contains {
            $0.bundleID == bundleID && ($0.menuControl != nil
                || !$0.playPauseScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func volumeSourceIsPlaying(_ source: VolumeSource) -> Bool {
        if let pending = pendingPickerPlayback, pending.source == source,
           pending.bundleID == volumeSourceBundleID(source) { return pending.playing }
        switch source {
        case .browserTab(let id): return browserCandidate(id: id)?.isPlaying ?? false
        case .hookedTarget:
            if selectedTargetIsBrowser, let candidate = selectedBrowserMediaCandidate { return candidate.isPlaying }
        case .app: break
        }
        guard let bundleID = volumeSourceBundleID(source) else { return false }
        if BrowserKind.browser(bundleID: bundleID) != nil {
            return (browserMediaCandidates + activeBrowserMediaCandidates).contains {
                $0.browser.bundleID == bundleID && $0.isPlaying
            } || audibleApps.contains(bundleID)
        }
        // Playback and audibility differ: muting a playing app must not make
        // its transport icon claim it is paused.
        return playbackHint(for: bundleID) ?? audibleApps.contains(bundleID)
    }

    private func refreshVolumeSourceActivity() {
        guard let session = volumeSession else { return }
        let activity = Dictionary(uniqueKeysWithValues: session.entries.map {
            ($0.source.id, volumeSourceIsEmitting($0.source))
        })
        HookHUD.shared.updateSourceActivity(activity)
        HookHUD.shared.updateSourcePlayback(Dictionary(uniqueKeysWithValues: session.entries.map {
            ($0.source.id, canPlayPauseVolumeSource($0.source) ? volumeSourceIsPlaying($0.source) : nil)
        }))
    }

    func setPerAppMute(_ on: Bool) {
        for bundleID in processVolumeLevels.keys { volumeByBundle[bundleID] = nil }
        processVolumeLevels = [:]
        processVolumeErrors = [:]
        perAppMuteEnabled = on
        PerAppMutePreference.setEnabled(on, in: .standard)
        defer {
            updateVolumeRouting()   // the tap's mute-key routing follows the setting
            updateMenuBarGlyph()
            updateMeterWatchlist()
        }
        guard #available(macOS 14.2, *) else { return }
        if on {
            muteController.start()
            // This is the moment the System Audio Recording prompt may appear —
            // right after the user asked for the feature, never uninvited.
            muteController.requestPermission()
        } else {
            muteController.stopAndClear()
        }
    }

    /// A mute key press the tap routed to us (⌘ + mute normally; plain mute
    /// while the volume keys are hooked): flip the hooked app's process-tap
    /// mute. The guards mirror `targetCanTakeMute` — the tap only routes the
    /// key here while that was true, but the world can change between press
    /// and dispatch.
    private func toggleTargetMute() {
        guard let bundleID = targetManager.targetBundleID,
              let nowMuted = toggleProcessMute(bundleID: bundleID) else { return }
        if let def = currentTargetDefinition() {
            HookHUD.shared.showMute(appName: def.displayName, muted: nowMuted)
        }
    }

    /// Flip one app's process-tap mute; the new state, or nil when per-app mute
    /// is off or unavailable. Shared by the mute key and the picker session.
    private func toggleProcessMute(bundleID: String) -> Bool? {
        guard #available(macOS 14.2, *), perAppMuteEnabled else { return nil }
        let nowMuted = !isAppMuted(bundleID)
        muteController.setMuted(nowMuted, bundleID: bundleID)
        return nowMuted
    }

    /// The hooked target can be process-tap muted right now: the per-app mute
    /// feature is on and the target is running. Unlike volume this needs no
    /// scripting support — the tap mutes any process.
    var targetCanTakeMute: Bool {
        guard perAppMuteEnabled, let bundleID = targetManager.targetBundleID else { return false }
        return isRunning(bundleID: bundleID)
    }

    func isAppMuted(_ bundleID: String) -> Bool {
        mutedApps.contains(bundleID)
    }

    func setAppMuted(_ muted: Bool, bundleID: String) {
        guard #available(macOS 14.2, *) else { return }
        muteController.setMuted(muted, bundleID: bundleID)
    }

    /// A positive volume adjustment restores sound, including a browser's
    /// process mute when its tab slider is used. Zero remains silent.
    func unmuteForVolumeChange(_ percent: Int, bundleID: String) {
        guard percent > 0, #available(macOS 14.2, *),
              muteController.isMuted(bundleID) else { return }
        muteController.setMuted(false, bundleID: bundleID)
    }

    /// "Re-check" after a trip to System Settings: the probe never re-prompts —
    /// once answered, tap creation just succeeds or fails.
    func recheckMutePermission() {
        guard #available(macOS 14.2, *) else { return }
        muteController.requestPermission()
    }

    /// Name for a muted row with no matching definition: the running app's own.
    func runningAppName(bundleID: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName
    }

    // Volume helpers used by the sliders (AppleScript runs off the main thread).
    // The initial read uses the poll runner (best-effort); the write uses the command
    // runner since it's a user action.
    func volume(for bundleID: String) async -> Int? {
        if #available(macOS 14.2, *), usesProcessVolume(bundleID: bundleID) {
            return muteController.volume(for: bundleID)
        }
        guard BrowserKind.browser(bundleID: bundleID) == nil,
              let app = registry.allApps().first(where: { $0.bundleID == bundleID }) else { return nil }
        return await pollRunner.run { app.currentVolume() }
    }

    func setVolume(_ percent: Int, for bundleID: String) {
        let percent = min(100, max(0, percent))
        volumeByBundle[bundleID] = percent   // optimistic: the slider reflects it at once
        if #available(macOS 14.2, *), usesProcessVolume(bundleID: bundleID) {
            muteController.setVolume(percent, bundleID: bundleID)
            unmuteForVolumeChange(percent, bundleID: bundleID)
            return
        }
        guard BrowserKind.browser(bundleID: bundleID) == nil,
              let app = registry.allApps().first(where: { $0.bundleID == bundleID }) else { return }
        Task {
            await scripting.run { app.setVolume(percent) }
            unmuteForVolumeChange(percent, bundleID: bundleID)
        }
    }

    // MARK: - Volume-key coalescing

    /// Records one volume-key press and kicks off the drain if it isn't already
    /// running. Presses that arrive mid-flight accumulate into the last pending
    /// batch while it is for the same source, so holding the key collapses into
    /// a few off-main round-trips instead of one blocked send each; a press for
    /// a different source starts a new batch.
    private func nudgeVolume(up: Bool) {
        guard let source = currentVolumeSource else { return }
        let session = activeVolumeSession
        let step = up ? 1 : -1
        if let last = pendingVolumeBatches.indices.last,
           pendingVolumeBatches[last].source == source,
           pendingVolumeBatches[last].session == session {
            pendingVolumeBatches[last].steps += step
        } else {
            pendingVolumeBatches.append(VolumeStepBatch(source: source, session: session, steps: step))
        }
        guard !volumeDrainInFlight else { return }
        volumeDrainInFlight = true
        Task { await drainVolumeSteps() }
    }

    private func drainVolumeSteps() async {
        defer { volumeDrainInFlight = false }
        while !pendingVolumeBatches.isEmpty {
            let batch = pendingVolumeBatches.removeFirst()
            guard batch.steps != 0 else { continue }
            // Pressed for a session that has since ended: drop it rather than
            // land it on whatever the keys reach now.
            if let session = batch.session, session != activeVolumeSession { continue }
            let delta = batch.steps * targetManager.volumeStep
            await changeVolume(of: batch.source, session: batch.session) { $0 + delta }
        }
    }

    /// The session's selected source, otherwise the hooked target; nil in a
    /// session whose list has no selection.
    private var currentVolumeSource: VolumeSource? {
        guard let volumeSession else { return .hookedTarget }
        return volumeSession.selected?.source
    }

    /// The open picker session's generation, or nil when none is open.
    private var activeVolumeSession: UInt64? {
        volumeSession == nil ? nil : volumeSessionGeneration
    }

    /// Read-modify-write one source's volume (AppleScript off main), update the
    /// caches the menu and HUD read, then show the HUD. Returns the change, or nil
    /// when nothing was changed (source gone, not ready, no volume, send failed).
    /// `session` is the picker session the change was asked for in; once that
    /// session has ended the change still lands in the caches but shows no HUD.
    @discardableResult
    func changeVolume(of source: VolumeSource,
                              session: UInt64?,
                              _ transform: @escaping (Int) -> Int) async -> VolumeChange? {
        // A hooked browser tab is still an exact tab. Use its cached level and
        // identity-checked fast path instead of the generic browser scripts,
        // which rediscover media for both the read and the write.
        if source == .hookedTarget, selectedTargetIsBrowser,
           let candidate = selectedBrowserMediaCandidate {
            return await changeVolume(of: .browserTab(id: candidate.id), session: session, transform)
        }
        let change: VolumeChange?
        switch source {
        case .hookedTarget:
            // Capture what "hooked" meant at the moment this RMW started — by the
            // time it returns, the user may have switched tabs or re-hooked, and
            // writing into today's selection with yesterday's result would land
            // one source's volume on another's row. The cache is keyed to the app
            // updateVolume actually acted on (resolved inside its off-main
            // closure), not a separately-read target.
            let wasBrowser = selectedTargetIsBrowser
            let browserTabID = selectedBrowserMediaID
            if (!wasBrowser || selectedBrowserMediaCandidate == nil),
               let bundleID = targetManager.targetBundleID,
               usesProcessVolume(bundleID: bundleID) {
                change = changeProcessVolume(bundleID: bundleID, transform)
            } else {
                change = await targetManager.updateVolume(transform)
            }
            if let change {
                volumeByBundle[change.bundleID] = change.volume
                if wasBrowser, let id = browserTabID,
                   let index = browserMediaCandidates.firstIndex(where: { $0.id == id }),
                   browserMediaCandidates[index].browser.bundleID == change.bundleID {
                    browserMediaCandidates[index].volume = change.volume
                }
            }
        case .app(let bundleID):
            if usesProcessVolume(bundleID: bundleID) {
                change = changeProcessVolume(bundleID: bundleID, transform)
            } else {
                guard BrowserKind.browser(bundleID: bundleID) == nil else { return nil }
                change = await targetManager.updateVolume(ofBundleID: bundleID, transform)
            }
            if let change { volumeByBundle[bundleID] = change.volume }
        case .browserTab(let id):
            guard let candidate = browserCandidate(id: id), let current = tabVolume(id: id) else {
                return nil
            }
            let next = min(100, max(0, transform(current)))
            if next != current {
                // Awaited inline (unlike the menu slider's `setBrowserVolume`),
                // so this RMW suspends until the send completes. Otherwise
                // `drainVolumeSteps` would finish at once and a held key's
                // repeats would fire overlapping, unordered sends.
                let sent = await scripting.run { [browserMediaController] in
                    browserMediaController.setVolume(next, for: candidate)
                }
                // A stale row (the tab closed or navigated): report nothing, so
                // the HUD neither redraws nor stays up for it.
                guard sent else { return nil }
                updateBrowserVolumeCaches(next, forTabID: id)
                if let session, session == activeVolumeSession {
                    sessionTabVolumes[id] = next
                }
            }
            // Reported even when unchanged (already at 0 or 100), so the
            // press still shows the HUD.
            change = VolumeChange(bundleID: candidate.browser.bundleID, previous: current, volume: next)
        }
        guard let change else { return nil }
        unmuteForVolumeChange(change.volume, bundleID: change.bundleID)
        if let session {
            if session == activeVolumeSession { showVolumeSessionHUD() }
        } else if volumeSession != nil {
            showVolumeSessionHUD()
        } else {
            let appName = availableApps.first { $0.bundleID == change.bundleID }?.displayName
                ?? change.bundleID
            // With the plain keys hooked, the overlay teaches the escape hatch.
            // Reached by ⌘ instead, it would only echo the chord just pressed.
            HookHUD.shared.showVolume(appName: appName,
                                      percent: change.volume,
                                      commandHint: tap.volumeKeysHijacked ? .system : nil)
        }
        return change
    }

    private func changeProcessVolume(bundleID: String, _ transform: (Int) -> Int) -> VolumeChange? {
        guard #available(macOS 14.2, *), isRunning(bundleID: bundleID),
              usesProcessVolume(bundleID: bundleID) else { return nil }
        let previous = muteController.volume(for: bundleID)
        let next = min(100, max(0, transform(previous)))
        setVolume(next, for: bundleID)
        return VolumeChange(bundleID: bundleID, previous: previous, volume: next)
    }

    /// Both browser-tab volume caches (the menu's hooked-browser rows and the
    /// active-tab list) for one tab. Shared by the menu slider's
    /// `setBrowserVolume` and the volume keys' `changeVolume`.
    private func updateBrowserVolumeCaches(_ percent: Int, forTabID id: String) {
        if let index = activeBrowserMediaCandidates.firstIndex(where: { $0.id == id }) {
            activeBrowserMediaCandidates[index].volume = percent
        }
        if let index = browserMediaCandidates.firstIndex(where: { $0.id == id }) {
            browserMediaCandidates[index].volume = percent
        }
    }

    /// Scanned candidates with the session's key-written tab levels laid over
    /// them. Pure, so the scan sites can patch incoming data before assigning
    /// it once; an empty map (always the case outside a session) returns the
    /// scan unchanged.
    nonisolated static func applyingSessionTabVolumes(
        _ volumes: [String: Int],
        to candidates: [BrowserMediaCandidate]
    ) -> [BrowserMediaCandidate] {
        guard !volumes.isEmpty else { return candidates }
        return candidates.map { candidate in
            guard let volume = volumes[candidate.id] else { return candidate }
            var patched = candidate
            patched.volume = volume
            return patched
        }
    }

    private func browserCandidate(id: String) -> BrowserMediaCandidate? {
        activeBrowserMediaCandidates.first { $0.id == id }
            ?? browserMediaCandidates.first { $0.id == id }
    }

    /// A tab's level: what the keys wrote this session, else the cached scan.
    private func tabVolume(id: String) -> Int? {
        guard browserCandidate(id: id) != nil else { return nil }
        return sessionTabVolumes[id] ?? browserCandidate(id: id)?.volume
    }

    /// A mute key the tap routed to us. Outside a picker session it is exactly
    /// upstream's hooked-app mute; inside one — ⌘ + Mute, or plain Mute with the
    /// volume keys hooked — it toggles the picked source.
    private func handleMuteKey() {
        guard let session = activeVolumeSession else {
            toggleTargetMute()
            return
        }
        guard let source = currentVolumeSource else { return }
        pendingMuteToggles.append(SessionMuteToggle(source: source, session: session))
        guard !muteToggleInFlight else { return }
        muteToggleInFlight = true
        Task { await drainMuteToggles() }
    }

    private func drainMuteToggles() async {
        defer { muteToggleInFlight = false }
        while !pendingMuteToggles.isEmpty {
            let toggle = pendingMuteToggles.removeFirst()
            // The session ended while this was queued: drop it. Redirecting it
            // to the hooked app could mute it for a press macOS should have had.
            guard toggle.session == activeVolumeSession else { continue }
            await performMuteToggle(toggle)
        }
    }

    /// One full mute toggle on the source picked when the key was pressed.
    ///
    /// Apps (the hooked target included) use the same process-tap mute as the
    /// mute key outside a session, so the menu, the menu-bar slash and the
    /// persisted set stay in step. A browser tab can't be process-muted without
    /// silencing the whole browser, so a tab is muted through its volume, with
    /// `MuteMemory` remembering what to put back.
    private func performMuteToggle(_ toggle: SessionMuteToggle) async {
        switch toggle.source {
        case .hookedTarget:
            guard let bundleID = targetManager.targetBundleID,
                  toggleProcessMute(bundleID: bundleID) != nil else { return }
            showVolumeSessionHUD()
        case .app(let bundleID):
            guard toggleProcessMute(bundleID: bundleID) != nil else { return }
            showVolumeSessionHUD()
        case .browserTab(let id):
            let source = VolumeSource.browserTab(id: id)
            let restore = muteMemory.restoreVolume(for: source.id)
            guard let change = await changeVolume(of: source, session: toggle.session, {
                MuteMemory.toggled(from: $0, restore: restore)
            }) else { return }
            muteMemory.record(sourceID: source.id, previous: change.previous, new: change.volume)
        }
    }

    /// Whether the picked source can take a volume step and a mute right now,
    /// mirrored to the tap so a session never swallows a key it can't act on.
    /// The hooked target uses upstream's `targetCanTakeVolume` /
    /// `targetCanTakeMute`; another app must be running (and scriptable, for
    /// volume; per-app mute on, for mute); a tab must still be in the caches.
    /// No selection (an emptied list) can take nothing. Kept current from the
    /// session's didSet, `updateVolumeRouting` (launch/terminate, settings)
    /// and the browser caches' didSets.
    private func updateVolumeSessionRouting() {
        tap.volumeSessionActive = volumeSession != nil
        let canTakeVolume: Bool
        let canTakeMute: Bool
        switch volumeSession?.selected?.source {
        case nil:
            canTakeVolume = false
            canTakeMute = false
        case .hookedTarget?:
            canTakeVolume = targetCanTakeVolume
            canTakeMute = targetCanTakeMute
        case .app(let bundleID)?:
            let running = isRunning(bundleID: bundleID)
            canTakeVolume = running && canControlVolume(bundleID: bundleID)
            canTakeMute = running && perAppMuteEnabled
        case .browserTab(let id)?:
            canTakeVolume = tabVolume(id: id) != nil
            canTakeMute = canTakeVolume
        }
        tap.volumeSessionCanTakeVolume = canTakeVolume
        tap.volumeSessionCanTakeMute = canTakeMute
        refreshVolumeSourceActivity()
    }

    // MARK: - Volume source picker

    private func hudVisibilityChanged(_ visible: Bool) {
        guard hudVisible != visible else { return }
        hudVisible = visible
        if visible {
            sourcePickerTap.arm()
        } else {
            sourcePickerTap.disarm()
        }
    }

    private func volumeHUDVisibilityChanged(_ visible: Bool) {
        if !visible {
            volumeSessionRefresh?.cancel()
            volumeSessionRefresh = nil
            spotifyTrackRefresh?.cancel()
            spotifyTrackRefresh = nil
            spotifyTrack = ""
            volumeSession = nil
            sessionTabVolumes = [:]
        }
    }

    /// Command-arrows expand any visible HUD into the picker, then perform the
    /// corresponding selection or volume action.
    private func handleSourcePickerKey(_ key: SourcePickerKey) {
        // A key can reach the main queue just after the HUD hid and the picker
        // tap was disarmed. Ignore it — otherwise a stale key would open a
        // session and re-show the HUD with no keyboard tap behind it.
        guard hudVisible else { return }
        beginVolumeSessionIfNeeded()
        guard volumeSession != nil else { return }
        if !tap.volumeKeysHijacked { HookHUD.shared.holdUntilCommandRelease() }
        switch key {
        case .previous: volumeSession?.selectPrevious()
        case .next: volumeSession?.selectNext()
        case .volumeDown: nudgeVolume(up: false)
        case .volumeUp: nudgeVolume(up: true)
        case .hook: hookPickerSource()
        }
        showVolumeSessionHUD()
    }

    /// Command-volume opens the full list without moving off the current source.
    private func showVolumePicker() {
        dismissMenuForOverlay?()
        beginVolumeSessionIfNeeded()
        guard volumeSession != nil else { return }
        if !tap.volumeKeysHijacked { HookHUD.shared.holdUntilCommandRelease() }
        showVolumeSessionHUD()
    }

    private var pickerHookInFlight = false

    private func hookPickerSource() {
        guard !pickerHookInFlight, let entry = volumeSession?.selected,
              let session = activeVolumeSession,
              let bundleID = volumeSourceBundleID(entry.source) else { return }
        guard let definition = availableApps.first(where: { $0.bundleID == bundleID }) else {
            AddAppWindow.shared.show(state: self, prefillName: entry.name, prefillBundleID: bundleID)
            return
        }
        let candidate: BrowserMediaCandidate?
        if case .browserTab(let id) = entry.source { candidate = browserCandidate(id: id) }
        else { candidate = nil }
        pickerHookInFlight = true
        Task {
            defer { pickerHookInFlight = false }
            if let candidate {
                let selected = await scripting.run { [browserMediaController] in
                    browserMediaController.select(candidate)
                }
                guard selected else { return }
            }
            guard activeVolumeSession == session else { return }
            setTarget(definition.id, showConfirmation: false)
            if selectedTargetIsBrowser { await refreshBrowserMedia() }
            guard activeVolumeSession == session else { return }
            let audible = audibleBundleIDs()
            volumeSession?.replace(target: hookedVolumeEntry(),
                                   apps: playingVolumeApps(audible: audible), tabs: browserVolumeTabs())
            volumeSession?.select(.hookedTarget)
            showVolumeSessionHUD()
        }
    }

    /// A browser parent is not a transport target. With no remembered media,
    /// an explicit Play can discover one exact tab and move the picker to it.
    private func browserNeedingPlaybackDiscovery(_ source: VolumeSource) -> BrowserKind? {
        guard let bundleID = volumeSourceBundleID(source),
              let browser = BrowserKind.browser(bundleID: bundleID) else { return nil }
        switch source {
        case .browserTab: return nil
        case .hookedTarget where selectedBrowserMediaCandidate != nil: return nil
        default: break
        }
        guard !activeBrowserMediaCandidates.contains(where: {
            $0.browser == browser && $0.supportsTransport
        }) else { return nil }
        return browser
    }

    static func discoveredPlaybackCandidate(_ candidates: [BrowserMediaCandidate]) -> BrowserMediaCandidate? {
        let playable = candidates.filter { $0.supportsTransport && $0.volume != nil }
        return playable.first(where: \.isPlaying) ?? playable.first
    }

    private func discoverAndPlay(_ browser: BrowserKind, source: VolumeSource, session: UInt64) async {
        let scan = await pollRunner.run { [browserMediaController] in browserMediaController.scan(browser) }
        guard activeVolumeSession == session, volumeSession?.selected?.source == source,
              scan.injectionAvailable, let candidate = Self.discoveredPlaybackCandidate(scan.candidates) else { return }
        activeBrowserMediaCandidates.removeAll { $0.browser == browser }
        activeBrowserMediaCandidates.append(candidate)
        if !candidate.isPlaying {
            let started = await scripting.run { [browserMediaController] in
                browserMediaController.play(candidate)
            }
            guard started else { return }
            noteBrowserPlaybackToggled(candidate)
        }
        _ = recentBrowserSources(from: activeBrowserMediaCandidates.filter { $0.browser == browser }, browser: browser)
        guard activeVolumeSession == session else { return }
        let audible = audibleBundleIDs()
        volumeSession?.replace(target: hookedVolumeEntry(),
                               apps: playingVolumeApps(audible: audible), tabs: browserVolumeTabs())
        volumeSession?.select(.browserTab(id: candidate.id))
        showVolumeSessionHUD()
    }

    private var pickerPlaybackInFlight = false
    private var pendingPickerPlayback: (source: VolumeSource, bundleID: String?, playing: Bool)?

    private func togglePickerPlayback() {
        guard !pickerPlaybackInFlight, let source = volumeSession?.selected?.source,
              let session = activeVolumeSession else { return }
        if let browser = browserNeedingPlaybackDiscovery(source) {
            pickerPlaybackInFlight = true
            Task {
                defer { pickerPlaybackInFlight = false }
                await discoverAndPlay(browser, source: source, session: session)
            }
            return
        }
        guard canPlayPauseVolumeSource(source) else { return }
        let context = playbackTargetContext
        let candidate: BrowserMediaCandidate?
        if case .browserTab(let id) = source { candidate = browserCandidate(id: id) }
        else { candidate = nil }
        let previous = volumeSourceIsPlaying(source)
        pendingPickerPlayback = (source, volumeSourceBundleID(source), !previous)
        refreshVolumeSourceActivity()
        pickerPlaybackInFlight = true
        Task {
            defer {
                pickerPlaybackInFlight = false
                pendingPickerPlayback = nil
                refreshVolumeSourceActivity()
            }
            switch source {
            case .hookedTarget:
                // Never fall back to the system's unrelated now-playing app.
                if selectedTargetIsBrowser && browserMediaInjectionAvailable != true { return }
                if await togglePlayPauseTarget(in: context),
                   context == playbackTargetContext, !selectedTargetIsBrowser,
                   let bundleID = volumeSourceBundleID(source) {
                    notePlayback(bundleID: bundleID, playing: !previous)
                }
            case .app(let bundleID):
                if await togglePlayPause(bundleID: bundleID) {
                    notePlayback(bundleID: bundleID, playing: !previous)
                }
            case .browserTab:
                if let candidate, candidate.supportsTransport {
                    _ = await toggleBrowserPlayPause(candidate)
                }
            }
            if activeVolumeSession == session { showVolumeSessionHUD() }
        }
    }

    private func beginVolumeSessionIfNeeded() {
        if volumeSession == nil {
            let audible = audibleBundleIDs()
            let list = VolumeSourceList(target: hookedVolumeEntry(),
                                        apps: playingVolumeApps(audible: audible),
                                        tabs: browserVolumeTabs())
            // Nothing to pick: no session, so the keys keep their usual rule
            // instead of being held for a list with no rows.
            guard !list.entries.isEmpty else { return }
            volumeSessionGeneration &+= 1
            sessionTabVolumes = [:]
            volumeSession = list
            startVolumeSessionRefresh(audible: audible)
            startSpotifyTrackRefresh()
        }
    }

    func refreshSpotifyTrack() async {
        guard isRunning(bundleID: "com.spotify.client") else {
            spotifyTrack = ""
            HookHUD.shared.updateSpotifyTrack("")
            return
        }
        let track = await metadataRunner.run {
            AppleScriptExecutor().run("""
            if application id "com.spotify.client" is not running then return ""
            tell application id "com.spotify.client"
                try
                    if player state is stopped then return ""
                    set trackArtist to (artist of current track) as text
                    set trackTitle to (name of current track) as text
                    return trackArtist & " — " & trackTitle
                on error
                    return ""
                end try
            end tell
            """).output ?? ""
        }
        guard !Task.isCancelled else { return }
        spotifyTrack = track
        if volumeSession != nil { HookHUD.shared.updateSpotifyTrack(track) }
    }

    private func startSpotifyTrackRefresh() {
        spotifyTrackRefresh?.cancel()
        spotifyTrackRefresh = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.volumeSession != nil else { return }
                if self.volumeSession?.entries.contains(where: {
                    self.volumeSourceBundleID($0.source) == "com.spotify.client"
                }) == true {
                    await self.refreshSpotifyTrack()
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func showVolumeSessionHUD() {
        guard let session = volumeSession else { return }
        let rows = session.entries.map {
            HookHUD.SourceRow(name: $0.name,
                              percent: currentVolume(of: $0.source),
                              muted: isProcessMuted($0.source),
                              canMute: canMuteVolumeSource($0.source),
                              indented: $0.parentSource != nil,
                              sourceID: $0.source.id,
                              isEmitting: volumeSourceIsEmitting($0.source),
                              isHooked: $0.source == .hookedTarget,
                              isPlaying: volumeSourceIsPlaying($0.source),
                              canPlayPause: canPlayPauseVolumeSource($0.source),
                              nowPlaying: volumeSourceBundleID($0.source) == "com.spotify.client" ? spotifyTrack : nil)
        }
        HookHUD.shared.showVolumeSources(rows, selectedIndex: session.selectedIndex)
    }

    private func canMuteVolumeSource(_ source: VolumeSource) -> Bool {
        switch source {
        case .hookedTarget: return targetCanTakeMute
        case .app(let bundleID): return perAppMuteEnabled && isRunning(bundleID: bundleID)
        case .browserTab(let id): return tabVolume(id: id) != nil
        }
    }

    /// Cached volume for a row; the session refresh fills these in.
    func currentVolume(of source: VolumeSource) -> Int? {
        switch source {
        case .hookedTarget:
            if selectedTargetIsBrowser, let candidate = selectedBrowserMediaCandidate {
                return candidate.volume
            }
            return targetManager.targetBundleID.flatMap { cachedAppVolume(bundleID: $0) }
        case .app(let bundleID):
            return cachedAppVolume(bundleID: bundleID)
        case .browserTab(let id):
            return tabVolume(id: id)
        }
    }

    /// A row's per-app (process-tap) mute. Read from the controller itself
    /// rather than the `mutedApps` mirror, which only catches up a run-loop
    /// turn later — too late for the redraw right after a toggle.
    private func isProcessMuted(_ source: VolumeSource) -> Bool {
        guard #available(macOS 14.2, *), perAppMuteEnabled else { return false }
        let bundleID: String?
        switch source {
        case .hookedTarget: bundleID = targetManager.targetBundleID
        case .app(let id): bundleID = id
        case .browserTab: bundleID = nil
        }
        return bundleID.map { muteController.isMuted($0) } ?? false
    }

    private func hookedVolumeEntry() -> VolumeSourceEntry? {
        guard let def = currentTargetDefinition(), isRunning(bundleID: def.bundleID) else { return nil }
        let name = selectedTargetIsBrowser
            ? (selectedBrowserMediaCandidate?.label ?? def.displayName)
            : def.displayName
        let parent: VolumeSource? = selectedTargetIsBrowser && selectedBrowserMediaCandidate != nil
            ? .app(bundleID: def.bundleID) : nil
        return VolumeSourceEntry(source: .hookedTarget, name: name, parentSource: parent)
    }

    // Use the menu's row ordering in the picker as well.
    func playingAppRows(_ playingApps: [PlayingApp]) -> [PlayingApp] {
        if !perAppMuteEnabled { recordAppPlayback(Set(playingApps.map(\.bundleID))) }
        let targetBundleID = targetManager.targetBundleID
        var seen = Set<String>()
        var out: [PlayingApp] = []
        for app in playingApps where seen.insert(app.bundleID).inserted {
            // Prefer a known app's own name (e.g. "Apple Music") over the OS process
            // name ("Music") so the label is the same whether it's playing or just open.
            let name = availableApps.first { $0.bundleID == app.bundleID }?.displayName ?? app.displayName
            out.append(PlayingApp(id: app.bundleID, displayName: name, bundleID: app.bundleID))
        }
        let scriptableRunning = availableApps
            .filter { volumeScriptable(bundleID: $0.bundleID) && isRunning(bundleID: $0.bundleID) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        for def in scriptableRunning where seen.insert(def.bundleID).inserted {
            out.append(PlayingApp(id: def.bundleID, displayName: def.displayName, bundleID: def.bundleID))
        }
        // Muted apps stay listed while they run, even once silent — a muted app
        // stops appearing "recently playing", and the unmute button must not
        // vanish along with the sound it silenced.
        if perAppMuteEnabled {
            for bid in mutedApps.union(processVolumeLevels.keys).sorted()
            where !seen.contains(bid) && isRunning(bundleID: bid) {
                seen.insert(bid)
                let name = availableApps.first { $0.bundleID == bid }?.displayName
                    ?? runningAppName(bundleID: bid)
                    ?? bid
                out.append(PlayingApp(id: bid, displayName: name, bundleID: bid))
            }
        }
        // A silent browser still needs its parent row while recent tabs remain.
        for bid in recentlyActiveAppIDs().sorted()
        where !seen.contains(bid) && isRunning(bundleID: bid) {
            seen.insert(bid)
            let name = availableApps.first { $0.bundleID == bid }?.displayName
                ?? runningAppName(bundleID: bid) ?? bid
            out.append(PlayingApp(id: bid, displayName: name, bundleID: bid))
        }
        if let targetBundleID,
           let targetIndex = out.firstIndex(where: { $0.bundleID == targetBundleID }),
           targetIndex != 0 {
            out.insert(out.remove(at: targetIndex), at: 0)
        }
        return out
    }

    /// The compact menu has no separate target picker/play button. Keep its
    /// target visible even when quit (Play can launch it), and retain running
    /// transport-only players after pausing so their resume button stays put.
    func menuAppRows(_ playingApps: [PlayingApp]) -> [PlayingApp] {
        var rows = playingAppRows(playingApps)
        var seen = Set(rows.map(\.bundleID))
        for definition in availableApps where isRunning(bundleID: definition.bundleID)
            && canPlayPauseVolumeSource(.app(bundleID: definition.bundleID))
            && seen.insert(definition.bundleID).inserted {
            rows.append(PlayingApp(id: definition.bundleID, displayName: definition.displayName,
                                   bundleID: definition.bundleID))
        }
        if let target = currentTargetDefinition() {
            rows.removeAll { $0.bundleID == target.bundleID }
            rows.insert(PlayingApp(id: target.bundleID, displayName: target.displayName,
                                   bundleID: target.bundleID), at: 0)
        }
        return rows
    }

    private func refreshRecentOverlaySources() {
        guard var updated = volumeSession else { return }
        updated.replace(target: hookedVolumeEntry(),
                        apps: playingVolumeApps(audible: Set(volumePickerApps.map(\.bundleID))),
                        tabs: browserVolumeTabs())
        guard updated != volumeSession else { return }
        volumeSession = updated
        showVolumeSessionHUD()
    }

    private var volumePickerApps: [PlayingApp] = []

    /// Bundle ids with a live audio output stream. Before macOS 14.2 there's no
    /// per-process audio API, so every running supported browser stands in (its
    /// tabs are still scanned) and no other apps are offered.
    private func audibleBundleIDs() -> Set<String> {
        if #available(macOS 14.2, *) {
            let monitor = AudioProcessMonitor()
            monitor.refresh()
            volumePickerApps = playingAppRows(monitor.playingApps)
            return Set(volumePickerApps.map(\.bundleID))
        }
        return Set(BrowserKind.allCases.map(\.bundleID).filter { isRunning(bundleID: $0) })
    }

    /// Every other sounding app, including mute-only apps and browsers whose
    /// tabs cannot be scanned. Browser tabs also offer individual volume control.
    private func playingVolumeApps(audible: Set<String>) -> [VolumeSourceEntry] {
        let targetBundleID = targetManager.targetBundleID
        let parents = Set(browserVolumeTabs().compactMap { entry -> String? in
            if case .app(let id)? = entry.parentSource { return id }
            return nil
        })
        let hookedBrowser = selectedTargetIsBrowser && selectedBrowserMediaCandidate != nil
        var ordered = volumePickerApps.map(\.bundleID)
        let missing = audible.union(parents).union(hookedBrowser ? Set([targetBundleID].compactMap { $0 }) : [])
            .subtracting(ordered)
        ordered.append(contentsOf: missing.sorted())
        let recent = recentlyActiveAppIDs().union(parents)
        return ordered
            .filter { recent.contains($0) || $0 == targetBundleID }
            .filter { $0 != targetBundleID || hookedBrowser }
            .map { bundleID in
                VolumeSourceEntry(source: .app(bundleID: bundleID),
                                  name: volumePickerApps.first { $0.bundleID == bundleID }?.displayName
                                      ?? availableApps.first { $0.bundleID == bundleID }?.displayName
                                      ?? runningAppName(bundleID: bundleID) ?? bundleID)
            }
    }

    /// Tabs with a volume from the last active-browser scan, minus the hooked tab.
    private func browserVolumeTabs() -> [VolumeSourceEntry] {
        let hookedTabID = selectedTargetIsBrowser ? selectedBrowserMediaID : nil
        return activeBrowserMediaCandidates
            .filter { $0.volume != nil && $0.id != hookedTabID }
            .map { VolumeSourceEntry(source: .browserTab(id: $0.id),
                                     name: $0.label,
                                     parentSource: $0.browser.bundleID == targetManager.targetBundleID
                                         && selectedBrowserMediaCandidate == nil
                                         ? .hookedTarget : .app(bundleID: $0.browser.bundleID)) }
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
                if let bundleID, BrowserKind.browser(bundleID: bundleID) == nil,
                   let playing = await self.isPlaying(bundleID: bundleID),
                   !Task.isCancelled, !self.pickerPlaybackInFlight {
                    self.notePolledPlayback(bundleID: bundleID, playing: playing)
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

    /// Browser app rows control all of that browser's audio through a process
    /// tap. Its child tab rows keep their independent JavaScript volume controls.
    /// Other apps use process gain only when they have no native volume API.
    func usesProcessVolume(bundleID: String) -> Bool {
        guard #available(macOS 14.2, *), perAppMuteEnabled else { return false }
        return BrowserKind.browser(bundleID: bundleID) != nil || !volumeScriptable(bundleID: bundleID)
    }

    func canControlVolume(bundleID: String) -> Bool {
        if usesProcessVolume(bundleID: bundleID) {
            return mutePermissionGranted != false && processVolumeErrors[bundleID] == nil
        }
        return BrowserKind.browser(bundleID: bundleID) == nil && volumeScriptable(bundleID: bundleID)
    }

    private func cachedAppVolume(bundleID: String) -> Int? {
        if #available(macOS 14.2, *), usesProcessVolume(bundleID: bundleID) {
            guard mutePermissionGranted != false, processVolumeErrors[bundleID] == nil else { return nil }
            return muteController.volume(for: bundleID)
        }
        guard BrowserKind.browser(bundleID: bundleID) == nil else { return nil }
        return volumeScriptable(bundleID: bundleID) ? volumeByBundle[bundleID] : nil
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
        if usesProcessVolume(bundleID: bundleID) { return .slider }
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
        updateVolumeRouting()
        if on,
           tap.volumeKeysHijacked,
           let def = currentTargetDefinition(),
           def.bundleID == bundleID {
            HookHUD.shared.show(appName: def.displayName, commandHint: commandVolumeHint)
        }
    }

    /// The volume keys are hijacked for the target only when it exposes a scriptable
    /// volume AND the user has explicitly enabled it for that app. `targetCanTakeVolume`
    /// gates both routings on the app actually running, so a quit target hands the
    /// keys back to macOS instead of swallowing presses that could do nothing.
    private func updateVolumeRouting() {
        tap.volumeKeysHijacked = VolumeKeyRouting.shouldHijack(
            targetBundleID: targetManager.targetBundleID,
            targetSupportsVolume: targetCanTakeVolume,
            preferences: volumeKeyOverride
        )
        sourcePickerTap.requiresCommand = !tap.volumeKeysHijacked
        HookHUD.shared.pickerRequiresCommand = !tap.volumeKeysHijacked
        tap.commandVolumeRouting = commandVolumeRouting
        tap.targetCanTakeVolume = targetCanTakeVolume
        tap.targetCanTakeMute = targetCanTakeMute
        updateVolumeSessionRouting()
        objectWillChange.send()   // the ⌘ hint in the menu row derives from these
    }

    /// The hooked target exposes a volume Beamhook can drive and is running right
    /// now — the precondition for either routing to swallow a volume key.
    var targetCanTakeVolume: Bool {
        guard let bundleID = targetManager.targetBundleID, isRunning(bundleID: bundleID) else { return false }
        if selectedTargetIsBrowser, let candidate = selectedBrowserMediaCandidate {
            return candidate.volume != nil
        }
        return canControlVolume(bundleID: bundleID)
    }

    /// What ⌘ + a volume key reaches right now, or nil when ⌘ changes nothing.
    /// Drives the hint in the menu row and on the overlay from one source.
    var commandVolumeHint: VolumeKeyDestination? {
        VolumeKeyRouting.commandHintDestination(
            hijacked: tap.volumeKeysHijacked,
            commandRoutingEnabled: commandVolumeRouting,
            targetCanTakeVolume: targetCanTakeVolume)
    }

    /// Volume routing depends on whether the target is running, and nothing else
    /// tells us that: the popover's refresh only runs while it's open, and a key
    /// press can't afford to ask NSWorkspace on the tap thread.
    private func observeTargetPresence() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVolumeRouting() }
            }
            workspaceObservers.append(token)
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { center.removeObserver(token) }
    }
}

/// Bridges the media-key tap's handler to `AppState` without capturing `self` during
/// `AppState.init`. Only touched on the main queue, where the tap dispatches its
/// handler, so the plain `weak var` needs no further synchronization.
private final class KeyHandlerBox {
    weak var state: AppState?
}
