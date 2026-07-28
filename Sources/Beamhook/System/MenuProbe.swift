import AppKit
import ApplicationServices
import BeamhookKit

/// Developer tool for mapping a menu-driven target. Dumps another app's menu bar
/// and exercises its play/pause item, so a `MenuControl` can be written from what
/// the app actually exposes — and so a target that silently does nothing can be
/// told apart from one whose press is refused. Inert unless asked for:
///
///     defaults write com.github.ppixu.beamhook BHProbeBundleID com.colliderli.iina
///
/// Output goes to the unified log:
///
///     log stream --predicate 'process == "Beamhook"' --info
enum MenuProbe {
    /// Writes to a file as well as the log, since the unified log swallows NSLog
    /// from a sandbox-free app inconsistently.
    private static let outputPath = "/tmp/beamhook-menuprobe.txt"

    static func runIfRequested(accessibilityGranted: Bool) {
        guard let bundleID = UserDefaults.standard.string(forKey: "BHProbeBundleID"),
              !bundleID.isEmpty else { return }
        try? "probe start, accessibility=\(accessibilityGranted)\n"
            .write(toFile: outputPath, atomically: true, encoding: .utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            if bundleID == "org.videolan.vlc" {
                runVLCGroundTruth()
            } else {
                dump(bundleID)
            }
        }
    }

    private static func emit(_ line: String) {
        NSLog("BHPROBE: %@", line)
        guard let handle = FileHandle(forWritingAtPath: outputPath) else { return }
        handle.seekToEndOfFile()
        handle.write((line + "\n").data(using: .utf8)!)
        try? handle.close()
    }

    private static func dump(_ bundleID: String) {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            emit("\(bundleID) is not running")
            return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = copy(axApp, kAXMenuBarAttribute) as! AXUIElement? else {
            emit("no menu bar for \(bundleID) (is Accessibility granted?)")
            return
        }

        for (menuIndex, barItem) in children(menuBar).enumerated() {
            emit("[\(menuIndex)] \(title(barItem) ?? "?")")
            guard let menu = children(barItem).first else { continue }
            for (itemIndex, item) in children(menu).enumerated() {
                emit("     [\(itemIndex)] \(title(item) ?? "(separator)")")
            }
        }

        // Round trip: read the play/pause title, press it, read it again. If the
        // second read differs, AX sees fresh titles and play state is trustworthy.
        // Core Audio is the tie-breaker: a stale title cannot fake an audio stream
        // going away, so that — not the title — says whether the press landed.
        let presser = AXMenuItemPresser()
        let definitions = BuiltInApps.all + [BuiltInApps.iina]
        guard let control = definitions.first(where: { $0.bundleID == bundleID })?.menuControl else {
            emit("no menu-driven definition for \(bundleID); dumped the menus only")
            return
        }
        let path = control.playPause
        emit("audio output before press: \(audioIsPlaying(bundleID) ? "yes" : "no")")
        let before = presser.title(of: path, bundleID: bundleID)
        let pressed = presser.press(path, bundleID: bundleID)
        Thread.sleep(forTimeInterval: 1.0)
        let after = presser.title(of: path, bundleID: bundleID)
        emit("playPause title before=\(before ?? "nil") pressed=\(pressed ? "yes" : "no") after=\(after ?? "nil")")
        emit("audio output after press: \(audioIsPlaying(bundleID) ? "yes" : "no")   <-- the real verdict")

        // Same title read again, but after opening and closing the menu, which
        // forces the app's menu delegate to run. If this disagrees with the read
        // above, AX serves stale titles and play state can't be trusted without
        // opening the menu — which would flash it on screen.
        if let menuBarItem = barItem(titled: "Playback", in: menuBar) {
            AXUIElementPerformAction(menuBarItem, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.5)
            let opened = presser.title(of: path, bundleID: bundleID)
            AXUIElementPerformAction(menuBarItem, kAXCancelAction as CFString)
            emit("playPause title after opening the menu=\(opened ?? "nil")")
        }

        Thread.sleep(forTimeInterval: 0.5)
        emit("second press \(presser.press(path, bundleID: bundleID) ? "ok" : "failed")")

        // Decisive test: does the item fire when its menu is OPEN? AppKit resolves a
        // nil-target menu action through the responder chain, which may only happen
        // while the menu is up. If this toggles and the closed-menu press does not,
        // the technique needs a visible menu flash for AppKit apps.
        guard let playbackMenuItem = barItem(titled: "Playback", in: menuBar) else { return }
        let opened = AXUIElementPerformAction(playbackMenuItem, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.6)
        emit("opened Playback menu: \(opened == .success ? "ok" : "failed \(opened.rawValue)"), title now=\(presser.title(of: path, bundleID: bundleID) ?? "nil")")

        let pressedWhileOpen = presser.press(path, bundleID: bundleID)
        Thread.sleep(forTimeInterval: 1.0)
        emit("pressed while open=\(pressedWhileOpen ? "yes" : "no") title after=\(presser.title(of: path, bundleID: bundleID) ?? "nil")")
        AXUIElementPerformAction(playbackMenuItem, kAXCancelAction as CFString)

        // Last question: does the item fire once the app is frontmost? If yes, the
        // action needs the responder chain of the active app, and driving it means
        // stealing focus on every key press — which is not worth having.
        Thread.sleep(forTimeInterval: 0.5)
        app.activate()
        Thread.sleep(forTimeInterval: 1.0)
        let activePress = presser.press(path, bundleID: bundleID)
        Thread.sleep(forTimeInterval: 1.0)
        emit("pressed while frontmost=\(activePress ? "yes" : "no") title after=\(presser.title(of: path, bundleID: bundleID) ?? "nil")")
    }

    private static func minimizeControl(axApp: AXUIElement, presser: AXMenuItemPresser, bundleID: String) {
        func minimized() -> String {
            guard let windows = copy(axApp, kAXWindowsAttribute) as? [AXUIElement],
                  let window = windows.first else { return "no window" }
            return ((copy(window, kAXMinimizedAttribute) as? Bool).map(String.init)) ?? "unreadable"
        }

        let before = minimized()
        let pressed = presser.press(MenuItemPath(menuIndex: nil, menuTitles: ["Window"],
                                                 itemIndex: nil, itemTitles: ["Minimize"]),
                                    bundleID: bundleID)
        Thread.sleep(forTimeInterval: 1.0)
        let after = minimized()
        emit("CONTROL minimize: before=\(before) pressed=\(pressed ? "yes" : "no") after=\(after)")

        // Put it back so the probe leaves no mess.
        if after == "true", let windows = copy(axApp, kAXWindowsAttribute) as? [AXUIElement],
           let window = windows.first {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }
    }

    /// Ground truth for the whole technique. VLC is scriptable, so its state can be
    /// read over AppleScript — independent of the menu titles being questioned here.
    /// Press its Play/Pause menu item over AX and see whether the state really moves.
    static func runVLCGroundTruth() {
        let executor = AppleScriptExecutor()
        let presser = AXMenuItemPresser()
        let bundleID = "org.videolan.vlc"
        let state = { executor.run("tell application \"VLC\" to return (playing as text)").output ?? "nil" }

        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            emit("VLC is not running")
            return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        if let menuBar = copy(axApp, kAXMenuBarAttribute) as! AXUIElement? {
            for (menuIndex, item) in children(menuBar).enumerated() where menuIndex > 0 {
                emit("VLC [\(menuIndex)] \(title(item) ?? "?")")
                guard title(item) == "Playback", let menu = children(item).first else { continue }
                for (itemIndex, sub) in children(menu).prefix(6).enumerated() {
                    emit("VLC      [\(itemIndex)] \(title(sub) ?? "(separator)")")
                }
            }
        }

        let path = MenuItemPath(menuIndex: nil, menuTitles: ["Playback"],
                                itemIndex: nil, itemTitles: ["Play", "Pause"])
        let before = state()
        let pressed = presser.press(path, bundleID: bundleID)
        Thread.sleep(forTimeInterval: 1.0)
        emit("VLC playing before=\(before) pressed=\(pressed ? "yes" : "no") after=\(state())")
    }

    /// Does this app currently hold a running audio output stream? Core Audio keeps
    /// a stream open briefly after a pause, hence the settle time before asking.
    private static func audioIsPlaying(_ bundleID: String) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        Thread.sleep(forTimeInterval: 1.5)
        let monitor = DispatchQueue.main.sync { AudioProcessMonitor() }
        DispatchQueue.main.sync { monitor.refresh() }
        return DispatchQueue.main.sync { monitor.playingApps.contains { $0.bundleID == bundleID } }
    }

    private static func barItem(titled wanted: String, in menuBar: AXUIElement) -> AXUIElement? {
        children(menuBar).first { title($0) == wanted }
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (copy(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func title(_ element: AXUIElement) -> String? {
        (copy(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
