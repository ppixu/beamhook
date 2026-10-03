import SwiftUI
import Combine
import BeamhookKit

private struct MenuRefreshContext: Hashable {
    let targetID: String?
    let isVisible: Bool
}

private struct PlaybackPollContext: Hashable {
    let target: PlaybackTargetContext
    let isVisible: Bool
}

struct MenuContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: UpdaterModel
    @State private var playback = PlaybackStatus()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.hasAccessibility {
                permissionBanner
                Divider()
            }

            Text("Hook media keys to:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Menu {
                Button {
                    state.setTarget(nil)
                } label: {
                    if state.selectedTargetID == nil {
                        Label("Nothing", systemImage: "checkmark")
                    } else {
                        Text("Nothing")
                    }
                }
                Divider()
                ForEach(state.availableApps) { app in
                    Button {
                        state.setTarget(app.id)
                    } label: {
                        Group {
                            if app.id == state.selectedTargetID {
                                Label(app.displayName, systemImage: "checkmark")
                            } else {
                                Text(app.displayName)
                            }
                        }
                        .foregroundStyle(state.isRunning(bundleID: app.bundleID) ? .primary : .secondary)
                    }
                    // An app that isn't on this Mac can't be hooked to anything,
                    // and disabling is also the only styling a menu item honours
                    // here — the foregroundStyle above has no effect on macOS 26.
                    .disabled(!state.isInstalled(bundleID: app.bundleID))
                }
            } label: {
                Text(targetName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton)
            // 21pt is the play/pause button's measured height. The borderless
            // menu style adds no padding of its own, leaving the row 16pt, so the
            // hover pill came out visibly shorter than the button below it. Grow
            // the control rather than just the wash, so the highlight and the
            // area that responds to the pointer stay the same shape.
            .frame(maxWidth: .infinity, minHeight: 21)
            // Behind, not over: this is bare text, and a wash on top would tint
            // the label along with the background.
            .hoverHighlight(cornerRadius: 7, behind: true)
            .accessibilityLabel("Hook media keys to \(targetName)")

            playPauseButton

            if state.selectedTargetIsBrowser {
                if state.browserMediaInjectionAvailable == true {
                    if state.browserMediaCandidates.isEmpty {
                        Text("No playable browser tabs found.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Picker("Browser player", selection: Binding(
                            get: { state.selectedBrowserMediaID ?? state.browserMediaCandidates.first?.id ?? "" },
                            set: { state.selectBrowserMedia($0) })) {
                            ForEach(state.browserMediaCandidates) { candidate in
                                Text((candidate.isPlaying ? "▶ " : "") + candidate.label)
                                    .tag(candidate.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }
                } else if state.browserTargetRunning == false {
                    Text("\(targetName) is not running. macOS will handle play/pause normally.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if state.browserMediaInjectionAvailable == false {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("macOS is choosing the browser player. Enable JavaScript from Apple Events to pick a specific tab in Beamhook.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let helpURL = appleEventsHelpURL {
                            Link("How to enable it", destination: helpURL)
                        }
                    }
                    .font(.caption2)
                }
            }

            // Playing-apps section renders its own leading divider + rows, and
            // nothing at all when nothing is playing.
            PlayingAppsList()

            Divider()
            HStack(spacing: 6) {
                Image("MenuBarIcon")
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                // Always the product name, never the running build's bundle
                // name: "Beamhookdev" is long enough to truncate this row, and
                // the dev build is already identifiable by its app name
                // everywhere macOS lists it.
                Text("Beamhook")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("v\(shortVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                Button {
                    SettingsWindow.shared.show(state: state)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .fixedSize()
            }
        }
        .padding(12)
        // Wide enough for the footer to fit rather than overflow. That row's
        // ideal width is 199pt (icon + "Beamhook" + version + gear + fixedSize
        // Quit + spacings), so 12pt of padding each side puts the floor at
        // 223pt. Narrower and the row draws outside the frame, which is what
        // pushed Quit past the right margin every other control lines up on —
        // Quit is fixedSize, so it overflows instead of truncating. The few
        // points of slack land in the footer's Spacer, keeping the alignment
        // stable if the version string grows a digit.
        .frame(width: 228)
        .onChange(of: state.playbackTargetContext, initial: true) { _, context in
            playback.reset(for: context)
        }
        .task(id: PlaybackPollContext(
            target: state.playbackTargetContext,
            isVisible: state.isMenuVisible
        )) {
            let context = state.playbackTargetContext
            playback.reset(for: context)
            guard state.isMenuVisible, context.targetID != nil else { return }
            while !Task.isCancelled {
                guard let observation = playback.observation(for: context) else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                let latest = await state.isTargetPlaying(in: context)
                guard !Task.isCancelled, context == state.playbackTargetContext else {
                    return
                }
                playback.accept(latest, from: observation)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .task(id: MenuRefreshContext(
            targetID: state.selectedTargetID,
            isVisible: state.isMenuVisible
        )) {
            guard state.isMenuVisible else { return }
            while !Task.isCancelled {
                await state.refreshBrowserMedia()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private var targetName: String {
        let id = state.selectedTargetID
        return state.availableApps.first { $0.id == id }?.displayName ?? "Nothing"
    }

    /// Deep-links to the section for the selected browser: the guide covers Safari
    /// separately from the Chromium browsers, which all share one menu path.
    private var appleEventsHelpURL: URL? {
        let anchor = BrowserKind.target(id: state.selectedTargetID) == .safari ? "safari" : "chrome"
        return URL(string: "https://beamhook.app/help/#\(anchor)")
    }

    private var shortVersion: String {
        let components = updater.version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.last == "0" else { return updater.version }
        return components.dropLast().joined(separator: ".")
    }

    private var playPauseButton: some View {
        Button {
            let context = state.playbackTargetContext
            let previousState = playback.isPlaying
            guard playback.beginToggle(for: context) else { return }
            // The click is the freshest knowledge: let the speaker animation
            // flip with it, not with the settled read that follows.
            if let previousState,
               let bundleID = state.availableApps.first(where: { $0.id == context.targetID })?.bundleID {
                state.notePlayback(bundleID: bundleID, playing: !previousState)
            }
            Task {
                let succeeded = await state.togglePlayPauseTarget(in: context)
                let confirmedState = succeeded
                    ? await state.confirmTargetPlaying(in: context, after: previousState)
                    : nil
                guard context == state.playbackTargetContext else {
                    return
                }
                playback.finishToggle(
                    succeeded: succeeded,
                    confirmedState: confirmedState,
                    previousState: previousState,
                    for: context
                )
            }
        } label: {
            Image(systemName: playback.isPlaying == true ? "pause.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .disabled(state.selectedTargetID == nil
                  || !state.selectedBrowserSourceSupportsTransport
                  || playback.commandInFlight)
        .help(state.selectedBrowserSourceSupportsTransport
              ? (playback.isPlaying == true ? "Pause \(targetName)" : "Play \(targetName)")
              : "This tab is a call, which has no play/pause. Volume still works.")
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility permission needed").font(.headline).foregroundStyle(.red)
            Text("Beamhook needs Accessibility access to capture the media keys.")
                .font(.caption)
            HStack {
                Button("Open Settings") { state.permissions.openAccessibilitySettings() }
                Button("Re-check") { state.refreshPermission() }
            }
        }
    }
}

private struct PlayingAppsList: View {
    var body: some View {
        if #available(macOS 14.2, *) {
            PlayingAppsListAvailable()
        }
    }
}

@available(macOS 14.2, *)
private struct PlayingAppsListAvailable: View {
    @EnvironmentObject var state: AppState
    @StateObject private var monitor = AudioProcessMonitor()

    private var targetBundleID: String? {
        guard let id = state.selectedTargetID else { return nil }
        return state.availableApps.first { $0.id == id }?.bundleID
    }

    private var activeBrowserBundleIDs: Set<String> {
        Set(monitor.playingApps.compactMap {
            BrowserKind.browser(bundleID: $0.bundleID)?.bundleID
        })
    }

    private var browserRefreshID: String {
        ([state.isMenuVisible ? "visible" : "hidden"] + activeBrowserBundleIDs.sorted())
            .joined(separator: ":")
    }

    /// What to show, deduplicated with currently-playing apps first:
    ///   1. apps with a live audio stream (from Core Audio), plus
    ///   2. known volume-scriptable apps (Spotify, Apple Music, VLC, …) that are
    ///      running — so their volume slider stays available while the app is open,
    ///      not only while it's actively making sound.
    /// Non-scriptable apps ("system volume only") appear only while they're
    /// actually emitting audio. Supported browsers resolve to their YouTube
    /// definitions in AudioProcessMonitor, including Safari's WebKit helper.
    private var rows: [PlayingApp] {
        var seen = Set<String>()
        var out: [PlayingApp] = []
        for app in monitor.playingApps where seen.insert(app.bundleID).inserted {
            // Prefer a known app's own name (e.g. "Apple Music") over the OS process
            // name ("Music") so the label is the same whether it's playing or just open.
            let name = state.availableApps.first { $0.bundleID == app.bundleID }?.displayName ?? app.displayName
            out.append(PlayingApp(id: app.bundleID, displayName: name, bundleID: app.bundleID))
        }
        let scriptableRunning = state.availableApps
            .filter { state.volumeScriptable(bundleID: $0.bundleID) && state.isRunning(bundleID: $0.bundleID) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        for def in scriptableRunning where seen.insert(def.bundleID).inserted {
            out.append(PlayingApp(id: def.bundleID, displayName: def.displayName, bundleID: def.bundleID))
        }
        // Muted apps stay listed while they run, even once silent — a muted app
        // stops appearing "recently playing", and the unmute button must not
        // vanish along with the sound it silenced.
        if state.perAppMuteEnabled {
            for bid in state.mutedApps.sorted()
            where !seen.contains(bid) && state.isRunning(bundleID: bid) {
                seen.insert(bid)
                let name = state.availableApps.first { $0.bundleID == bid }?.displayName
                    ?? state.runningAppName(bundleID: bid)
                    ?? bid
                out.append(PlayingApp(id: bid, displayName: name, bundleID: bid))
            }
        }
        if let targetBundleID,
           let targetIndex = out.firstIndex(where: { $0.bundleID == targetBundleID }),
           targetIndex != 0 {
            out.insert(out.remove(at: targetIndex), at: 0)
        }
        return out
    }

    var body: some View {
        // The popover content stays mounted while hidden, so explicitly bind the
        // monitor to its visible lifetime instead of relying on view appearance.
        VStack(alignment: .leading, spacing: 8) {
            let list = rows
            let emittingIDs = Set(monitor.playingApps.map(\.bundleID))
            if !list.isEmpty {
                Divider()
                ForEach(Array(list.enumerated()), id: \.element.id) { index, app in
                    AppVolumeRow(playing: app,
                                 isEmitting: emittingIDs.contains(app.bundleID))
                    if index == 0, app.bundleID == targetBundleID, list.count > 1 {
                        Divider()
                    }
                }
            }
        }
        .task(id: state.isMenuVisible) {
            if state.isMenuVisible {
                monitor.start()
            } else {
                monitor.stop()
            }
        }
        // Rows with no play-state source (no scripting, no tabs) get their EQ
        // animation from the live meter; keep its watchlist matched to the
        // rows on screen, and empty the moment the menu closes.
        .task(id: "\(state.isMenuVisible):\(meterWatchlist.sorted().joined(separator: ","))") {
            state.setMeterWatchlist(state.isMenuVisible ? meterWatchlist : [])
        }
        .task(id: browserRefreshID) {
            guard state.isMenuVisible else {
                await state.refreshActiveBrowserMedia(bundleIDs: [])
                return
            }
            while !Task.isCancelled {
                await state.refreshActiveBrowserMedia(bundleIDs: activeBrowserBundleIDs)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .onDisappear {
            monitor.stop()
            state.setMeterWatchlist([])
        }
    }

    /// Apps whose sound-emission truth needs the meter: no play/pause script
    /// (those report their own state), not muted (arcs are suppressed for
    /// muted rows anyway). Browsers are included on purpose — their tabs
    /// report play state, but a tab with no media element (a Web Audio chime,
    /// a voice chat) is invisible to the scan, and only the meter hears it.
    private var meterWatchlist: Set<String> {
        guard state.perAppMuteEnabled else { return [] }
        return Set(rows.map(\.bundleID).filter { bid in
            !state.availableApps.contains { $0.bundleID == bid && !$0.playPauseScript.isEmpty }
                && !state.mutedApps.contains(bid)
        })
    }
}

@available(macOS 14.2, *)
private struct AppVolumeRow: View {
    @EnvironmentObject var state: AppState
    let playing: PlayingApp
    /// Whether Core Audio currently reports this app with a live output stream
    /// (drives the speaker icon's radiating-arcs animation). Trails reality by
    /// up to one 2s monitor refresh, and a paused app can keep its stream open
    /// for a moment — both fine for an at-a-glance indicator.
    let isEmitting: Bool
    @State private var volume: Double = 50
    @State private var availability: VolumeAvailability = .systemVolumeOnly
    @State private var appIsPlaying: Bool?
    @State private var playPauseInFlight = false

    private var scriptable: Bool { availability == .slider }

    private var isTarget: Bool {
        guard let id = state.selectedTargetID,
              let def = state.availableApps.first(where: { $0.id == id }) else { return false }
        return def.bundleID == playing.bundleID
    }

    private var isBrowser: Bool {
        BrowserKind.browser(bundleID: playing.bundleID) != nil
    }

    private var browserSources: [BrowserMediaCandidate] {
        guard let browser = BrowserKind.browser(bundleID: playing.bundleID) else { return [] }
        // AppState has already ranked and capped each browser's sources by recency.
        return state.activeBrowserMediaCandidates.filter { $0.browser == browser }
    }

    private var supportsDirectPlayPause: Bool {
        !isBrowser && state.availableApps.contains {
            $0.bundleID == playing.bundleID && !$0.playPauseScript.isEmpty
        }
    }

    /// Shown when macOS is blocking the Apple events this app's volume needs —
    /// otherwise a denied permission is indistinguishable from an app that simply
    /// has no volume control, and the fix is two panes deep in System Settings.
    private var permissionHint: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Beamhook isn't allowed to control \(playing.displayName), so its volume is unavailable. The media keys still work.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow in System Settings…") {
                state.permissions.openAutomationSettings()
            }
            .buttonStyle(.link)
            .font(.caption2)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !isTarget && supportsDirectPlayPause {
                    compactPlayPauseButton
                }
                // The hooked app's title is fully opaque; the rest sit back a bit.
                Text(playing.displayName).font(.subheadline)
                    .opacity(isTarget ? 1 : 0.55)
                    .lineLimit(1)
                    // The name is the "go there" control, and covers only the
                    // glyphs — a stray click in the gap beside it does nothing.
                    .overlay(ClickableName { state.activate(bundleID: playing.bundleID) })
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { state.activate(bundleID: playing.bundleID) }
                    .help("Show \(playing.displayName)")
                Spacer(minLength: 2)
                // Browsers expose multiple independently controllable media sources,
                // so their volume always lives in the named child rows below.
                if scriptable && !isTarget && !isBrowser {
                    compactSlider
                }
                if state.perAppMuteEnabled {
                    muteButton
                }
                Button(isTarget ? "Unhook" : "Hook") {
                    if isTarget {
                        state.setTarget(nil)
                    } else {
                        hook()
                    }
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverHighlight(cornerRadius: 5)
                    .help(isTarget ? "Return media-key control to macOS"
                                   : "Send the media keys to this app")
            }
            if scriptable && isTarget && !isBrowser {
                Slider(value: $volume, in: 0...100) { editing in
                    if !editing { state.setVolume(Int(volume), for: playing.bundleID) }
                }
                volumeKeyControls
            } else if isTarget && !isBrowser && browserSources.isEmpty {
                if availability == .permissionDenied {
                    permissionHint
                } else {
                    Text("system volume only").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(browserSources) { candidate in
                BrowserVolumeRow(candidate: candidate)
            }
            // Audible, but no scanned tab is playing: the sound comes from a
            // page with no media element (Web Audio), which no tab row can
            // represent. Say so rather than leave the animation unexplained.
            if isBrowser && !isMuted && state.audibleApps.contains(playing.bundleID)
                && !browserSources.contains(where: \.isPlaying) {
                Text("Sound from a tab with no media player")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
            }
            if scriptable && isTarget && isBrowser {
                volumeKeyControls
            }
        }
        .task(id: state.isMenuVisible) {
            guard state.isMenuVisible else { return }
            if isBrowser {
                // Browser volume is source-specific. We only need the capability
                // flag here; BrowserVolumeRow obtains each source's live volume.
                availability = state.volumeScriptable(bundleID: playing.bundleID)
                    ? .slider : .systemVolumeOnly
                return
            }
            if let cached = state.volumeByBundle[playing.bundleID] {
                volume = Double(cached); availability = .slider
            } else {
                if let v = await state.volume(for: playing.bundleID) {
                    volume = Double(v); availability = .slider
                    state.volumeByBundle[playing.bundleID] = v
                } else {
                    // The read failed. Find out whether that is the app's nature or
                    // a permission the user can give back.
                    availability = await state.volumeAvailability(for: playing.bundleID)
                }
            }
        }
        .onChange(of: state.volumeByBundle[playing.bundleID]) { _, newVal in
            if let v = newVal { volume = Double(v) }
        }
        .task(id: "\(state.isMenuVisible):\(isTarget):\(playing.bundleID)") {
            // Target rows poll too (the popover polls the target separately,
            // but that state lives in MenuContentView): the arcs need a play
            // state for every scriptable row, hooked or not.
            guard state.isMenuVisible, supportsDirectPlayPause else {
                appIsPlaying = nil
                return
            }
            while !Task.isCancelled {
                let latest = await state.isPlaying(bundleID: playing.bundleID)
                if !playPauseInFlight {
                    appIsPlaying = latest
                    // Polls are what keep the hint truthful — it never ages out.
                    if let latest { state.notePolledPlayback(bundleID: playing.bundleID, playing: latest) }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private var compactPlayPauseButton: some View {
        Button {
            guard !playPauseInFlight else { return }
            let wasPlaying = appIsPlaying == true
            appIsPlaying = !wasPlaying
            // The click is the freshest knowledge there is; without this the
            // hint from an earlier poll would outrank it for a few seconds.
            state.notePlayback(bundleID: playing.bundleID, playing: !wasPlaying)
            playPauseInFlight = true
            Task {
                if !(await state.togglePlayPause(bundleID: playing.bundleID)) {
                    appIsPlaying = wasPlaying
                    state.notePlayback(bundleID: playing.bundleID, playing: wasPlaying)
                }
                playPauseInFlight = false
            }
        } label: {
            Image(systemName: appIsPlaying == true ? "pause.fill" : "play.fill")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(playPauseInFlight)
        .foregroundStyle(.secondary)
        .accessibilityLabel(appIsPlaying == true
                            ? "Pause \(playing.displayName)"
                            : "Play \(playing.displayName)")
        .help(appIsPlaying == true
              ? "Pause \(playing.displayName)"
              : "Play \(playing.displayName)")
    }

    private var compactSlider: some View {
        Slider(value: $volume, in: 0...100) { editing in
            if !editing { state.setVolume(Int(volume), for: playing.bundleID) }
        }
        .controlSize(.mini)
        .tint(.gray)
        .frame(width: 52)
        .accessibilityLabel("\(playing.displayName) volume")
        .help("\(playing.displayName) volume: \(Int(volume))%")
    }

    private var isMuted: Bool { state.isAppMuted(playing.bundleID) }

    /// Whether the EQ animation runs: the best available "making sound right
    /// now" signal per kind of app. Core Audio's stream flag (`isEmitting`)
    /// alone is too sticky — a paused player keeps its stream open, and Unity
    /// holds a silent one for a whole play-mode session — so it only gates,
    /// never decides by itself when something better exists:
    ///   browser    → its scanned tabs' play state, or the meter
    ///   scriptable → its polled play state, gated by the stream flag
    ///   the rest   → the live audio meter (see meterWatchlist)
    private var showsEmittingArcs: Bool {
        guard !isMuted else { return false }
        if isBrowser {
            // A playing tab answers instantly and per tab. The meter catches
            // sound from tabs the scan can't see — Web Audio chimes, voice
            // chats — which have no media element to report.
            return browserSources.contains { $0.isPlaying }
                || state.audibleApps.contains(playing.bundleID)
        }
        if supportsDirectPlayPause {
            // Freshest first: a state learned from a toggle or click seconds
            // ago beats this row's own 1.5s poll.
            if let hinted = state.playbackHint(for: playing.bundleID) { return hinted }
            guard let playing = appIsPlaying else { return isEmitting }
            return playing
        }
        return state.audibleApps.contains(playing.bundleID)
    }

    /// Process-tap mute: silences the whole app at the audio HAL, so it works on
    /// apps with no scripting at all. Browser tabs still get their own sliders —
    /// this button mutes the entire browser.
    ///
    /// Muted wins over emitting: a muted app still renders audio (into the
    /// tap), but animating its icon would suggest the mute isn't working.
    private var muteButton: some View {
        Button {
            state.setAppMuted(!isMuted, bundleID: playing.bundleID)
        } label: {
            Group {
                if isMuted {
                    Image(systemName: "speaker.slash.fill")
                } else if showsEmittingArcs {
                    EmittingSpeakerIcon(seed: playing.bundleID)
                } else {
                    Image(systemName: "speaker.fill")
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isMuted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .hoverHighlight(cornerRadius: 4)
        .accessibilityLabel(isMuted
                            ? "Unmute \(playing.displayName)"
                            : "Mute \(playing.displayName)")
        .help(isMuted
              ? "Unmute \(playing.displayName)"
              : "Mute \(playing.displayName) — silences only this app")
    }

    private var volumeKeyControls: some View {
        HStack(spacing: 6) {
            Toggle("Volume keys", isOn: Binding(
                get: { state.volumeKeysEnabled(bundleID: playing.bundleID) },
                set: { state.setVolumeKeysEnabled($0, bundleID: playing.bundleID) }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
                .help("Route the hardware volume keys to this app while it's the hooked target")
            // ⌘ always leads to the volume the plain keys don't: the system
            // while this app is hooked, this app while it isn't.
            if let hint = state.commandVolumeHint {
                let target = hint == .system ? "system" : playing.displayName
                HStack(spacing: 2) {
                    Text("⌘ +").fixedSize()
                    Image(systemName: "speaker.wave.2.fill").fixedSize()
                    Text("for \(target)").lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Command plus Volume for \(target)")
            }
        }
    }

    /// Hook the media keys to this app. If it's a known app, just select it;
    /// otherwise open the Add-an-app window prefilled with its details.
    private func hook() {
        if let def = state.availableApps.first(where: { $0.bundleID == playing.bundleID }) {
            state.setTarget(def.id)
        } else {
            AddAppWindow.shared.show(state: state,
                                     prefillName: playing.displayName,
                                     prefillBundleID: playing.bundleID)
        }
    }
}

/// The "this is making sound" indicator: a speaker whose arcs jump like an EQ
/// meter. SF Symbols' `variableValue` lights 0–3 arcs while keeping the
/// symbol's geometry stable, so the flicker never shifts the row's layout.
/// The levels are a fixed loop (cheap, deterministic); `seed` offsets each
/// icon's position in it so neighboring rows don't pulse in lockstep.
private struct EmittingSpeakerIcon: View {
    let seed: String

    private static let levels: [Double] = [0.67, 1.0, 0.34, 0.67, 1.0, 0.67, 0.34, 1.0, 0.67, 0.34]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.15) + abs(seed.hashValue)
            Image(systemName: "speaker.wave.3.fill",
                  variableValue: Self.levels[tick % Self.levels.count])
        }
    }
}

@available(macOS 14.2, *)
private struct BrowserVolumeRow: View {
    @EnvironmentObject var state: AppState
    let candidate: BrowserMediaCandidate
    @State private var volume: Double = 50
    @State private var isEditing = false
    @State private var sourceIsPlaying = false
    @State private var playPauseInFlight = false

    private var browserIsTarget: Bool {
        BrowserKind.target(id: state.selectedTargetID) == candidate.browser
    }

    private func focus() {
        Task { await state.focusBrowserSource(candidate) }
    }

    var body: some View {
        HStack(spacing: 6) {
            // A call tab keeps its slider but never gets a play/pause button:
            // pausing a live MediaStream would only freeze the meeting.
            if !browserIsTarget && candidate.supportsTransport {
                compactPlayPauseButton
            }
            Text(candidate.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .overlay(ClickableName { focus() })
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { focus() }
                // Titles truncate here, so the tooltip still has to carry the full
                // one — it gains the action rather than being replaced by it.
                .help("Switch to this tab: \(candidate.label)")
            if sourceIsPlaying {
                EmittingSpeakerIcon(seed: candidate.sourceID)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Playing")
            }
            Spacer(minLength: 2)
            Slider(value: $volume, in: 0...100) { editing in
                isEditing = editing
                if !editing {
                    state.setBrowserVolume(Int(volume), for: candidate)
                }
            }
            .controlSize(.mini)
            .tint(.gray)
            .frame(width: 58)
            .accessibilityLabel("\(candidate.label) volume")
            .help(candidate.isPlaying
                  ? "\(candidate.label) volume: \(Int(volume))%"
                  : "\(candidate.label) volume while paused: \(Int(volume))%")
        }
        .padding(.leading, 8)
        .task(id: candidate.id) {
            sourceIsPlaying = candidate.isPlaying
            if let value = candidate.volume { volume = Double(value) }
        }
        .onChange(of: candidate.isPlaying) { _, newValue in
            if !playPauseInFlight { sourceIsPlaying = newValue }
        }
        .onChange(of: candidate.volume) { _, newValue in
            if !isEditing, let newValue { volume = Double(newValue) }
        }
    }

    private var compactPlayPauseButton: some View {
        Button {
            guard !playPauseInFlight else { return }
            let previous = sourceIsPlaying
            sourceIsPlaying.toggle()
            playPauseInFlight = true
            Task {
                if !(await state.toggleBrowserPlayPause(candidate)) {
                    sourceIsPlaying = previous
                }
                playPauseInFlight = false
            }
        } label: {
            Image(systemName: sourceIsPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(playPauseInFlight)
        .foregroundStyle(.secondary)
        .accessibilityLabel(sourceIsPlaying
                            ? "Pause \(candidate.label)"
                            : "Play \(candidate.label)")
        .help(sourceIsPlaying
              ? "Pause \(candidate.label)"
              : "Play \(candidate.label)")
    }
}
