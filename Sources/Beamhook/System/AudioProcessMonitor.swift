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
            guard let pid = Self.pid(obj),
                  let running = NSRunningApplication(processIdentifier: pid),
                  let bid = running.bundleIdentifier else { continue }
            if !apps.contains(where: { $0.bundleID == bid }) {
                apps.append(PlayingApp(id: bid, displayName: Self.displayName(for: running, bundleID: bid), bundleID: bid))
            }
        }
        if apps != playingApps { playingApps = apps }
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

    // MARK: - Core Audio helpers

    private static func processObjectIDs() -> [AudioObjectID] {
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

    private static func isRunningOutput(_ obj: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func pid(_ obj: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }
}
