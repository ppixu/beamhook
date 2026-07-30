import Foundation

/// Starts an app. Main-actor isolated: the only implementation asks NSWorkspace,
/// which is a main-thread API, and it keeps every caller on one actor.
@MainActor
public protocol AppLaunching {
    /// Asks the system to launch this app. False when it isn't installed.
    func launch(bundleID: String) async -> Bool
}

/// Test seam so the readiness poll runs instantly under test.
@MainActor
public protocol Sleeping {
    func sleep(seconds: Double) async
}

public struct TaskSleeper: Sleeping {
    // Default-argument expressions (e.g. `sleeper: Sleeping = TaskSleeper()` below)
    // are type-checked in a synchronous nonisolated context regardless of the
    // enclosing initializer's actor isolation, so this init must opt out of the
    // @MainActor isolation the compiler infers for the type from its `Sleeping`
    // conformance. Safe: the body touches no actor-isolated state.
    public nonisolated init() {}
    public func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

public enum TargetLaunchOutcome: Equatable {
    /// A launch was already in flight, or the hook moved while we waited.
    case skipped
    case notInstalled
    case timedOut
    /// The app resumed playback on its own; nothing was sent.
    case alreadyPlaying
    case played
}

/// Launches the hooked app and starts playback, for a play/pause press that
/// would otherwise be swallowed with nothing to act on.
///
/// Deliberately NOT done by letting AppleScript launch the app implicitly: that
/// Apple-event send blocks until the target finishes launching (the ~2 minute
/// stall behind the July 2026 freeze) and would sit on the serial command lane
/// with every later key press queued behind it. It also cannot work for
/// menu-driven targets, which have no scripting dictionary at all.
@MainActor
public final class TargetLauncher {
    private let launcher: AppLaunching
    private let sleeper: Sleeping
    private let runner: ScriptRunning
    private let timeout: Double
    private let pollInterval: Double
    private var isLaunching = false

    /// - Parameters:
    ///   - runner: the *command* lane, so the play it sends is serialized with
    ///     the user's other key presses.
    ///   - timeout: how long to wait for readiness before giving up quietly.
    public init(launcher: AppLaunching,
                sleeper: Sleeping = TaskSleeper(),
                runner: ScriptRunning,
                timeout: Double = 15,
                pollInterval: Double = 0.25) {
        self.launcher = launcher
        self.sleeper = sleeper
        self.runner = runner
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    /// - Parameters:
    ///   - isStillHooked: re-checked after the wait; the user can change target
    ///     during a cold start, and playing the old one would be wrong.
    ///   - onLaunchStarted: fires exactly once, only when something really is
    ///     starting — drives the "Starting …" HUD.
    public func launchAndPlay(_ app: MediaApp,
                              isStillHooked: @escaping @MainActor () -> Bool,
                              onLaunchStarted: @escaping @MainActor () -> Void)
        async -> TargetLaunchOutcome {
        guard !isLaunching else { return .skipped }
        isLaunching = true
        defer { isLaunching = false }

        // Already running means mid-launch: wait for it rather than relaunching.
        if !app.isRunning {
            guard await launcher.launch(bundleID: app.bundleID) else { return .notInstalled }
        }
        onLaunchStarted()

        var waited = 0.0
        while !app.isReady {
            if waited >= timeout { return .timedOut }
            await sleeper.sleep(seconds: pollInterval)
            waited += pollInterval
        }

        guard isStillHooked() else { return .skipped }

        return await runner.run {
            // An app that resumed on its own would be PAUSED by an unconditional
            // playPause. Unknown state (nil) counts as not playing.
            if app.isPlaying() == true { return .alreadyPlaying }
            app.perform(.playPause)
            return .played
        }
    }
}
