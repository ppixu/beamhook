import AppKit
import CoreAudio

struct PlayingApp: Identifiable, Equatable, Sendable {
    let id: String          // bundle identifier
    let displayName: String
    let bundleID: String
}

@available(macOS 14.2, *)
@MainActor
final class AudioProcessMonitor: ObservableObject {
    /// Apps with an active audio OUTPUT stream. Note: Core Audio reports a process as
    /// running-output while its stream is open even if it is paused/silent, so this list
    /// can include paused apps — hence "recently playing" rather than "currently audible".
    @Published private(set) var playingApps: [PlayingApp] = []
    private var timer: Timer?
    private let scanQueue = DispatchQueue(label: "com.github.ppixu.beamhook.audio-discovery", qos: .utility)
    private let scan: @Sendable () -> [PlayingApp]
    private var scanning = false
    private var running = false
    private var generation: UInt64 = 0

    init(scan: @escaping @Sendable () -> [PlayingApp] = { AudioProcessMonitor.scanPlayingApps() }) {
        self.scan = scan
    }

    func start() {
        stop()
        running = true
        refresh()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        running = false
        generation &+= 1
    }

    func refresh() {
        guard running, !scanning else { return }
        scanning = true
        let generation = generation
        // Only the plain snapshot crosses queues; publication stays on main.
        scanQueue.async { [weak self, scan] in
            let apps = scan()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanning = false
                guard self.running else { return }
                guard self.generation == generation else {
                    // Closed and reopened during the scan: discard the old
                    // result and refresh the new session without overlapping.
                    self.refresh()
                    return
                }
                if apps != self.playingApps { self.playingApps = apps }
            }
        }
    }

    /// Blocking HAL discovery, separated from publication so callers can scan
    /// off main without moving an observable monitor between threads.
    nonisolated static func scanPlayingApps() -> [PlayingApp] {
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
        return apps
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
    nonisolated static func resolve(_ obj: AudioObjectID) -> (displayName: String, bundleID: String)? {
        let running = pid(obj).flatMap { NSRunningApplication(processIdentifier: $0) }
        guard let raw = running?.bundleIdentifier ?? bundleID(obj), !raw.isEmpty else { return nil }
        if raw == "com.apple.avconferenced" {
            let identity = ScreenSharingAudio.identity(
                for: raw,
                runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            )
            return identity.map { ($0.displayName, $0.bundleID) }
        }
        if let running, running.bundleIdentifier != nil {
            if let identity = browserIdentity(for: running, rawBundleID: raw) { return identity }
            return (displayName(for: running, bundleID: raw), raw)
        }
        if let identity = browserIdentity(bundleID: raw) { return identity }
        // "<parent>.helper[…]" → the app it belongs to — but only when that
        // app is really running, so a system daemon never becomes a row.
        guard let helperRange = raw.range(of: ".helper") else { return nil }
        let parentID = String(raw[..<helperRange.lowerBound])
        guard let parent = NSRunningApplication
            .runningApplications(withBundleIdentifier: parentID).first else { return nil }
        return (parent.localizedName ?? parentID, parentID)
    }

    /// Human-facing name for an audio-emitting process. Safari (and any WebKit host,
    /// e.g. an app embedding a web view) plays through the shared WebKit GPU helper
    /// "com.apple.WebKit.GPU", which macOS names "<Owning app> Graphics and Media".
    /// Strip the helper suffix so we show "Safari" rather than "Safari Graphics and Media".
    private nonisolated static func displayName(for app: NSRunningApplication, bundleID: String) -> String {
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
    private nonisolated static func browserIdentity(
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
    private nonisolated static func browserIdentity(bundleID: String) -> (displayName: String, bundleID: String)? {
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
    nonisolated static func rowBundleID(for obj: AudioObjectID) -> String? {
        resolve(obj)?.bundleID
    }

    // MARK: - Core Audio helpers (shared with ProcessMuteController)

    nonisolated static func processObjectIDs() -> [AudioObjectID] {
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

    nonisolated static func isRunningOutput(_ obj: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    nonisolated static func pid(_ obj: AudioObjectID) -> pid_t? {
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
    private nonisolated static func bundleID(_ obj: AudioObjectID) -> String? {
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
