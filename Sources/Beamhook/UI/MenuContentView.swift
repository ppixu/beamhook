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

/// The NSPopover supplies the system's glass material. Keep the content transparent
/// so the compact rows inherit the same Liquid Glass appearance as the old menu.
struct MenuContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: UpdaterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if !state.hasAccessibility {
                permissionBanner
                Divider().padding(.horizontal, 8)
            }
            PlayingAppsList()
            Button(state.showAllMenuApps ? "Show less" : "Show all") {
                state.showAllMenuApps.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            browserNotice
            Divider().padding(.horizontal, 8)
            volumeKeyControls
        }
        .padding(8)
        .frame(width: 300)
        .task(id: state.isMenuVisible) {
            guard state.isMenuVisible else { return }
            while !Task.isCancelled {
                await state.refreshMenuPlayback()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .task(id: state.isMenuVisible) {
            guard state.isMenuVisible else { return }
            while !Task.isCancelled {
                await state.refreshSpotifyTrack()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .task(id: MenuRefreshContext(targetID: state.selectedTargetID,
                                     isVisible: state.isMenuVisible)) {
            guard state.isMenuVisible else { return }
            while !Task.isCancelled {
                await state.refreshBrowserMedia()
                await state.refreshQuickTimeMovies()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private var target: AppDefinition? {
        state.availableApps.first { $0.id == state.selectedTargetID }
    }

    private var header: some View {
        HStack {
            Text("Beamhook").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            moreOptions
        }
        .padding(.leading, 9)
        .padding(.trailing, 3)
    }

    private var moreOptions: some View {
        StableOptionsButton(state: state, version: updater.version)
            .frame(width: 24, height: 24)
    }

    private var volumeKeysOn: Bool {
        target.map { state.volumeKeysEnabled(bundleID: $0.bundleID) } ?? false
    }

    private var volumeKeyControls: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Volume keys").font(.system(size: 12))
                if (state.commandVolumeRouting || volumeKeysOn), target != nil {
                    let name = volumeTargetName
                    HStack(spacing: 3) {
                        if !volumeKeysOn { Text("⌘ +") }
                        Image(systemName: "speaker.wave.2.fill")
                        Text("→ \(name)").lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(volumeKeysOn ? "" : "Command plus ")Volume for \(name)")
                    .help("\(volumeKeysOn ? "" : "Command plus ")Volume for \(name)")
                } else if target == nil {
                    Text("Hook an app to route volume keys")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Toggle("Volume keys", isOn: Binding(
                get: { volumeKeysOn },
                set: { enabled in
                    if let target { state.setVolumeKeysEnabled(enabled, bundleID: target.bundleID) }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!state.targetCanTakeVolume)
                .help("Route volume keys to the hooked app; Command + volume controls system volume")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private var volumeTargetName: String {
        if state.selectedTargetIsBrowser,
           let tab = state.browserMediaCandidates.first(where: { $0.id == state.selectedBrowserMediaID }) {
            return tab.label
        }
        return target?.displayName ?? "app"
    }

    @ViewBuilder private var browserNotice: some View {
        if state.selectedTargetIsBrowser {
            if state.browserTargetRunning == false {
                Text("\(target?.displayName ?? "Browser") is not running. macOS handles play/pause.")
                    .font(.caption2).foregroundStyle(.secondary).padding(8)
            } else if state.browserMediaInjectionAvailable == false {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Enable JavaScript from Apple Events to control individual tabs. macOS handles play/pause until then.")
                        .foregroundStyle(.secondary)
                    let anchor = BrowserKind.target(id: state.selectedTargetID) == .safari ? "safari" : "chrome"
                    Link("How to enable it", destination: URL(string: "https://beamhook.app/help/#\(anchor)")!)
                }
                .font(.caption2).fixedSize(horizontal: false, vertical: true).padding(8)
            } else if state.browserMediaInjectionAvailable == true && state.browserMediaCandidates.isEmpty {
                Text("No playable browser tabs found.")
                    .font(.caption2).foregroundStyle(.secondary).padding(8)
            }
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility permission needed").font(.headline).foregroundStyle(.red)
            Text("Beamhook needs Accessibility access to capture the media keys.").font(.caption)
            HStack {
                Button("Open Settings") { state.permissions.openAccessibilitySettings() }
                Button("Re-check") { state.refreshPermission() }
            }
        }
        .padding(8)
    }
}

private struct PlayingAppsList: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if #available(macOS 14.2, *) {
            PlayingAppsListAvailable()
        } else {
            MenuAppRows(apps: state.showAllMenuApps ? state.menuAppRows([]) : state.recentAppRows(state.menuAppRows([])), emittingIDs: [])
        }
    }
}

private struct MenuAppRows: View {
    let apps: [PlayingApp]
    let emittingIDs: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if apps.isEmpty {
                Text("No audio apps open")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
            }
            ForEach(apps) { app in
                AppVolumeRow(playing: app, isEmitting: emittingIDs.contains(app.bundleID))
            }
        }
    }
}

@available(macOS 14.2, *)
private struct PlayingAppsListAvailable: View {
    @EnvironmentObject var state: AppState
    @StateObject private var monitor = AudioProcessMonitor()

    private var rows: [PlayingApp] { state.menuAppRows(monitor.playingApps) }
    private var activeBrowserBundleIDs: Set<String> {
        Set(rows.compactMap { BrowserKind.browser(bundleID: $0.bundleID)?.bundleID })
    }
    private var browserRefreshID: String {
        ([state.isMenuVisible ? "visible" : "hidden"] + activeBrowserBundleIDs.sorted()).joined(separator: ":")
    }
    private var meterWatchlist: Set<String> {
        guard state.perAppMuteEnabled else { return [] }
        return Set(rows.map(\.bundleID).filter {
            !state.mutedApps.contains($0)
        })
    }

    var body: some View {
        MenuAppRows(apps: state.showAllMenuApps ? rows : state.recentAppRows(rows),
                    emittingIDs: Set(monitor.playingApps.map(\.bundleID)))
            .task(id: state.isMenuVisible) {
                if state.isMenuVisible { monitor.start() } else { monitor.stop() }
            }
            .task(id: "\(state.isMenuVisible):\(meterWatchlist.sorted().joined(separator: ","))") {
                state.setMeterWatchlist(state.isMenuVisible ? meterWatchlist : [])
            }
            .task(id: browserRefreshID) {
                guard state.isMenuVisible else { return }
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
}

/// The same template asset used by the overlay. Only the hooked row shows it;
/// other rows keep its slot empty so names stay aligned when the hook moves.
private struct HookRowLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let name: String
    let hooked: Bool
    var indented = false
    var track: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            HookRowGlyph(tint: colorScheme == .dark ? .white : .black)
                .frame(width: 18, height: 18)
                .frame(width: 13, height: 16)
                .opacity(hooked ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hooked)
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: indented ? 11 : 12, weight: hooked ? .semibold : .regular))
                .lineLimit(1).truncationMode(.tail)
            if let track {
                HookHUD.TrackTicker(text: track)
                    .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Draw the master at the backing display's resolution, like the overlay's
/// AppKit attachment. Avoid SwiftUI's template-image resizing and fractional
/// scale animation, which leave the small hook with jagged edges.
private struct HookRowGlyph: NSViewRepresentable {
    let tint: NSColor

    func makeNSView(context: Context) -> GlyphView { GlyphView() }

    func updateNSView(_ view: GlyphView, context: Context) {
        view.tint = tint
    }

    final class GlyphView: NSView {
        private let glyph = NSImage(named: "HookGlyph")
        var tint: NSColor = .black { didSet { needsDisplay = true } }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let glyph else { return }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current?.imageInterpolation = .high
            let context = NSGraphicsContext.current?.cgContext
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
            glyph.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            tint.setFill()
            bounds.fill(using: .sourceAtop)
            context?.endTransparencyLayer()
        }
    }
}

/// Keep the native slider interactive while explaining why its source is quiet.
private struct MenuVolumeSlider: View {
    @Binding var volume: Double
    let isMuted: Bool
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        Slider(value: $volume, in: 0...100, onEditingChanged: onEditingChanged)
            .controlSize(.mini).tint(.gray)
            .opacity(isMuted ? 0.25 : 1)
            .overlay {
                if isMuted {
                    Text("Muted")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 64)
            .accessibilityValue(isMuted ? "Muted" : "\(Int(volume)) percent")
    }
}

private struct AppVolumeRow: View {
    @EnvironmentObject var state: AppState
    let playing: PlayingApp
    let isEmitting: Bool
    @State private var volume: Double = 50
    @State private var isEditing = false
    @State private var availability: VolumeAvailability = .systemVolumeOnly
    @State private var playback = PlaybackStatus()

    private var isTarget: Bool { state.targetManager.targetBundleID == playing.bundleID }
    private var isBrowser: Bool { BrowserKind.browser(bundleID: playing.bundleID) != nil }
    private var isHooked: Bool {
        isTarget && !browserSources.contains { $0.id == state.selectedBrowserMediaID }
    }
    private var automationDenied: Bool { state.automationDeniedBundleIDs.contains(playing.bundleID) }
    private var canPlayPause: Bool { state.canPlayPauseVolumeSource(.app(bundleID: playing.bundleID)) }
    private var canChangeVolume: Bool {
        state.isRunning(bundleID: playing.bundleID) && state.canControlVolume(bundleID: playing.bundleID)
            && (state.usesProcessVolume(bundleID: playing.bundleID) || availability == .slider)
    }
    private var isMuted: Bool { state.isAppMuted(playing.bundleID) || volume == 0 }
    private var playbackContext: PlaybackTargetContext {
        isTarget ? state.playbackTargetContext
            : PlaybackTargetContext(targetID: playing.bundleID, browserMediaID: nil, revision: 0)
    }
    private var browserSources: [BrowserMediaCandidate] {
        guard let browser = BrowserKind.browser(bundleID: playing.bundleID) else { return [] }
        var sources = state.activeBrowserMediaCandidates.filter { $0.browser == browser }
        // Keep an explicitly hooked tab visible even before the active-source scan
        // catches up, or when its player does not expose a volume property.
        if isTarget, let selected = state.browserMediaCandidates.first(where: { $0.id == state.selectedBrowserMediaID }),
           !sources.contains(where: { $0.id == selected.id }) {
            sources.append(selected)
        }
        return sources.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button(action: hook) {
                    HookRowLabel(name: playing.displayName, hooked: isHooked,
                                 track: playing.bundleID == "com.spotify.client"
                                     ? (state.isMenuVisible ? state.spotifyTrack : "") : nil)
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 6, behind: true)
                .help(isTarget ? "Release media keys from \(playing.displayName)" : "Hook media keys to \(playing.displayName)")
                .accessibilityLabel(isTarget ? "Release media keys from \(playing.displayName)" : "Hook media keys to \(playing.displayName)")
                .contextMenu {
                    Button("Show \(playing.displayName)") { state.activate(bundleID: playing.bundleID) }
                }
                if canPlayPause {
                    playPauseButton
                } else {
                    Color.clear.frame(width: 22, height: 22).accessibilityHidden(true)
                }
                muteButton
                MenuVolumeSlider(volume: $volume, isMuted: isMuted) { editing in
                    isEditing = editing
                    if !editing { state.setVolume(Int(volume), for: playing.bundleID) }
                }
                .disabled(!canChangeVolume)
                .accessibilityLabel("\(playing.displayName) volume\(isBrowser ? ", all tabs" : "")")
                .help(canChangeVolume
                      ? (isMuted ? "Muted · adjust volume to unmute" : "\(playing.displayName) volume: \(Int(volume))%")
                      : "Volume unavailable")
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.primary.opacity(isHooked ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 9))

            if isTarget && !state.isRunning(bundleID: playing.bundleID) && !isBrowser {
                Text(state.launchTargetOnPlay ? "Play to launch \(playing.displayName)" : "\(playing.displayName) is not running")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 9)
            }
            if availability == .permissionDenied || automationDenied {
                Button("Allow control of \(playing.displayName)…") { state.permissions.openAutomationSettings() }
                    .buttonStyle(.link).font(.caption2).padding(.horizontal, 9)
            }
            if let error = state.processVolumeErrors[playing.bundleID] {
                Text(error).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 9)
            }
            if state.usesProcessVolume(bundleID: playing.bundleID), state.mutePermissionGranted == false {
                Button("Allow System Audio Recording…") { state.permissions.openAudioCaptureSettings() }
                    .buttonStyle(.link).font(.caption2).padding(.horizontal, 9)
            }
            if isTarget && state.selectedTargetIsQuickTime {
                if state.quickTimeScanFailed {
                    Text("Cannot read QuickTime movies. Check Automation access in System Settings.")
                        .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 9)
                } else if state.quickTimeMovies.isEmpty {
                    Text("No playable QuickTime movies open.")
                        .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 9)
                } else {
                    Picker("QuickTime movie", selection: Binding(
                        get: { state.selectedQuickTimeMovieID ?? "" },
                        set: { state.selectQuickTimeMovie($0) })) {
                        ForEach(state.quickTimeMovies) { movie in
                            Text((movie.isPlaying ? "▶ " : "") + movie.title).tag(movie.id)
                        }
                    }
                    .pickerStyle(.menu).controlSize(.small).padding(.horizontal, 9)
                }
            }
            ForEach(browserSources) { candidate in BrowserVolumeRow(candidate: candidate) }
        }
        .task(id: "\(state.isMenuVisible):\(state.perAppMuteEnabled):\(automationDenied)") {
            guard state.isMenuVisible else { return }
            if let value = await state.volume(for: playing.bundleID) {
                if !isEditing { volume = Double(value) }
                availability = .slider
            } else {
                availability = await state.volumeAvailability(for: playing.bundleID)
            }
        }
        .onChange(of: state.volumeByBundle[playing.bundleID]) { _, value in
            if !isEditing, let value { volume = Double(value) }
        }
        .onChange(of: state.processVolumeLevels[playing.bundleID]) { _, value in
            if !isEditing, let value { volume = Double(value) }
        }
        .task(id: PlaybackPollContext(target: playbackContext, isVisible: state.isMenuVisible)) {
            let context = playbackContext
            playback.reset(for: context)
            guard state.isMenuVisible, canPlayPause else { return }
            while !Task.isCancelled {
                if let observation = playback.observation(for: context) {
                    let latest = isTarget
                        ? await state.isTargetPlaying(in: context)
                        : await state.isPlaying(bundleID: playing.bundleID)
                    guard !Task.isCancelled, context == playbackContext else { return }
                    playback.accept(latest, from: observation)
                    if !playback.commandInFlight {
                        state.notePolledPlayback(bundleID: playing.bundleID, playing: playback.isPlaying)
                    }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            if automationDenied {
                state.permissions.openAutomationSettings()
                return
            }
            let context = playbackContext
            let previous = playback.isPlaying
            guard playback.beginToggle(for: context) else { return }
            if let previous { state.notePlayback(bundleID: playing.bundleID, playing: !previous) }
            let targetContext = state.playbackTargetContext
            let wasTarget = isTarget
            Task {
                let succeeded = wasTarget
                    ? await state.togglePlayPauseTarget(in: targetContext)
                    : await state.togglePlayPause(bundleID: playing.bundleID)
                let confirmed: Bool?
                if succeeded && wasTarget {
                    confirmed = await state.confirmTargetPlaying(in: targetContext, after: previous)
                } else if succeeded {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    confirmed = await state.isPlaying(bundleID: playing.bundleID)
                } else {
                    confirmed = nil
                }
                guard context == playbackContext else { return }
                playback.finishToggle(succeeded: succeeded, confirmedState: confirmed,
                                      previousState: previous, for: context)
                if !succeeded { state.notePolledPlayback(bundleID: playing.bundleID, playing: previous) }
            }
        } label: {
            Image(systemName: automationDenied ? "lock.fill" : PlaybackStatus.symbol(for: playback.isPlaying))
                .font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight(cornerRadius: 5, behind: true)
        .disabled(playback.commandInFlight)
        .accessibilityLabel(automationDenied ? "Allow control of \(playing.displayName)"
                            : PlaybackStatus.actionLabel(for: playback.isPlaying, name: playing.displayName))
        .help(automationDenied ? "Allow control of \(playing.displayName) in System Settings"
              : PlaybackStatus.actionLabel(for: playback.isPlaying, name: playing.displayName))
    }

    private var showsEmittingArcs: Bool {
        guard !isMuted else { return false }
        if isBrowser { return browserSources.contains(where: \.isPlaying) || state.audibleApps.contains(playing.bundleID) }
        if canPlayPause { return state.playbackHint(for: playing.bundleID) ?? playback.isPlaying ?? isEmitting }
        return state.audibleApps.contains(playing.bundleID)
    }

    private var muteButton: some View {
        Button { state.setAppMuted(!state.isAppMuted(playing.bundleID), bundleID: playing.bundleID) } label: {
            Group {
                if isMuted { Image(systemName: "speaker.slash.fill") }
                else if showsEmittingArcs { EmittingSpeakerIcon(seed: playing.bundleID, volume: Int(volume)) }
                else { Image(systemName: "speaker.fill") }
            }
            .font(.system(size: 9, weight: .semibold)).frame(width: 22, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .hoverHighlight(cornerRadius: 5, behind: true)
        .disabled(!state.perAppMuteEnabled || !state.isRunning(bundleID: playing.bundleID))
        .accessibilityLabel("\(state.isAppMuted(playing.bundleID) ? "Unmute" : "Mute") \(playing.displayName)")
        .help(state.perAppMuteEnabled ? "\(state.isAppMuted(playing.bundleID) ? "Unmute" : "Mute") \(playing.displayName)" : "Enable per-app volume and mute in Settings")
    }

    private func hook() {
        if isTarget { state.setTarget(nil) }
        else if let definition = state.availableApps.first(where: { $0.bundleID == playing.bundleID }) {
            state.setTarget(definition.id)
        } else {
            AddAppWindow.shared.show(state: state, prefillName: playing.displayName, prefillBundleID: playing.bundleID)
        }
    }
}

/// Each active arc pulses independently. Volume determines how many arcs are
/// active; audible sources always retain at least the innermost arc.
struct EmittingSpeakerIcon: View {
    let seed: String
    let volume: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let phase = Double(UInt(bitPattern: seed.hashValue) % 100) / 100
            let activeArcs = max(1, min(3, Int(ceil(Double(volume) / 100 * 3))))
            HStack(spacing: 1) {
                Image(systemName: "speaker.fill")
                ZStack {
                    ForEach(0..<3) { arc in
                        SpeakerArc(index: arc)
                            .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round))
                            .opacity(arc < activeArcs
                                     ? (reduceMotion ? 1 : 0.45 + 0.55 * (sin(time * 9 + phase - Double(arc) * 1.8) + 1) / 2)
                                     : 0.12)
                    }
                }
                .frame(width: 7, height: 12)
            }
        }
    }

    private struct SpeakerArc: Shape {
        let index: Int
        func path(in rect: CGRect) -> Path {
            let scale = CGFloat(index + 1) / 3
            let x = CGFloat(index) * rect.width / 3
            let halfHeight = rect.height * 0.48 * scale
            return Path { path in
                path.move(to: CGPoint(x: x, y: rect.midY - halfHeight))
                path.addQuadCurve(to: CGPoint(x: x, y: rect.midY + halfHeight),
                                  control: CGPoint(x: x + rect.width * 0.55 * scale, y: rect.midY))
            }
        }
    }
}

private struct BrowserVolumeRow: View {
    @EnvironmentObject var state: AppState
    let candidate: BrowserMediaCandidate
    @State private var volume: Double = 50
    @State private var restoreVolume: Double = 50
    @State private var isEditing = false
    @State private var sourceIsPlaying = false
    @State private var playPauseInFlight = false
    @State private var hookInFlight = false

    private var isHooked: Bool {
        BrowserKind.target(id: state.selectedTargetID) == candidate.browser && state.selectedBrowserMediaID == candidate.id
    }
    private var isMuted: Bool { volume == 0 }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if isHooked { state.setTarget(nil) }
                else {
                    hookInFlight = true
                    Task {
                        _ = await state.hookBrowserMedia(candidate)
                        hookInFlight = false
                    }
                }
            } label: {
                HookRowLabel(name: candidate.label, hooked: isHooked, indented: true)
            }
            .buttonStyle(.plain).hoverHighlight(cornerRadius: 6, behind: true)
            .disabled(hookInFlight)
            .accessibilityLabel(isHooked ? "\(candidate.label), hooked. Release media keys" : "Hook media keys to \(candidate.label)")
            .help(isHooked ? "Release media keys from \(candidate.label)" : "Hook media keys to \(candidate.label)")
            .contextMenu {
                Button("Show this tab") { Task { await state.focusBrowserSource(candidate) } }
            }
            // Live calls expose volume but must never expose a pause action.
            if candidate.supportsTransport {
                playPauseButton
            } else {
                Color.clear.frame(width: 22, height: 22).accessibilityHidden(true)
            }
            Button {
                if isMuted { volume = restoreVolume }
                else { restoreVolume = volume; volume = 0 }
                state.setBrowserVolume(Int(volume), for: candidate)
            } label: {
                Group {
                    if isMuted { Image(systemName: "speaker.slash.fill") }
                    else if sourceIsPlaying { EmittingSpeakerIcon(seed: candidate.sourceID, volume: Int(volume)) }
                    else { Image(systemName: "speaker.fill") }
                }
                .font(.system(size: 9, weight: .semibold)).frame(width: 22, height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .hoverHighlight(cornerRadius: 5, behind: true)
            .disabled(candidate.volume == nil)
            .accessibilityLabel("\(isMuted ? "Unmute" : "Mute") \(candidate.label)")
            .help("\(isMuted ? "Unmute" : "Mute") \(candidate.label)")
            MenuVolumeSlider(volume: $volume, isMuted: isMuted) { editing in
                isEditing = editing
                if !editing { state.setBrowserVolume(Int(volume), for: candidate) }
            }
            .disabled(candidate.volume == nil)
            .accessibilityLabel("\(candidate.label) volume")
            .help(isMuted ? "Muted · adjust volume to unmute" : "\(candidate.label) volume: \(Int(volume))%")
        }
        .padding(.leading, 23).padding(.trailing, 7).padding(.vertical, 1)
        .background(Color.primary.opacity(isHooked ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 9))
        .task(id: candidate.id) {
            sourceIsPlaying = candidate.isPlaying
            if let value = candidate.volume {
                volume = Double(value)
                if value > 0 { restoreVolume = Double(value) }
            }
        }
        .onChange(of: candidate.isPlaying) { _, value in
            if !playPauseInFlight { sourceIsPlaying = value }
        }
        .onChange(of: candidate.volume) { _, value in
            if !isEditing, let value {
                if volume > 0 && value == 0 { restoreVolume = volume }
                volume = Double(value)
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            guard !playPauseInFlight else { return }
            let previous = sourceIsPlaying
            sourceIsPlaying.toggle()
            playPauseInFlight = true
            Task {
                if !(await state.toggleBrowserPlayPause(candidate)) { sourceIsPlaying = previous }
                playPauseInFlight = false
            }
        } label: {
            Image(systemName: sourceIsPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight(cornerRadius: 5, behind: true)
        .disabled(playPauseInFlight)
        .accessibilityLabel("\(sourceIsPlaying ? "Pause" : "Play") \(candidate.label)")
        .help("\(sourceIsPlaying ? "Pause" : "Play") \(candidate.label)")
    }
}

/// Snapshot options when clicked. SwiftUI's live Menu can replace its submenu
/// during meter/playback updates; a tracked NSMenu keeps its items stable.
private struct StableOptionsButton: NSViewRepresentable {
    let state: AppState
    let version: String

    func makeCoordinator() -> Coordinator { Coordinator(state: state, version: version) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)!,
                              target: context.coordinator, action: #selector(Coordinator.openMenu(_:)))
        button.isBordered = false
        button.toolTip = "More Beamhook options"
        button.setAccessibilityLabel("More Beamhook options")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.state = state
        context.coordinator.version = version
    }

    @MainActor
    final class Coordinator: NSObject {
        var state: AppState
        var version: String

        init(state: AppState, version: String) {
            self.state = state
            self.version = version
        }

        @objc func openMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            func add(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
                item.target = self
                menu.addItem(item)
                return item
            }
            add("Release media keys", action: #selector(releaseKeys)).isEnabled = state.selectedTargetID != nil
            let apps = NSMenu(title: "Hook another app")
            apps.autoenablesItems = false
            for app in state.availableApps {
                let item = NSMenuItem(title: app.displayName, action: #selector(hookApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app.id
                item.state = app.id == state.selectedTargetID ? .on : .off
                item.isEnabled = state.isInstalled(bundleID: app.bundleID)
                apps.addItem(item)
            }
            let appMenu = NSMenuItem(title: "Hook another app", action: nil, keyEquivalent: "")
            appMenu.submenu = apps
            menu.addItem(appMenu)
            _ = add("Add app…", action: #selector(addApp))
            menu.addItem(.separator())
            _ = add("Settings…", action: #selector(settings), key: ",")
            _ = add("Quit Beamhook", action: #selector(quit), key: "q")
            menu.addItem(.separator())
            let versionItem = NSMenuItem(title: "Beamhook \(version)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
        }

        @objc private func hookApp(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            state.setTarget(id)
        }
        @objc private func releaseKeys() { state.setTarget(nil) }
        @objc private func addApp() { AddAppWindow.shared.show(state: state) }
        @objc private func settings() { SettingsWindow.shared.show(state: state) }
        @objc private func quit() { NSApplication.shared.terminate(nil) }
    }
}
