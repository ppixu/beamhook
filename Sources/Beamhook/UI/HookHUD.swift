import AppKit
import os

/// A transient, click-through overlay — like the macOS volume/brightness HUD —
/// shown in the centre of the active screen to confirm which app the media keys
/// are now hooked to (e.g. "Spotify hooked"). It never takes focus, so it can't
/// interrupt whatever the user is doing.
///
/// Chrome-free by design: the Beamhook hook glyph over the label, with no boxy
/// panel. A soft radial scrim + a dark halo on the white glyph/text keep both
/// clearly legible over any window behind them (light or dark).
@MainActor
final class HookHUD {
    static let shared = HookHUD()
    private init() {}

    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "HUD")

    private let panelSize = NSSize(width: 400, height: 360)
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    /// Flash "<appName> hooked" in the centre of the screen.
    func show(appName: String) {
        let panel = ensurePanel()
        label?.stringValue = "\(appName) hooked"

        // Centre on the screen holding the cursor (fall back to the main screen).
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panelSize.width / 2,
                                         y: frame.midY - panelSize.height / 2))
        }

        generation += 1
        let gen = generation
        hideWork?.cancel()

        // Show immediately (no fade-in): an implicit alpha animation isn't reliably
        // committed when this fires during app launch, which left the HUD invisible.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        Self.log.info("HUD shown: \(appName, privacy: .public) hooked; screen=\(screen?.localizedName ?? "nil", privacy: .public) visible=\(panel.isVisible)")

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(gen: gen) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func dismiss(gen: Int) {
        guard gen == generation, let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Runs on the main thread once the fade-out finishes.
            MainActor.assumeIsolated {
                // Skip if a newer show() has since re-displayed the HUD.
                guard let self, gen == self.generation else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // Soft radial glow behind the content (fades to clear — no boxy edges).
        let content = ScrimView(frame: NSRect(origin: .zero, size: panelSize))

        // Dark halo so the white glyph + text separate from any background.
        func halo() -> NSShadow {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.9)
            s.shadowBlurRadius = 14
            s.shadowOffset = .zero
            return s
        }

        let icon = NSImageView()
        icon.image = NSImage(named: "HookGlyph")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.shadow = halo()
        icon.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextField(labelWithString: "")
        text.alignment = .center
        text.font = .systemFont(ofSize: 24, weight: .semibold)
        text.textColor = .white
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 2
        text.wantsLayer = true
        text.shadow = halo()
        text.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, text])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        let padding: CGFloat = 28
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -padding),
            icon.widthAnchor.constraint(equalToConstant: 132),
            icon.heightAnchor.constraint(equalToConstant: 132),
        ])

        panel.contentView = content
        self.panel = panel
        self.label = text
        return panel
    }
}

/// Draws a soft, centred radial darkening that fades fully to clear before the
/// edges — gives the HUD presence on bright backgrounds without a hard-edged box.
private final class ScrimView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let gradient = NSGradient(colors: [
            NSColor.black.withAlphaComponent(0.42),
            NSColor.black.withAlphaComponent(0.0),
        ])!
        gradient.draw(fromCenter: center, radius: 0,
                      toCenter: center, radius: min(bounds.width, bounds.height) / 2,
                      options: [])
    }
}
