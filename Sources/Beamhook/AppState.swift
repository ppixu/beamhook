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
    @Published var hasAccessibility: Bool = false
    /// Passive AppleScript reads are useful only while the user can see their
    /// results. Keeping the real popover lifecycle here prevents a newly launched
    /// target from causing an Automation permission prompt in the background.
    @Published private(set) var isMenuVisible: Bool = false
    @Published var loginItemEnabled: Bool = LoginItem.isEnabled
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
        default:
            guard let command = key.command else { return }
            if selectedTargetIsBrowser, browserMediaInjectionAvailable == true {
                guard let candidate = selectedBrowserMediaCandidate,
                      candidate.supportsTransport
                else { return }
                Task { _ = await performBrowserCommand(command, on: candidate) }
            } else {
                Task { _ = await targetManager.route(key) }
            }
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
            return await scripting.run {
                guard app.isReady else { return false }
                app.perform(.playPause)
                return true
            }
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
                let appName = availableApps.first { $0.bundleID == result.bundleID }?.displayName
                    ?? result.bundleID
                HookHUD.shared.showVolume(appName: appName, percent: result.volume)
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
    }
}

/// Bridges the media-key tap's handler to `AppState` without capturing `self` during
/// `AppState.init`. Only touched on the main queue, where the tap dispatches its
/// handler, so the plain `weak var` needs no further synchronization.
private final class KeyHandlerBox {
    weak var state: AppState?
}
