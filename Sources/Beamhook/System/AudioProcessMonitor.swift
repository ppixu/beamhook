import AppKit
import CoreAudio

struct PlayingApp: Identifiable, Equatable {
    let id: String          // bundle identifier
    let displayName: String
    let bundleID: String
}

@available(macOS 14.2, *)
final class AudioProcessMonitor: ObservableObject {
    /// Apps with an active audio OUTPUT stream. Note: Core Audio reports a process as
    /// running-output while its stream is open even if it is paused/silent, so this list
    /// can include paused apps — hence "recently playing" rather than "currently audible".
    @Published private(set) var playingApps: [PlayingApp] = []
    private var timer: Timer?

    func start() {
        stop()
        refresh()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        var apps: [PlayingApp] = []
        for obj in Self.processObjectIDs() where Self.isRunningOutput(obj) {
            guard let identity = Self.resolve(obj) else { continue }
            // Never list Beamhook itself (any build: .dev or shipping). The
            // mute assemblies run an IO proc that plays silence, which makes
            // our own process a running-output audio client — a row nobody
            // can meaningfully hook or mute.
            if identity.bundleID.hasPrefix("com.github.ppixu.beamhook") { continue }
            if !apps.contains(where: { $0.bundleID == identity.bundleID }) {
                apps.append(PlayingApp(id: identity.bundleID,
                                       displayName: identity.displayName,
                                       bundleID: identity.bundleID))
            }
        }
        if apps != playingApps { playingApps = apps }
    }

    /// (displayName, bundleID) for one HAL process, or nil when it can't be
    /// tied to an app the user would recognize. Internal (not private):
    /// ProcessMuteController resolves processes with the same mapping, so a
    /// mute applied to a row covers exactly the processes the row stands for.
    ///
    /// Two paths, because Core Audio's process list is broader than
    /// LaunchServices': an app process (or a registered helper like WebKit's)
    /// resolves through NSRunningApplication, but Chromium and Electron audio
    /// helpers are spawned outside LaunchServices and only the HAL knows their
    /// bundle id — those resolve through `kAudioProcessPropertyBundleID` and,
    /// via the ".helper" convention, back to the app that owns them.
    static func resolve(_ obj: AudioObjectID) -> (displayName: String, bundleID: String)? {
        if let pid = pid(obj),
           let running = NSRunningApplication(processIdentifier: pid),
           let raw = running.bundleIdentifier {
            if let identity = browserIdentity(for: running, rawBundleID: raw) { return identity }
            return (displayName(for: running, bundleID: raw), raw)
        }
        guard let hal = bundleID(obj), !hal.isEmpty else { return nil }
        if let identity = browserIdentity(bundleID: hal) { return identity }
        // "<parent>.helper[…]" → the app it belongs to — but only when that
        // app is really running, so a system daemon never becomes a row.
        guard let helperRange = hal.range(of: ".helper") else { return nil }
        let parentID = String(hal[..<helperRange.lowerBound])
        guard let parent = NSRunningApplication
            .runningApplications(withBundleIdentifier: parentID).first else { return nil }
        return (parent.localizedName ?? parentID, parentID)
    }

    /// Human-facing name for an audio-emitting process. Safari (and any WebKit host,
    /// e.g. an app embedding a web view) plays through the shared WebKit GPU helper
    /// "com.apple.WebKit.GPU", which macOS names "<Owning app> Graphics and Media".
    /// Strip the helper suffix so we show "Safari" rather than "Safari Graphics and Media".
    private static func displayName(for app: NSRunningApplication, bundleID: String) -> String {
        let raw = app.localizedName ?? bundleID
        guard bundleID.hasPrefix("com.apple.WebKit") else { return raw }
        for suffix in [" Graphics and Media", " Web Content", " Networking"] where raw.hasSuffix(suffix) {
            return String(raw.dropLast(suffix.count))
        }
        return raw
    }

    /// Core Audio often attributes browser playback to a renderer/GPU helper.
    /// Resolve those helpers to the browser's built-in target so the row can be
    /// hooked instead of offering a useless custom definition for the helper.
    private static func browserIdentity(
        for app: NSRunningApplication,
        rawBundleID: String
    ) -> (displayName: String, bundleID: String)? {
        let name = displayName(for: app, bundleID: rawBundleID)
        if rawBundleID.hasPrefix("com.apple.WebKit"), name == "Safari" {
            return ("Safari", "com.apple.Safari")
        }
        return browserIdentity(bundleID: rawBundleID)
    }

    /// The Chromium browsers by bundle id alone (the app itself or any of its
    /// ".helper" processes) — the WebKit case above needs a process name and
    /// stays with the NSRunningApplication path.
    private static func browserIdentity(bundleID: String) -> (displayName: String, bundleID: String)? {
        if bundleID == "com.google.Chrome" || bundleID.hasPrefix("com.google.Chrome.helper") {
            return ("Chrome", "com.google.Chrome")
        }
        if bundleID == "com.brave.Browser" || bundleID.hasPrefix("com.brave.Browser.helper") {
            return ("Brave", "com.brave.Browser")
        }
        if bundleID == "company.thebrowser.Browser" || bundleID.hasPrefix("company.thebrowser.Browser.helper") {
            return ("Arc", "company.thebrowser.Browser")
        }
        if bundleID == "com.vivaldi.Vivaldi" || bundleID.hasPrefix("com.vivaldi.Vivaldi.helper") {
            return ("Vivaldi", "com.vivaldi.Vivaldi")
        }
        return nil
    }

    /// The bundle id an app row uses for one HAL process; nil for processes
    /// that don't belong to a recognizable app. See `resolve`.
    static func rowBundleID(for obj: AudioObjectID) -> String? {
        resolve(obj)?.bundleID
    }

    // MARK: - Core Audio helpers (shared with ProcessMuteController)

    static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &dataSize, &ids) == noErr else { return [] }
        let actualCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        return Array(ids.prefix(actualCount))
    }

    static func isRunningOutput(_ obj: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    static func pid(_ obj: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// The HAL's own record of a process's bundle id — present even for audio
    /// helpers LaunchServices has never heard of.
    private static func bundleID(_ obj: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
