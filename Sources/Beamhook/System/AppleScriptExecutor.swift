import Foundation
import BeamhookKit

/// Runs AppleScript via NSAppleScript. Blocks the calling thread until the target
/// replies, so it must be driven from a `ScriptRunning` serial queue — never the
/// main thread. A fresh NSAppleScript is created per call and used entirely on the
/// caller's thread, so instances are never shared across threads.
final class AppleScriptExecutor: ScriptExecuting {
    /// Cap on how long a single send waits for the target's Apple-event reply.
    /// NSAppleScript otherwise uses the ~60s default, so one beachballing/network-
    /// stalled (but already-launched) app could occupy the scripting queue for a
    /// minute and starve the next command. `with timeout` bounds the wait and raises
    /// errAETimeout (-1712), which we surface as a failed result (a safe no-op).
    private static let timeoutSeconds = 5

    func run(_ source: String) -> ScriptResult {
        let bounded = "with timeout of \(Self.timeoutSeconds) seconds\n\(source)\nend timeout"
        guard let script = NSAppleScript(source: bounded) else {
            return ScriptResult(output: nil, succeeded: false)
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            NSLog("AppleScript error: \(errorInfo)")
            return ScriptResult(output: nil, succeeded: false)
        }
        return ScriptResult(output: descriptor.stringValue, succeeded: true)
    }
}
