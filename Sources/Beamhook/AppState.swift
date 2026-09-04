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
    @Published var browserMediaInjectionAvailable: Bool?
    @Published var browserTargetRunning: Bool?
    @Published var browserMediaCandidates: [BrowserMediaCandidate] = [] {
        didSet { updateMenuBarGlyph() }
    }
    @Published var selectedBrowserMediaID: String? {
        didSet {
            if selectedBrowserMediaID != oldValue { playbackContextRevision &+= 1 }
            updateMenuBarGlyph()
        }
    }
    /// Volume-controllable browser tabs for browsers whose Core Audio process
    /// currently has an output stream. Populated only while the menu is visible.
    @Published var activeBrowserMediaCandidates: [BrowserMediaCandidate] = []
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
        if PerAppMutePreference.isEnabled(.standard), #available(macOS 14.2, *) {
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
        case .mute:       toggleTargetMute()
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
            revision: playbackContextRevision
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
    @Published private(set) var playbackHints: [String: PlaybackHint] = [:]
    /// Apps with a toggle in flight. A poll that lands mid-toggle would read
    /// the state we just left (Spotify keeps reporting "paused" for a beat
    /// after play while it buffers) and stomp the optimistic hint, so polled
    /// results are ignored for these until the confirm read settles them.
    private var playbackSettling: Set<String> = []

    /// Authoritative: a click, a key press, or a settled confirm read.
    func notePlayback(bundleID: String, playing: Bool) {
        playbackHints[bundleID] = PlaybackHint(playing: playing, at: Date())
    }

    /// From a periodic poll — dropped while that app's toggle is settling.
    func notePolledPlayback(bundleID: String, playing: Bool) {
        guard !playbackSettling.contains(bundleID) else { return }
        notePlayback(bundleID: bundleID, playing: playing)
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
            if notingHint, let result, context == playbackTargetContext {
                notePolledPlayback(bundleID: app.bundleID, playing: result)
            }
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
        let performed = await scripting.run { [browserMediaController] in
            browserMediaController.perform(command, on: candidate)
        }
        if performed, command == .playPause {
            noteBrowserPlaybackToggled(candidate)
        }
        return performed
    }

    func setTarget(_ id: String?) {
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
        // Confirm the new hook with a centre-screen HUD (user-initiated, so always).
        if let def = currentTargetDefinition() {
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
        controller.$permissionGranted
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.mutePermissionGranted = $0 }
            .store(in: &cancellables)
        controller.$audibleApps
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.audibleApps = $0 }
            .store(in: &cancellables)
        muteControllerStorage = controller
        return controller
    }

    /// The popover's list of apps that need live audibility (no play state to
    /// ask for): while the menu is open the mute controller meters exactly
    /// these; an empty set tears the meters down.
    func setMeterWatchlist(_ bundleIDs: Set<String>) {
        guard #available(macOS 14.2, *), perAppMuteEnabled else { return }
        muteController.setMeterWatchlist(bundleIDs)
    }

    func setPerAppMute(_ on: Bool) {
        perAppMuteEnabled = on
        PerAppMutePreference.setEnabled(on, in: .standard)
        defer {
            updateVolumeRouting()   // the tap's mute-key routing follows the setting
            updateMenuBarGlyph()
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
        guard #available(macOS 14.2, *), perAppMuteEnabled,
              let bundleID = targetManager.targetBundleID else { return }
        let nowMuted = !isAppMuted(bundleID)
        muteController.setMuted(nowMuted, bundleID: bundleID)
        if let def = currentTargetDefinition() {
            HookHUD.shared.showMute(appName: def.displayName, muted: nowMuted)
        }
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
                let appName = availableApps.first { $0.bundleID == result.bundleID }?.displayName
                    ?? result.bundleID
                // With the plain keys hooked, the overlay teaches the escape hatch.
                // Reached by ⌘ instead, it would only echo the chord just pressed.
                HookHUD.shared.showVolume(appName: appName,
                                          percent: result.volume,
                                          commandHint: tap.volumeKeysHijacked ? .system : nil)
            }
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
            targetSupportsVolume: targetManager.targetSupportsVolume,
            preferences: volumeKeyOverride
        )
        tap.commandVolumeRouting = commandVolumeRouting
        tap.targetCanTakeVolume = targetCanTakeVolume
        tap.targetCanTakeMute = targetCanTakeMute
        objectWillChange.send()   // the ⌘ hint in the menu row derives from these
    }

    /// The hooked target exposes a volume Beamhook can drive and is running right
    /// now — the precondition for either routing to swallow a volume key.
    var targetCanTakeVolume: Bool {
        guard targetManager.targetSupportsVolume,
              let bundleID = targetManager.targetBundleID else { return false }
        return isRunning(bundleID: bundleID)
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
