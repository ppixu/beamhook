import Foundation
@testable import BeamhookKit

final class MockScriptExecutor: ScriptExecuting {
    var ranScripts: [String] = []
    var cannedOutput: String?
    var succeed = true

    func run(_ source: String) -> ScriptResult {
        ranScripts.append(source)
        return ScriptResult(output: cannedOutput, succeeded: succeed)
    }
}

final class MockPresence: AppPresenceChecking {
    var runningBundleIDs: Set<String> = []
    func isRunning(bundleID: String) -> Bool { runningBundleIDs.contains(bundleID) }
}

final class MockMediaApp: MediaApp {
    let id: String
    let displayName: String
    let bundleID: String
    var isRunning: Bool
    var performedCommands: [MediaCommand] = []
    var supportsVolume: Bool = false
    var volumeValue: Int? = nil
    var setVolumeCalls: [Int] = []

    init(id: String, isRunning: Bool) {
        self.id = id
        self.displayName = id
        self.bundleID = "com.example.\(id)"
        self.isRunning = isRunning
    }

    func perform(_ command: MediaCommand) { performedCommands.append(command) }
    func currentVolume() -> Int? { volumeValue }
    func setVolume(_ percent: Int) { setVolumeCalls.append(percent) }
}
