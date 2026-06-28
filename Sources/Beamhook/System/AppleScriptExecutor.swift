import Foundation
import BeamhookKit

/// Runs AppleScript via NSAppleScript. Call on the main thread.
final class AppleScriptExecutor: ScriptExecuting {
    func run(_ source: String) -> ScriptResult {
        guard let script = NSAppleScript(source: source) else {
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
