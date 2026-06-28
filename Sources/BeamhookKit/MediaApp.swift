import Foundation

public struct ScriptResult {
    public let output: String?
    public let succeeded: Bool
    public init(output: String?, succeeded: Bool) {
        self.output = output
        self.succeeded = succeeded
    }
}

public protocol ScriptExecuting {
    /// Runs a script and returns its result. The real implementation runs
    /// NSAppleScript synchronously and MUST be called on the main thread.
    func run(_ source: String) -> ScriptResult
}

public protocol AppPresenceChecking {
    func isRunning(bundleID: String) -> Bool
}

public protocol MediaApp: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var bundleID: String { get }
    var isRunning: Bool { get }
    func perform(_ command: MediaCommand)
    var supportsVolume: Bool { get }
    func currentVolume() -> Int?    // 0...100, nil if unsupported/unavailable
    func setVolume(_ percent: Int)  // 0...100
}

public protocol MediaAppResolver: AnyObject {
    func app(withID id: String) -> MediaApp?
    func allApps() -> [MediaApp]
}
