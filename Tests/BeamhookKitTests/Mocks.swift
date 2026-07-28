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

/// Stands in for the Accessibility API so menu-driven apps are testable without
/// a running target app or an Accessibility grant.
final class MockMenuPresser: MenuItemPressing {
    var pressed: [(path: MenuItemPath, bundleID: String)] = []
    var succeed = true
    /// Title the fake reports for any queried item; nil models "couldn't read it".
    var cannedTitle: String?

    func press(_ path: MenuItemPath, bundleID: String) -> Bool {
        pressed.append((path, bundleID))
        return succeed
    }

    func title(of path: MenuItemPath, bundleID: String) -> String? { cannedTitle }
}

final class MockPresence: AppPresenceChecking {
    var runningBundleIDs: Set<String> = []
    /// nil → "ready" tracks "running"; set to model a running-but-still-launching app.
    var readyBundleIDs: Set<String>? = nil
    func isRunning(bundleID: String) -> Bool { runningBundleIDs.contains(bundleID) }
    func isReady(bundleID: String) -> Bool {
        if let readyBundleIDs { return readyBundleIDs.contains(bundleID) }
        return isRunning(bundleID: bundleID)
    }
}

/// Runs work synchronously inline so async TargetManager methods resolve
/// deterministically in tests (no real queue hops or timing).
final class InlineScriptRunner: ScriptRunning {
    func run<T>(_ work: @escaping () -> T) async -> T { work() }
}

final class MockMediaApp: MediaApp {
    let id: String
    let displayName: String
    let bundleID: String
    var isRunning: Bool
    /// nil → "ready" tracks "running"; set false to model a launching app.
    var readyValue: Bool? = nil
    var isReady: Bool { readyValue ?? isRunning }
    var performedCommands: [MediaCommand] = []
    var supportsVolume: Bool = false
    var volumeValue: Int? = nil
    var setVolumeCalls: [Int] = []
    var playingState: Bool? = nil

    init(id: String, isRunning: Bool) {
        self.id = id
        self.displayName = id
        self.bundleID = "com.example.\(id)"
        self.isRunning = isRunning
    }

    func perform(_ command: MediaCommand) { performedCommands.append(command) }
    func currentVolume() -> Int? { volumeValue }
    func setVolume(_ percent: Int) { setVolumeCalls.append(percent) }
    func isPlaying() -> Bool? { playingState }
}
