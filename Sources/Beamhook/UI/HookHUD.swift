import AppKit
import os

/// A transient, click-through overlay for hook confirmations and app-specific
/// volume changes. Styled like the modern macOS volume HUD, it drops down below
/// the menu bar near Beamhook's status item without taking focus.
@MainActor
final class HookHUD {
    static let shared = HookHUD()
    private init() {}

    private static let systemVolumeHint = "⌘ + 🔊 for system volume"

    private enum Presentation {
        case hooked(appName: String, volumeKeysHijacked: Bool)
        case volume(appName: String, percent: Int)

        var appName: String {
            switch self {
            case .hooked(let appName, _), .volume(let appName, _): appName
            }
        }

        var hideDelay: TimeInterval {
            switch self {
            case .hooked(_, let volumeKeysHijacked): volumeKeysHijacked ? 3.0 : 2.0
            case .volume: 1.5
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

    private var panel: NSPanel?
    private var label: NSTextField?
    private var detailLabel: NSTextField?
    private var hookIcon: NSImageView?
    private var volumeRow: NSView?
    private var volumeBar: VolumeBarView?
    private var box: NSView?
    /// The padded stack inside the chrome; its fitting size drives the panel size.
    private var content: NSView?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    /// Initialize Liquid Glass at full opacity outside every screen. Rendering
    /// it with near-zero window alpha lets the compositor skip the expensive
    /// backdrop pass, which merely postpones initialization until the first show.
    func prewarm(completion: @escaping @MainActor () -> Void) {
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
    func show(appName: String, volumeKeysHijacked: Bool = false) {
        show(.hooked(appName: appName, volumeKeysHijacked: volumeKeysHijacked))
    }

    /// Show an app-specific volume HUD after a hooked volume-key command succeeds.
    func showVolume(appName: String, percent: Int) {
        show(.volume(appName: appName, percent: min(100, max(0, percent))))
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
        switch presentation {
        case .hooked(let appName, let volumeKeysHijacked):
            label?.stringValue = "\(appName) hooked"
            detailLabel?.stringValue = Self.systemVolumeHint
            detailLabel?.isHidden = !volumeKeysHijacked
            hookIcon?.isHidden = false
            volumeRow?.isHidden = true
        case .volume(let appName, let percent):
            label?.stringValue = appName
            detailLabel?.stringValue = Self.systemVolumeHint
            detailLabel?.isHidden = false
            hookIcon?.isHidden = true
            volumeRow?.isHidden = false
            volumeBar?.percent = percent
        }

        // Size the window to the (variable-width) content, then anchor it.
        content?.layoutSubtreeIfNeeded()
        if let fitting = content?.fittingSize { panel.setContentSize(fitting) }
        position(panel)

        hideWork?.cancel()

        // Present immediately. Unlike NSGlassEffectView, the HUD material does
        // not need an asynchronous backdrop-settling period, so launch-time
        // notifications cannot be lost while waiting for a delayed reveal.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        if case .hooked = presentation { onPresent?() }
        Self.log.info("HUD shown for \(presentation.appName, privacy: .public); frame=\(NSStringFromRect(panel.frame), privacy: .public)")

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
        // Fade to (near-)invisible but never order out: keeping the window in
        // keeps the glass backdrop warm, so the next show has no first-frame
        // flash while the effect re-initializes.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0.001
        }
    }

    /// Use the opposite of the system appearance so the HUD stands apart from
    /// the desktop while preserving the user's high-contrast preference.
    private func applyContrastingAppearance(to panel: NSPanel) {
        let systemAppearance = NSApp.effectiveAppearance.bestMatch(from: [
            .aqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
        ])
        let contrastingAppearance: NSAppearance.Name
        let systemUsesDarkColors: Bool
        switch systemAppearance {
        case .darkAqua:
            contrastingAppearance = .aqua
            systemUsesDarkColors = true
        case .accessibilityHighContrastDarkAqua:
            contrastingAppearance = .accessibilityHighContrastAqua
            systemUsesDarkColors = true
        case .accessibilityHighContrastAqua:
            contrastingAppearance = .accessibilityHighContrastDarkAqua
            systemUsesDarkColors = false
        default:
            contrastingAppearance = .darkAqua
            systemUsesDarkColors = false
        }
        // Reassigning an identical appearance makes Liquid Glass rebuild its
        // backdrop, producing a black first frame on the launch notification.
        if panel.appearance?.name != contrastingAppearance {
            panel.appearance = NSAppearance(named: contrastingAppearance)
        }
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

        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.isHidden = true
        detail.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [text, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [icon, labels])
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

        let stack = NSStackView(views: [header, volumeStack])
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
            quietSpeaker.widthAnchor.constraint(equalToConstant: 18),
            quietSpeaker.heightAnchor.constraint(equalToConstant: 18),
            bar.widthAnchor.constraint(equalToConstant: 172),
            bar.heightAnchor.constraint(equalToConstant: 7),
            loudSpeaker.widthAnchor.constraint(equalToConstant: 22),
            loudSpeaker.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
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
        applyContrastingAppearance(to: panel)
        self.panel = panel
        self.label = text
        self.detailLabel = detail
        self.hookIcon = icon
        self.volumeRow = volumeStack
        self.volumeBar = bar
        self.box = chrome
        self.content = content
        return panel
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

        let track = bounds
        let trackRadius = track.height / 2
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackRadius, yRadius: trackRadius).fill()

        let fillWidth = track.width * CGFloat(percent) / 100
        guard fillWidth > 0 else { return }
        let fill = NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)
        let fillRadius = min(fill.height / 2, fill.width / 2)
        NSColor.labelColor.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: fill, xRadius: fillRadius, yRadius: fillRadius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
