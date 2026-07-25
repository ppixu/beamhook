import Foundation

public struct ScriptResult: Sendable {
    public let output: String?
    public let succeeded: Bool
    public init(output: String?, succeeded: Bool) {
        self.output = output
        self.succeeded = succeeded
    }
}

public protocol ScriptExecuting {
    /// Runs a script and returns its result. The real implementation runs
    /// NSAppleScript synchronously and blocks the calling thread until the target
    /// answers (or the Apple-event send times out), so it MUST NOT be called on the
    /// main thread — route it through a `ScriptRunning` off-main serial queue.
    func run(_ source: String) -> ScriptResult
}

/// Serializes blocking scripting work off the main thread. All AppleScript runs
/// through one of these so a slow/unresponsive target can never wedge the UI or
/// the media-key event tap (the root cause of the July 2026 system freeze).
public protocol ScriptRunning: AnyObject {
    /// Runs `work` on the scripting queue and resumes with its result. At most one
    /// `work` block runs at a time (serial), so callers get natural single-flight.
    func run<T>(_ work: @escaping () -> T) async -> T
}

public protocol AppPresenceChecking {
    /// A process with this bundle id exists.
    func isRunning(bundleID: String) -> Bool
    /// Running AND finished launching — i.e. ready to answer Apple events promptly.
    /// Scripting a still-launching app is what blocked for ~2 minutes in the freeze.
    func isReady(bundleID: String) -> Bool
}

public extension AppPresenceChecking {
    // Default: treat "running" as "ready". Real checkers override to also require
    // `isFinishedLaunching`; mocks inherit this so existing tests are unaffected.
    func isReady(bundleID: String) -> Bool { isRunning(bundleID: bundleID) }
}

public protocol MediaApp: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var bundleID: String { get }
    var isRunning: Bool { get }
    /// Running and ready to answer Apple events promptly. Defaults to `isRunning`.
    var isReady: Bool { get }
    func perform(_ command: MediaCommand)
    var supportsVolume: Bool { get }
    func currentVolume() -> Int?    // 0...100, nil if unsupported/unavailable
    func setVolume(_ percent: Int)  // 0...100
    func isPlaying() -> Bool?       // true=playing, false=paused/stopped, nil=unknown/unavailable
}

public extension MediaApp {
    var isReady: Bool { isRunning }
}

public protocol MediaAppResolver: AnyObject {
    func app(withID id: String) -> MediaApp?
    func allApps() -> [MediaApp]
}
