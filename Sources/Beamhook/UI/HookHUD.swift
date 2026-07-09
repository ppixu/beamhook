import AppKit
import os

/// A transient, click-through overlay confirming which app the media keys are
/// hooked to (e.g. "Spotify hooked"). Styled like the modern macOS volume HUD —
/// a dark translucent rounded panel that drops down just below the menu bar near
/// Beamhook's status item. It never takes focus, so it can't interrupt whatever
/// the user is doing.
@MainActor
final class HookHUD {
    static let shared = HookHUD()
    private init() {}

    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "HUD")

    /// Screen frame of the menu-bar status item, so we can anchor under it.
    /// Set by the AppDelegate once the status item exists.
    var menuBarAnchor: (() -> NSRect?)?
    /// Invoked the moment the panel is put on screen — the AppDelegate hooks the
    /// status-item "fishing bob" animation here so both happen together.
    var onPresent: (() -> Void)?

    private var panel: NSPanel?
    private var label: NSTextField?
    private var box: NSView?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    /// Flash "<appName> hooked" just below the menu bar, under the status item.
    func show(appName: String) {
        generation += 1
        present(appName: appName, gen: generation, attempt: 0)
    }

    private func present(appName: String, gen: Int, attempt: Int) {
        guard gen == generation else { return }   // superseded by a newer show

        // At launch the status item's window reports a bogus near-origin frame
        // until the status bar lays it out. Wait for the real icon position (up
        // to ~1.2s) so the panel lands under the Beamhook icon, not at a
        // generic fallback spot.
        if validAnchor() == nil && attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.present(appName: appName, gen: gen, attempt: attempt + 1) }
            }
            return
        }

        let panel = ensurePanel()
        label?.stringValue = "\(appName) hooked"

        // Size the window to the (variable-width) content, then anchor it.
        box?.layoutSubtreeIfNeeded()
        if let fitting = box?.fittingSize { panel.setContentSize(fitting) }
        position(panel)

        hideWork?.cancel()

        // Show immediately (no fade-in): an implicit alpha animation isn't reliably
        // committed when this fires during app launch, which left the HUD invisible.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()   // recompute for the masked shape at this size
        onPresent?()
        Self.log.info("HUD shown: \(appName, privacy: .public) hooked; frame=\(NSStringFromRect(panel.frame), privacy: .public)")

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(gen: gen) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
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
        // The system volume HUD is dark translucent regardless of the theme;
        // force dark so ours reads the same in light mode.
        panel.appearance = NSAppearance(named: .darkAqua)

        let box = NSVisualEffectView()
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        // Round via maskImage, NOT layer.cornerRadius: with behind-window
        // blending the vibrancy backdrop (and the window shadow) is composited
        // by the window server for the window's full rect, so a layer mask
        // leaves a light un-rounded rectangle poking out at the corners. The
        // mask image is what tells the window server the real shape.
        box.maskImage = Self.roundedMask(radius: 20)

        let icon = NSImageView()
        icon.image = NSImage(named: "HookGlyph")   // template → tinted below
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 15, weight: .semibold)
        text.textColor = .white
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
        ])

        panel.contentView = box
        self.panel = panel
        self.label = text
        self.box = box
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
