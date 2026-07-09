import AppKit
import os

/// A transient, click-through overlay confirming which app the media keys are
/// hooked to (e.g. "Spotify hooked"). Styled like a macOS Control-Center panel —
/// a frosted rounded box — and shown just below the menu bar near Beamhook's
/// status item, echoing where the system shows volume/now-playing feedback. It
/// never takes focus, so it can't interrupt whatever the user is doing.
@MainActor
final class HookHUD {
    static let shared = HookHUD()
    private init() {}

    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "HUD")

    /// Screen frame of the menu-bar status item, so we can anchor under it.
    /// Set by the AppDelegate once the status item exists.
    var menuBarAnchor: (() -> NSRect?)?

    private var panel: NSPanel?
    private var label: NSTextField?
    private var box: NSView?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    /// Flash "<appName> hooked" just below the menu bar.
    func show(appName: String) {
        let panel = ensurePanel()
        label?.stringValue = "\(appName) hooked"

        // Size the window to the (variable-width) content, then anchor it.
        box?.layoutSubtreeIfNeeded()
        if let fitting = box?.fittingSize { panel.setContentSize(fitting) }
        position(panel)

        generation += 1
        let gen = generation
        hideWork?.cancel()

        // Show immediately (no fade-in): an implicit alpha animation isn't reliably
        // committed when this fires during app launch, which left the HUD invisible.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        Self.log.info("HUD shown: \(appName, privacy: .public) hooked; visible=\(panel.isVisible)")

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(gen: gen) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        let gap: CGFloat = 8, margin: CGFloat = 10

        if let anchor = menuBarAnchor?() {
            let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
            var x = anchor.midX - size.width / 2
            let y = anchor.minY - gap - size.height   // just below the menu bar
            if let f = screen?.frame {
                x = min(max(x, f.minX + margin), f.maxX - size.width - margin)
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let f = (NSScreen.main ?? NSScreen.screens.first)?.frame {
            // Fallback: top-right, just under the menu bar.
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 32))
        }
    }

    private func dismiss(gen: Int) {
        guard gen == generation, let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
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

        // Frosted rounded box (Control-Center look).
        let box = NSVisualEffectView()
        box.material = .popover
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 16
        box.layer?.cornerCurve = .continuous
        box.layer?.masksToBounds = true

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

        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -13),
        ])

        panel.contentView = box
        self.panel = panel
        self.label = text
        self.box = box
        return panel
    }
}
