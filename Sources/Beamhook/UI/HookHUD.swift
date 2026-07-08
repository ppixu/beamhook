import AppKit
import os

/// A transient, click-through overlay — like the macOS volume/brightness HUD —
/// shown in the centre of the active screen to confirm which app the media keys
/// are now hooked to (e.g. "Spotify hooked"). It never takes focus, so it can't
/// interrupt whatever the user is doing.
@MainActor
final class HookHUD {
    static let shared = HookHUD()
    private init() {}

    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "HUD")

    private let panelSize = NSSize(width: 210, height: 210)
    private var panel: NSPanel?
    private var iconView: NSImageView?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    /// Flash "<appName> hooked" in the centre of the screen.
    func show(appName: String, bundleID: String?) {
        let panel = ensurePanel()

        let icon = Self.icon(forBundleID: bundleID)
        iconView?.image = icon
        iconView?.isHidden = (icon == nil)
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
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // HUDs are always dark, regardless of the system appearance.
        panel.appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 20
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextField(labelWithString: "")
        text.alignment = .center
        text.font = .systemFont(ofSize: 16, weight: .semibold)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        blur.addSubview(icon)
        blur.addSubview(text)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            icon.topAnchor.constraint(equalTo: blur.topAnchor, constant: 36),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            text.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
        ])

        panel.contentView = blur
        self.panel = panel
        self.iconView = icon
        self.label = text
        return panel
    }

    /// Resolve an app icon for a bundle id — the running instance's icon first,
    /// else a Launch Services lookup of the installed app.
    private static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = running.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}
