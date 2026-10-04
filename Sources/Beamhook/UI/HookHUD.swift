import AppKit
import SwiftUI
import os
import BeamhookKit

/// A transient, click-through overlay for hook confirmations and app-specific
/// volume changes. Styled like the modern macOS volume HUD, it drops down below
/// the menu bar near Beamhook's status item without taking focus.
@MainActor
final class HookHUD {
    static let shared = HookHUD()
    private init() {}

    /// Watches the system theme so the panel can be rebuilt when it flips.
    private var appearanceObservation: NSKeyValueObservation?

    /// One row of the volume-source picker. `percent` nil means the volume
    /// is unavailable (or hasn't been read yet). `muted` is the app's per-app (process-tap) mute;
    /// a volume of 0 reads as muted too, which is how a tab is muted.
    struct SourceRow: Equatable {
        let name: String
        let percent: Int?
        var muted = false
        var canMute = false
        var indented = false
        var sourceID = ""
        var isEmitting = false
        var isHooked = false
        var isPlaying = false
        var canPlayPause = false
        var nowPlaying: String? = nil

        var statusText: String {
            if percent == nil {
                return "Volume unavailable · " + (muted ? "Muted" : canMute ? "Mute available" : "Mute unavailable")
            }
            return isMuted ? "Muted" : percent.map { "\($0) percent" } ?? "Volume unavailable"
        }

        var isMuted: Bool { muted || percent == 0 }
    }

    /// Reuses the menu's exact animation; only its surrounding size/color differ.
    private struct SourceSpeakerIcon: View {
        let seed: String
        let isMuted: Bool
        let canMute: Bool
        var isEmitting: Bool
        var volume: Int

        var body: some View {
            Group {
                if isMuted { Image(systemName: "speaker.slash.fill") }
                else if isEmitting { EmittingSpeakerIcon(seed: seed, volume: volume) }
                else { Image(systemName: "speaker.fill") }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color(nsColor: canMute ? .labelColor : .tertiaryLabelColor))
            .frame(width: 20, height: 16)
            .accessibilityHidden(true)
        }
    }

    struct TrackTicker: View {
        var text: String
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var started = Date()

        var body: some View {
            GeometryReader { geometry in
                let width = (text as NSString).size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11)
                ]).width
                let scrolling = width > geometry.size.width && !reduceMotion && !text.isEmpty
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !scrolling)) { timeline in
                    let elapsed = max(0, timeline.date.timeIntervalSince(started) - 1.5)
                    let offset = scrolling ? (elapsed * 22).truncatingRemainder(dividingBy: width + 24) : 0
                    HStack(spacing: 24) {
                        Text(text).fixedSize()
                        if scrolling { Text(text).fixedSize() }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .labelColor).opacity(0.5))
                    .offset(x: -offset)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                    .clipped()
                }
            }
            .onChange(of: text) { _, _ in started = Date() }
            .accessibilityLabel(text)
        }
    }

    private var sourceTickers: [String: NSHostingView<TrackTicker>] = [:]

    /// Update in place so polling does not reset the HUD's dismissal timer.
    func updateSpotifyTrack(_ text: String) {
        for ticker in sourceTickers.values where ticker.rootView.text != text {
            ticker.rootView.text = text
        }
    }

    private var sourceSpeakers: [String: NSHostingView<SourceSpeakerIcon>] = [:]
    private var sourceBars: [String: VolumeBarView] = [:]
    private var sourcePlaybackIcons: [String: NSImageView] = [:]

    func updateSourcePlayback(_ playback: [String: Bool?]) {
        for (id, playing) in playback {
            sourcePlaybackIcons[id]?.image = playing.flatMap { Self.playbackStateSymbol($0) }
        }
    }

    private static func playbackStateSymbol(_ playing: Bool) -> NSImage? {
        NSImage(systemSymbolName: playing ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }

    /// Activity updates must not call `show`: that would reset the hide deadline,
    /// rebuild the list, and scroll back to the selected row on every meter tick.
    func updateSourceActivity(_ activity: [String: Bool]) {
        for (id, view) in sourceSpeakers {
            let emitting = activity[id] ?? false
            if view.rootView.isEmitting != emitting { view.rootView.isEmitting = emitting }
            if sourceBars[id]?.isEmitting != emitting { sourceBars[id]?.isEmitting = emitting }
        }
    }

    private enum Presentation {
        /// `commandHint` is what ⌘ + a volume key reaches from here, or nil when
        /// ⌘ changes nothing and the hint line stays hidden.
        case hooked(appName: String, commandHint: VolumeKeyDestination?)
        case volume(appName: String, percent: Int, commandHint: VolumeKeyDestination?)
        /// The volume-source picker: one row per source, one selected.
        case volumeSources(rows: [SourceRow], selectedIndex: Int)
        case launching(appName: String)
        /// `isPlaying` is nil when the app reports no play state — the glyph then
        /// stays neutral rather than claiming a direction it doesn't know.
        case playback(appName: String, isPlaying: Bool?, subtitle: String)
        /// A play/pause press the tap handed back to macOS while a browser was
        /// hooked. The notice names why, so the key controlling another app
        /// reads as the system routing it — not as Beamhook misfiring.
        case passthrough(appName: String, notice: PassthroughNotice)
        /// A routed mute key flipped the hooked app's process-tap mute.
        case mute(appName: String, muted: Bool)

        var appName: String {
            switch self {
            case .hooked(let appName, _), .volume(let appName, _, _),
                 .launching(let appName), .playback(let appName, _, _),
                 .passthrough(let appName, _), .mute(let appName, _): appName
            case .volumeSources(let rows, let selectedIndex):
                rows.indices.contains(selectedIndex) ? rows[selectedIndex].name : "volume sources"
            }
        }

        var isVolume: Bool {
            switch self {
            case .volume, .volumeSources: true
            default: false
            }
        }

        var hideDelay: TimeInterval {
            switch self {
            case .hooked(_, let commandHint): commandHint == nil ? 2.0 : 3.0
            case .volume: 1.5
            case .volumeSources: 2.5
            case .launching: 2.0
            case .playback: 1.4
            case .mute: 1.4
            // The remediation line is a sentence; leave time to read it.
            case .passthrough(let appName, let notice):
                HookHUD.noticeText(notice, appName: appName) == nil ? 1.8 : 4.0
            }
        }
    }

    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "HUD")

    /// Screen frame of the menu-bar status item, so we can anchor under it.
    /// Set by the AppDelegate once the status item exists.
    var menuBarAnchor: (() -> NSRect?)?
    /// Frame of Beamhook's open menu popover. When present, the HUD sits beside
    /// it rather than covering the controls the user is interacting with.
    var menuPopoverFrame: (() -> NSRect?)?
    /// Invoked when a hook confirmation appears — the AppDelegate uses it to run
    /// the status-item "fishing bob" animation at the same time.
    var onPresent: (() -> Void)?
    /// Arms picker shortcuts for any visible HUD, including playback and hook confirmations.
    var onVisibilityChange: ((Bool) -> Void)?
    /// Told when a volume presentation appears or is hidden/replaced, so the
    /// source session can end independently of the general keyboard shortcuts.
    var onVolumeVisibilityChange: ((Bool) -> Void)?
    private var volumeVisible = false

    private func setVolumeVisible(_ visible: Bool) {
        guard visible != volumeVisible else { return }
        volumeVisible = visible
        onVolumeVisibilityChange?(visible)
    }

    private var panel: NSPanel?
    private var label: NSTextField?
    /// The icon-and-title row, visible under every presentation except
    /// `.volumeSources`, which replaces it with the source list.
    private var header: NSView?
    /// "⌘ + <speaker> for system volume" — a row rather than a label, so the
    /// speaker is the same SF Symbol the popover and the menu bar draw. Its
    /// trailing caption names whichever side ⌘ leads to, so the two directions
    /// of the chord can't be advertised the wrong way round.
    private var hintRow: NSStackView?
    private var hintSuffix: NSTextField?
    /// Free-text caption under the title, used by the passthrough presentation
    /// for its remediation line ("Enable JavaScript from Apple Events …").
    private var noticeLabel: NSTextField?
    private var trackSubtitle: NSTextField?
    private var hookIcon: NSImageView?
    private var transportIcon: NSImageView?
    private var volumeRow: NSView?
    private var volumeBar: VolumeBarView?
    /// Shortcut modifiers follow the volume-key routing mode.
    var pickerRequiresCommand = true {
        didSet {
            guard oldValue != pickerRequiresCommand else { return }
            if !pickerRequiresCommand {
                commandReleaseTimer?.invalidate()
                commandReleaseTimer = nil
            }
            guard let stack = pickerHint as? NSStackView else { return }
            let updated = Self.makePickerHint(requiresCommand: pickerRequiresCommand)
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            for view in updated.arrangedSubviews { stack.addArrangedSubview(view) }
            stack.setAccessibilityLabel(updated.accessibilityLabel())
        }
    }
    private var pickerHint: NSView?
    /// The picker's rows; rebuilt on every `.volumeSources` show.
    private var sourceList: NSStackView?
    private var sourceScroll: NSScrollView?
    private var sourceHeight: NSLayoutConstraint?
    private var box: NSView?
    /// The padded stack inside the chrome; its fitting size drives the panel size.
    private var content: NSView?
    private var hideWork: DispatchWorkItem?
    private var commandReleaseTimer: Timer?
    private var generation = 0

    /// Initialize Liquid Glass at full opacity outside every screen. Rendering
    /// it with near-zero window alpha lets the compositor skip the expensive
    /// backdrop pass, which merely postpones initialization until the first show.
    func prewarm(completion: @escaping @MainActor () -> Void) {
        observeSystemAppearance()
        let panel = ensurePanel()
        if #available(macOS 26.0, *), box is NSGlassEffectView {
            panel.alphaValue = 1
            parkOffscreen(panel)
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak panel] in
                MainActor.assumeIsolated {
                    guard let self, let panel else { return }
                    panel.alphaValue = 0.001
                    self.position(panel)
                    completion()
                }
            }
        } else {
            panel.alphaValue = 0.001
            position(panel)
            panel.orderFrontRegardless()
            completion()
        }
    }

    /// Flash "<appName> hooked" just below the menu bar, under the status item.
    func show(appName: String, commandHint: VolumeKeyDestination? = nil) {
        show(.hooked(appName: appName, commandHint: commandHint))
    }

    /// Show an app-specific volume HUD after a hooked volume-key command succeeds.
    func showVolume(appName: String, percent: Int, commandHint: VolumeKeyDestination? = nil) {
        show(.volume(appName: appName,
                     percent: min(100, max(0, percent)),
                     commandHint: commandHint))
    }

    /// Poll the physical modifier state so a release during tap installation
    /// or an asynchronous volume read cannot strand the picker on screen.
    func holdUntilCommandRelease() {
        hideWork?.cancel()
        guard commandReleaseTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
                else { return }
                self.commandReleaseTimer?.invalidate()
                self.commandReleaseTimer = nil
                self.hideWork?.cancel()
                self.generation += 1
                self.dismiss(gen: self.generation)
            }
        }
        commandReleaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Show the volume-source picker with `selectedIndex` highlighted.
    func showVolumeSources(_ rows: [SourceRow], selectedIndex: Int) {
        show(.volumeSources(rows: rows, selectedIndex: selectedIndex))
    }

    /// Flash "Starting <appName>…" while a hooked app that wasn't running
    /// launches, so a cold start doesn't read as a dead key press.
    func showLaunching(appName: String) {
        show(.launching(appName: appName))
    }

    /// Confirm a play/pause press: the hooked app's name under a play or pause
    /// glyph. Pass `isPlaying: nil` when the app doesn't report its state.
    @discardableResult
    func showPlayback(appName: String, isPlaying: Bool?, subtitle: String = "") -> Int {
        show(.playback(appName: appName, isPlaying: isPlaying, subtitle: subtitle))
        return generation
    }

    func updatePlaybackSubtitle(_ text: String, generation expected: Int) {
        guard generation == expected, let panel, panel.isVisible else { return }
        trackSubtitle?.stringValue = text
        trackSubtitle?.isHidden = text.isEmpty
        content?.layoutSubtreeIfNeeded()
        if let fitting = content?.fittingSize { panel.setContentSize(fitting) }
        position(panel)
    }

    /// Explain a play/pause press that macOS routed instead of Beamhook.
    func showPassthrough(_ notice: PassthroughNotice, appName: String) {
        show(.passthrough(appName: appName, notice: notice))
    }

    /// Confirm a mute-key press: muting is otherwise only audible by its
    /// absence, which reads as a dead key.
    func showMute(appName: String, muted: Bool) {
        show(.mute(appName: appName, muted: muted))
    }

    /// Point the "⌘ + <speaker> for …" line at whichever volume the chord reaches,
    /// or hide it when ⌘ changes nothing from here.
    private func applyCommandHint(_ destination: VolumeKeyDestination?, appName: String) {
        guard let destination else {
            hintRow?.isHidden = true
            return
        }
        let target = destination == .system ? "system" : appName
        hintSuffix?.stringValue = "for \(target) volume"
        hintRow?.setAccessibilityLabel("Command plus Volume for \(target) volume")
        hintRow?.isHidden = false
    }

    /// The one-line remediation under the passthrough title; nil when there is
    /// nothing actionable to add.
    nonisolated private static func noticeText(_ notice: PassthroughNotice, appName: String) -> String? {
        switch notice {
        case .handledByMacOS:
            return nil
        case .browserNotRunning:
            return "\(appName) isn't running"
        case .enableBrowserJavaScript:
            return "Enable JavaScript from Apple Events to control \(appName)"
        }
    }

    private func show(_ presentation: Presentation) {
        generation += 1
        present(presentation, gen: generation, attempt: 0)
    }

    private func present(_ presentation: Presentation, gen: Int, attempt: Int) {
        guard gen == generation else { return }   // superseded by a newer show

        // At launch the status item's window reports a bogus near-origin frame
        // until the status bar lays it out. Wait for the real icon position (up
        // to ~1.2s) so the panel lands under the Beamhook icon, not at a
        // generic fallback spot.
        if validAnchor() == nil && attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated {
                    self?.present(presentation, gen: gen, attempt: attempt + 1)
                }
            }
            return
        }

        let panel = ensurePanel()
        // Only the passthrough presentation uses the notice line; hide it here
        // so the cases below stay a checklist of what they *do* show.
        noticeLabel?.isHidden = true
        trackSubtitle?.isHidden = true
        header?.isHidden = false
        pickerHint?.isHidden = true
        sourceScroll?.isHidden = true
        updateSourceActivity([:])
        sourceSpeakers = [:]
        sourceBars = [:]
        sourcePlaybackIcons = [:]
        sourceTickers = [:]
        switch presentation {
        case .hooked(let appName, let commandHint):
            label?.stringValue = "\(appName) hooked"
            applyCommandHint(commandHint, appName: appName)
            hookIcon?.isHidden = false
            transportIcon?.isHidden = true
            volumeRow?.isHidden = true
        case .volume(let appName, let percent, let commandHint):
            label?.stringValue = appName
            applyCommandHint(commandHint, appName: appName)
            hookIcon?.isHidden = true
            transportIcon?.isHidden = true
            volumeRow?.isHidden = false
            volumeBar?.percent = percent
            pickerHint?.isHidden = false
        case .volumeSources(let rows, let selectedIndex):
            header?.isHidden = true
            volumeRow?.isHidden = true
            pickerHint?.isHidden = false
            if let sourceList {
                sourceList.arrangedSubviews.forEach { $0.removeFromSuperview() }
                panel.appearance?.performAsCurrentDrawingAppearance {
                    for (index, row) in rows.enumerated() {
                        sourceList.addArrangedSubview(
                            makeSourceRow(row, selected: index == selectedIndex))
                    }
                }
                sourceList.layoutSubtreeIfNeeded()
                let size = sourceList.fittingSize
                sourceList.setFrameSize(size)
                let screenHeight = panel.screen?.visibleFrame.height ?? 700
                sourceHeight?.constant = min(size.height, max(100, screenHeight - 120))
                sourceScroll?.isHidden = false
            }
        case .launching(let appName):
            label?.stringValue = "Starting \(appName)…"
            hintRow?.isHidden = true
            hookIcon?.isHidden = false
            transportIcon?.isHidden = true
            volumeRow?.isHidden = true
        case .playback(let appName, let isPlaying, let subtitle):
            trackSubtitle?.stringValue = subtitle
            trackSubtitle?.isHidden = subtitle.isEmpty
            label?.stringValue = appName
            hintRow?.isHidden = true
            hookIcon?.isHidden = true
            transportIcon?.isHidden = false
            transportIcon?.image = Self.transportSymbol(isPlaying: isPlaying)
            volumeRow?.isHidden = true
        case .mute(let appName, let muted):
            label?.stringValue = muted ? "\(appName) muted" : "\(appName) unmuted"
            hintRow?.isHidden = true
            hookIcon?.isHidden = true
            transportIcon?.isHidden = false
            transportIcon?.image = Self.muteSymbol(muted: muted)
            volumeRow?.isHidden = true
        case .passthrough(let appName, let notice):
            label?.stringValue = "macOS handled Play/Pause"
            if let text = Self.noticeText(notice, appName: appName) {
                noticeLabel?.stringValue = text
                noticeLabel?.isHidden = false
            }
            hintRow?.isHidden = true
            hookIcon?.isHidden = true
            transportIcon?.isHidden = false
            transportIcon?.image = Self.transportSymbol(isPlaying: nil)
            volumeRow?.isHidden = true
        }

        // Size the window to the (variable-width) content, then anchor it.
        content?.layoutSubtreeIfNeeded()
        if let fitting = content?.fittingSize { panel.setContentSize(fitting) }
        position(panel)
        if case .volumeSources(_, let selectedIndex) = presentation,
           let sourceList, sourceList.arrangedSubviews.indices.contains(selectedIndex) {
            sourceList.layoutSubtreeIfNeeded()
            sourceList.scrollToVisible(sourceList.arrangedSubviews[selectedIndex].frame)
        }

        hideWork?.cancel()

        // Present immediately. Unlike NSGlassEffectView, the HUD material does
        // not need an asynchronous backdrop-settling period, so launch-time
        // notifications cannot be lost while waiting for a delayed reveal.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        if case .hooked = presentation { onPresent?() }
        setVolumeVisible(presentation.isVolume)
        onVisibilityChange?(true)
        Self.log.info("HUD shown for \(presentation.appName, privacy: .public); frame=\(NSStringFromRect(panel.frame), privacy: .public)")

        if presentation.isVolume && commandReleaseTimer != nil { return }
        commandReleaseTimer?.invalidate()
        commandReleaseTimer = nil
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(gen: gen) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + presentation.hideDelay, execute: work)
    }

    /// The status-item frame, but only once it really sits in a screen's menu
    /// bar (flush with the top edge) — see `present` for why it can be bogus.
    private func validAnchor() -> (NSRect, NSScreen)? {
        guard let anchor = menuBarAnchor?(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }),
              anchor.maxY >= screen.frame.maxY - 40 else { return nil }
        return (anchor, screen)
    }

    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        let gap: CGFloat = 6, margin: CGFloat = 10

        if let popover = menuPopoverFrame?(),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(popover) }) {
            let left = popover.minX - gap - size.width
            let right = popover.maxX + gap
            let x = left >= screen.frame.minX + margin
                ? left
                : min(right, screen.frame.maxX - size.width - margin)
            let y = min(popover.maxY - size.height,
                        screen.frame.maxY - size.height - margin)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        if let (anchor, screen) = validAnchor() {
            var x = anchor.midX - size.width / 2
            let y = anchor.minY - gap - size.height   // just below the menu bar
            x = min(max(x, screen.frame.minX + margin), screen.frame.maxX - size.width - margin)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let f = (NSScreen.main ?? NSScreen.screens.first)?.frame {
            // Fallback: top-right, just under the menu bar (where the item lives).
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 32 - gap))
        }
    }

    private func parkOffscreen(_ panel: NSPanel) {
        let rightEdge = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        panel.setFrameOrigin(NSPoint(x: rightEdge + panel.frame.width + 100, y: 0))
    }

    private func dismiss(gen: Int) {
        guard gen == generation, let panel else { return }
        setVolumeVisible(false)
        updateSpotifyTrack("")
        onVisibilityChange?(false)
        updateSourceActivity([:])
        // Fade to (near-)invisible but never order out: keeping the window in
        // keeps the glass backdrop warm, so the next show has no first-frame
        // flash while the effect re-initializes.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0.001
        }
    }

    /// An existing glass panel keeps drawing the backdrop it was built under,
    /// even after its appearance is reassigned, so a theme switch left the HUD
    /// in the old look until relaunch. Rebuild and prewarm it instead.
    private func observeSystemAppearance() {
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.rebuildIfAppearanceChanged() }
            }
        }
    }

    private func rebuildIfAppearanceChanged() {
        guard let panel,
              panel.appearance?.name != Self.contrastingAppearance().name
        else { return }
        hideWork?.cancel()
        commandReleaseTimer?.invalidate()
        commandReleaseTimer = nil
        generation += 1
        if panel.alphaValue > 0.01 {
            // Showing mid-switch: report the hide that orderOut skips past.
            setVolumeVisible(false)
            updateSpotifyTrack("")
            onVisibilityChange?(false)
            updateSourceActivity([:])
        }
        panel.orderOut(nil)
        self.panel = nil
        prewarm {}
    }

    /// The opposite of the system appearance, keeping high contrast, plus
    /// whether the system itself is dark.
    private static func contrastingAppearance()
        -> (name: NSAppearance.Name, systemUsesDarkColors: Bool) {
        switch NSApp.effectiveAppearance.bestMatch(from: [
            .aqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
        ]) {
        case .darkAqua: return (.aqua, true)
        case .accessibilityHighContrastDarkAqua: return (.accessibilityHighContrastAqua, true)
        case .accessibilityHighContrastAqua: return (.accessibilityHighContrastDarkAqua, false)
        default: return (.darkAqua, false)
        }
    }

    /// Use the opposite of the system appearance so the HUD stands apart from
    /// the desktop while preserving the user's high-contrast preference.
    private func applyContrastingAppearance(to panel: NSPanel) {
        let (contrastingAppearance, systemUsesDarkColors) = Self.contrastingAppearance()
        // Reassigning an identical appearance makes Liquid Glass rebuild its
        // backdrop, producing a black first frame on the launch notification.
        if panel.appearance?.name != contrastingAppearance {
            panel.appearance = NSAppearance(named: contrastingAppearance)
        }
        // The subtitle follows the system theme: half-opacity black in light
        // mode, white in dark mode. The glass's contrasting tint is separate.
        trackSubtitle?.textColor = (systemUsesDarkColors ? NSColor.white : NSColor.black)
            .withAlphaComponent(0.5)
        if #available(macOS 26.0, *),
           let glass = panel.contentView as? NSGlassEffectView {
            // Glass remains backdrop-adaptive even with a forced appearance, so
            // explicitly bias it toward the opposite luminance as well.
            let tint = (systemUsesDarkColors ? NSColor.white : NSColor.black)
                .withAlphaComponent(0.52)
            if glass.tintColor?.isEqual(tint) != true {
                glass.tintColor = tint
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            applyContrastingAppearance(to: panel)
            return panel
        }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 58),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let icon = NSImageView()
        icon.image = NSImage(named: "HookGlyph")   // template → tinted below
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 15, weight: .semibold)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false

        let transport = NSImageView()
        transport.symbolConfiguration = .init(pointSize: 22, weight: .medium)
        transport.contentTintColor = .labelColor
        transport.imageScaling = .scaleProportionallyDown
        transport.isHidden = true
        transport.translatesAutoresizingMaskIntoConstraints = false
        transport.setContentHuggingPriority(.required, for: .horizontal)

        let (hint, hintSuffix) = Self.makeCommandVolumeHint()
        hint.isHidden = true

        let notice = NSTextField(labelWithString: "")
        notice.font = .systemFont(ofSize: 11, weight: .regular)
        notice.textColor = .secondaryLabelColor
        notice.lineBreakMode = .byTruncatingTail
        notice.isHidden = true
        notice.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: 10, weight: .regular)
        subtitle.textColor = NSColor.labelColor.withAlphaComponent(0.5)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1
        subtitle.cell?.wraps = false
        subtitle.cell?.usesSingleLineMode = true
        subtitle.isHidden = true
        subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true

        let labels = NSStackView(views: [text, subtitle, hint, notice])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        // Hug the lines vertically. Left to its default, this column stretches to
        // the height of the taller glyph beside it and then hangs its content off
        // the top — so with the hint hidden the title sat a line above the glyph
        // it is supposed to sit beside, in every one-line presentation.
        labels.setHuggingPriority(.defaultHigh, for: .vertical)

        let header = NSStackView(views: [icon, transport, labels])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 11
        header.translatesAutoresizingMaskIntoConstraints = false

        let quietSpeaker = NSImageView()
        quietSpeaker.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Low volume")
        quietSpeaker.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        quietSpeaker.contentTintColor = .labelColor
        quietSpeaker.imageScaling = .scaleProportionallyUpOrDown

        let loudSpeaker = NSImageView()
        loudSpeaker.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "High volume")
        loudSpeaker.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        loudSpeaker.contentTintColor = .labelColor
        loudSpeaker.imageScaling = .scaleProportionallyUpOrDown

        let bar = VolumeBarView()
        let volumeStack = NSStackView(views: [quietSpeaker, bar, loudSpeaker])
        volumeStack.orientation = .horizontal
        volumeStack.alignment = .centerY
        volumeStack.spacing = 8
        volumeStack.isHidden = true

        let sources = NSStackView()
        sources.orientation = .vertical
        sources.alignment = .leading
        sources.spacing = 4
        let sourceScroll = NSScrollView()
        sourceScroll.drawsBackground = false
        sourceScroll.hasVerticalScroller = false
        sourceScroll.documentView = sources
        sourceScroll.isHidden = true
        sourceScroll.translatesAutoresizingMaskIntoConstraints = false
        let sourceHeight = sourceScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            sourceScroll.widthAnchor.constraint(equalToConstant: 368),
            sourceHeight,
        ])

        let picker = Self.makePickerHint(requiresCommand: pickerRequiresCommand)
        picker.isHidden = true

        let stack = NSStackView(views: [header, volumeStack, sourceScroll, picker])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The padded content, chrome-agnostic (its fitting size sizes the panel).
        let content = NSView()
        content.addSubview(stack)
        let iconScale: CGFloat = 1.15
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 26 * iconScale),
            icon.heightAnchor.constraint(equalToConstant: 30 * iconScale),
            // Same box as the hook glyph, so the title starts on one x whichever
            // of the two leads the row.
            transport.widthAnchor.constraint(equalToConstant: 26 * iconScale),
            transport.heightAnchor.constraint(equalToConstant: 30 * iconScale),
            quietSpeaker.widthAnchor.constraint(equalToConstant: 18),
            quietSpeaker.heightAnchor.constraint(equalToConstant: 18),
            bar.widthAnchor.constraint(equalToConstant: 172),
            bar.heightAnchor.constraint(equalToConstant: 7),
            loudSpeaker.widthAnchor.constraint(equalToConstant: 22),
            loudSpeaker.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])

        let chrome: NSView
        if #available(macOS 26.0, *) {
            // Keep the system's regular optical treatment; applyContrastingAppearance
            // supplies the opposite light/dark tint after this becomes contentView.
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 24
            glass.contentView = content
            chrome = glass
            // Liquid Glass supplies its own adaptive shadow and rim. A second
            // NSWindow shadow produces the heavy outline seen in earlier builds.
            panel.hasShadow = false
        } else {
            let frosted = NSVisualEffectView()
            frosted.material = .hudWindow
            frosted.blendingMode = .behindWindow
            frosted.state = .active
            frosted.maskImage = Self.roundedMask(radius: 24)
            content.frame = frosted.bounds
            content.autoresizingMask = [.width, .height]
            frosted.addSubview(content)
            chrome = frosted
        }

        panel.contentView = chrome
        self.trackSubtitle = subtitle
        applyContrastingAppearance(to: panel)
        self.panel = panel
        self.label = text
        self.header = header
        self.hintRow = hint
        self.hintSuffix = hintSuffix
        self.noticeLabel = notice
        self.hookIcon = icon
        self.transportIcon = transport
        self.volumeRow = volumeStack
        self.volumeBar = bar
        self.pickerHint = picker
        self.sourceList = sources
        self.sourceScroll = sourceScroll
        self.sourceHeight = sourceHeight
        self.box = chrome
        self.content = content
        return panel
    }

    /// An 11pt secondary-label caption, used by every hint row's text
    /// fragments. Not an accessibility element itself — the row that contains
    /// it composes one label and speaks for all of its pieces.
    private static func caption(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: 11, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.setAccessibilityElement(false)
        return field
    }

    /// "⌘ + <speaker> for … volume", built as a row so the speaker can be
    /// the real `speaker.wave.2.fill` symbol — the same mark the popover's hint
    /// and the menu bar itself use. An emoji speaker sat here before; it drew in
    /// its own colours and at its own weight, ignoring both the HUD's tint and
    /// the surrounding text. The trailing caption is returned alongside the row
    /// because `applyCommandHint` retargets it per presentation.
    private static func makeCommandVolumeHint() -> (row: NSStackView, suffix: NSTextField) {
        let speaker = NSImageView()
        speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                accessibilityDescription: "Volume")
        speaker.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        speaker.contentTintColor = .secondaryLabelColor
        speaker.imageScaling = .scaleNone
        speaker.setContentHuggingPriority(.required, for: .horizontal)
        speaker.setAccessibilityElement(false)

        let suffix = caption("for system volume")
        let row = NSStackView(views: [caption("⌘ +"), speaker, suffix])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 3
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel("Command plus Volume for system volume")
        return (row, suffix)
    }

    /// Each shortcut includes its Command modifier, with space between groups.
    /// The mute mark uses the real SF Symbol, like the system hint.
    private static func makePickerHint(requiresCommand: Bool) -> NSStackView {
        let muted = NSImageView()
        muted.image = NSImage(systemSymbolName: "speaker.slash.fill",
                              accessibilityDescription: "Mute")
        muted.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        muted.contentTintColor = .secondaryLabelColor
        muted.imageScaling = .scaleNone
        muted.setContentHuggingPriority(.required, for: .horizontal)
        muted.setAccessibilityElement(false)

        let prefix = requiresCommand ? "⌘ " : ""
        let muteShortcut = NSStackView(views: (requiresCommand ? [caption("⌘")] : []) + [muted, caption("mute")])
        muteShortcut.orientation = .horizontal
        muteShortcut.alignment = .centerY
        muteShortcut.spacing = 2

        let legend = NSStackView(views: [
            caption("\(prefix)↑↓ select"),
            caption("\(prefix)←→ volume"),
            caption("\(prefix)⏯ play/pause"),
            muteShortcut, caption("\(prefix)H hook"),
        ])
        legend.orientation = .horizontal
        legend.alignment = .centerY
        legend.distribution = .equalSpacing
        legend.spacing = 8
        for item in legend.arrangedSubviews {
            item.setContentHuggingPriority(.required, for: .horizontal)
        }
        legend.setAccessibilityElement(true)
        legend.setAccessibilityRole(.staticText)
        legend.setAccessibilityLabel("\(requiresCommand ? "Hold Command: " : "")Up or Down to select, Left or Right for volume, Play for play/pause, Mute to mute, H to hook")
        return legend
    }

    /// Match the menu: hooked name, playback control, speaker, then volume.
    private func makeSourceRow(_ row: SourceRow, selected: Bool) -> NSView {
        let marker = NSImageView()
        marker.image = row.canPlayPause ? Self.playbackStateSymbol(row.isPlaying) : nil
        marker.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        marker.imageScaling = .scaleProportionallyDown
        marker.contentTintColor = selected ? .labelColor : NSColor.labelColor.withAlphaComponent(0.65)
        marker.setAccessibilityElement(false)
        sourcePlaybackIcons[row.sourceID] = marker

        let name = NSTextField(labelWithString: row.name)
        let nameFont = NSFont.systemFont(ofSize: row.indented ? 11 : 13, weight: selected ? .semibold : .regular)
        name.font = nameFont
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.cell?.wraps = false
        name.cell?.usesSingleLineMode = true
        name.setAccessibilityElement(false)
        if row.isHooked, let glyph = NSImage(named: "HookGlyph") {
            // The attachment shares the original name column, so adding the
            // hook cannot widen the row or push its volume bar out of the HUD.
            let attachment = NSTextAttachment()
            attachment.image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                glyph.draw(in: rect)
                NSColor.black.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            attachment.bounds = NSRect(x: 0, y: -4, width: 18, height: 18)
            let title = NSMutableAttributedString(attachment: attachment)
            title.append(NSAttributedString(string: " " + row.name))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            title.addAttributes([.font: nameFont, .foregroundColor: NSColor.labelColor,
                                 .paragraphStyle: paragraph],
                                range: NSRange(location: 0, length: title.length))
            name.attributedStringValue = title
        }

        let level: NSView
        if row.percent == nil && !row.isMuted {
            let text = Self.caption("Volume unavailable")
            text.font = .systemFont(ofSize: 10)
            level = text
        } else {
            let bar = VolumeBarView()
            bar.percent = row.percent ?? 0
            bar.isMuted = row.isMuted
            bar.isEmitting = row.isEmitting
            bar.trackHeight = 5
            bar.setAccessibilityElement(false)
            sourceBars[row.sourceID] = bar
            level = bar
        }

        let mute = NSHostingView(rootView: SourceSpeakerIcon(
            seed: row.sourceID, isMuted: row.isMuted, canMute: row.canMute, isEmitting: row.isEmitting, volume: row.percent ?? 100))
        mute.setAccessibilityElement(false)
        sourceSpeakers[row.sourceID] = mute

        let nameColumn: NSView
        if let track = row.nowPlaying {
            let ticker = NSHostingView(rootView: TrackTicker(text: track))
            ticker.setAccessibilityElement(false)
            sourceTickers[row.sourceID] = ticker
            name.setContentHuggingPriority(.required, for: .horizontal)
            name.setContentCompressionResistancePriority(.required, for: .horizontal)
            let column = NSStackView(views: [name, ticker])
            column.orientation = .horizontal
            column.alignment = .centerY
            column.spacing = 8
            // GeometryReader has no intrinsic width. Reserve its share of the
            // name column explicitly instead of allowing the host to collapse.
            let columnWidth: CGFloat = row.indented ? 152 : 168
            let nameWidth = min(ceil(name.attributedStringValue.size().width), columnWidth - 40)
            ticker.sizingOptions = []
            NSLayoutConstraint.activate([
                name.widthAnchor.constraint(equalToConstant: nameWidth),
                ticker.widthAnchor.constraint(equalToConstant: columnWidth - nameWidth - column.spacing),
                ticker.heightAnchor.constraint(equalToConstant: 18),
            ])
            nameColumn = column
        } else {
            nameColumn = name
        }
        let line = NSStackView(views: [nameColumn, marker, mute, level])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 6
        line.edgeInsets = NSEdgeInsets(top: row.indented ? 6 : 12, left: row.indented ? 24 : 8, bottom: row.indented ? 6 : 12, right: 12)
        line.wantsLayer = true
        line.layer?.cornerRadius = 18
        line.layer?.cornerCurve = .continuous
        let dark = panel?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if selected {
            // Follow the overlay's appearance (which contrasts with the system),
            // so white labels never sit on the light-mode-strength highlight.
            line.layer?.backgroundColor = NSColor.white.withAlphaComponent(dark ? 0.18 : 0.22).cgColor
        } else if row.isMuted {
            let tint: NSColor = dark ? .white : .black
            line.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
            line.layer?.borderColor = tint.withAlphaComponent(0.2).cgColor
            line.layer?.borderWidth = 1
        }
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            marker.widthAnchor.constraint(equalToConstant: 20),
            marker.heightAnchor.constraint(equalToConstant: 20),
            nameColumn.widthAnchor.constraint(equalToConstant: row.indented ? 152 : 168),
            level.widthAnchor.constraint(equalToConstant: 122),
            mute.widthAnchor.constraint(equalToConstant: 20),
            level.heightAnchor.constraint(equalToConstant: 16),
        ])

        let state = row.statusText
        line.setAccessibilityElement(true)
        line.setAccessibilityRole(.staticText)
        line.setAccessibilityLabel("\(row.name)\(row.isHooked ? ", hooked" : ""), \(state)\(selected ? ", selected" : "")")
        return line
    }

    /// The glyph for a play/pause press. `nil` — an app that reports no state —
    /// gets the neutral combined mark rather than a guess in either direction.
    private static func muteSymbol(muted: Bool) -> NSImage? {
        muted
            ? NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Muted")
            : NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Unmuted")
    }

    private static func transportSymbol(isPlaying: Bool?) -> NSImage? {
        switch isPlaying {
        case true?:
            return NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Playing")
        case false?:
            return NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Paused")
        case nil:
            return NSImage(systemSymbolName: "playpause.fill", accessibilityDescription: "Play or pause")
        }
    }

    /// A stretchable rounded-rect alpha mask (the corners are fixed via
    /// capInsets, the middle stretches to any panel size).
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A compact, appearance-adaptive fill bar matching the monochrome system HUD.
private final class VolumeBarView: NSView {
    var isMuted = false { didSet { needsDisplay = true } }
    var isEmitting = true { didSet { needsDisplay = true } }
    var trackHeight: CGFloat? { didSet { needsDisplay = true } }
    var percent = 0 {
        didSet {
            percent = min(100, max(0, percent))
            needsDisplay = true
            setAccessibilityValue("\(percent) percent")
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Volume")
        setAccessibilityValue("0 percent")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let height = min(bounds.height, trackHeight ?? bounds.height)
        let track = NSRect(x: bounds.minX, y: bounds.midY - height / 2,
                           width: bounds.width, height: height)
        let opacity: CGFloat = isMuted ? 0.25 : isEmitting ? 1 : 0.35
        let caption = NSAttributedString(string: "Muted", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        let captionSize = isMuted ? caption.size() : .zero
        let captionOrigin = NSPoint(x: bounds.midX - captionSize.width / 2,
                                    y: bounds.midY - captionSize.height / 2)
        let trackRadius = track.height / 2
        NSColor.labelColor.withAlphaComponent(0.16 * opacity).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackRadius, yRadius: trackRadius).fill()

        let fillWidth = track.width * CGFloat(percent) / 100
        if fillWidth > 0 {
            let fill = NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)
            let fillRadius = min(fill.height / 2, fill.width / 2)
            NSColor.labelColor.withAlphaComponent(0.88 * opacity).setFill()
            NSBezierPath(roundedRect: fill, xRadius: fillRadius, yRadius: fillRadius).fill()
        }
        // Overlay the text directly: no background box or rectangular cutout.
        if isMuted { caption.draw(at: captionOrigin) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
