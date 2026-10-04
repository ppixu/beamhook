import Foundation

/// One completed read-modify-write of an app's volume, 0...100.
public struct VolumeChange: Equatable, Sendable {
    public let bundleID: String
    public let previous: Int
    public let volume: Int

    public init(bundleID: String, previous: Int, volume: Int) {
        self.bundleID = bundleID
        self.previous = previous
        self.volume = volume
    }
}

public final class TargetManager {
    private let defaults: UserDefaults
    private let resolver: MediaAppResolver
    private let runner: ScriptRunning
    /// Percent per volume-key press. Public so other volume sources (browser
    /// tabs) step by the same amount as the hooked target.
    public let volumeStep: Int
    private static let storageKey = "selectedTargetAppID"
    private static let noTargetSentinel = "__beamhook_no_target__"

    /// - Parameters:
    ///   - runner: serializes AppleScript off the main thread (single-flight).
    ///   - volumeStep: percent per volume-key press (0...100).
    public init(defaults: UserDefaults,
                resolver: MediaAppResolver,
                runner: ScriptRunning = ScriptRunner(),
                volumeStep: Int = 6) {
        self.defaults = defaults
        self.resolver = resolver
        self.runner = runner
        self.volumeStep = volumeStep
    }

    public var selectedTargetID: String? {
        get {
            guard let stored = defaults.string(forKey: Self.storageKey),
                  stored != Self.noTargetSentinel else { return nil }
            return stored
        }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.storageKey) }
            else { defaults.set(Self.noTargetSentinel, forKey: Self.storageKey) }
        }
    }

    /// Distinguishes a fresh install from an explicitly persisted "no target" choice.
    public var hasSavedSelection: Bool {
        defaults.object(forKey: Self.storageKey) != nil
    }

    /// Routes a media key to the selected target, off the main thread. No-op for
    /// non-command keys, no selected target, or a target that isn't running.
    @discardableResult
    public func route(_ key: MediaKey) async -> Bool {
        guard let command = key.command, let app = currentTargetApp() else { return false }
        return await runner.run {
            // Check at execution time so a command queued while the app is finishing
            // launch is not silently discarded before it reaches the scripting lane.
            guard app.isReady else { return false }
            return app.perform(command)
        }
    }

    /// Sends a command directly to a running app without changing the hooked
    /// media-key target. Used by the compact controls in the playing-app list.
    @discardableResult
    public func route(_ command: MediaCommand, toBundleID bundleID: String) async -> Bool {
        guard let app = resolver.allApps().first(where: { $0.bundleID == bundleID })
        else { return false }
        return await runner.run {
            guard app.isReady else { return false }
            return app.perform(command)
        }
    }

    /// Reads the hooked target's volume, sets `transform(current)` clamped to
    /// 0...100, and reports both — one off-main round-trip, so a mute toggle can
    /// decide from the live value without a second Apple event. nil when there's
    /// no target, it isn't ready, or it has no readable volume. The bundle id is
    /// resolved inside the same off-main closure, so callers can key their
    /// volume cache to the app actually changed even if the hooked target
    /// changed while this was in flight.
    ///
    /// Coalescing note: the volume keys apply a burst of N presses as one
    /// pre-clamped net delta, so the final volume can differ from applying each
    /// press individually across the 0/100 boundary (e.g. down-then-up near 0).
    /// That's intentional and benign for a held key; it keeps holding the key
    /// to one round-trip.
    public func updateVolume(_ transform: @escaping (Int) -> Int) async -> VolumeChange? {
        guard let app = currentTargetApp() else { return nil }
        return await Self.readModifyWrite(app, transform, on: runner)
    }

    /// Same as `updateVolume(_:)` for any registered app, without touching the
    /// hooked target. Used by the volume-source picker.
    public func updateVolume(ofBundleID bundleID: String,
                             _ transform: @escaping (Int) -> Int) async -> VolumeChange? {
        guard let app = resolver.allApps().first(where: { $0.bundleID == bundleID }) else { return nil }
        return await Self.readModifyWrite(app, transform, on: runner)
    }

    private static func readModifyWrite(_ app: MediaApp, _ transform: @escaping (Int) -> Int,
                                        on runner: ScriptRunning) async -> VolumeChange? {
        await runner.run {
            guard app.isReady, app.supportsVolume, let current = app.currentVolume() else { return nil }
            let next = min(100, max(0, transform(current)))
            app.setVolume(next)
            return VolumeChange(bundleID: app.bundleID, previous: current, volume: next)
        }
    }

    /// Whether the current target exposes a scriptable volume.
    public var targetSupportsVolume: Bool {
        currentTargetApp()?.supportsVolume ?? false
    }

    /// Bundle id of the current target, if any.
    public var targetBundleID: String? {
        currentTargetApp()?.bundleID
    }

    private func currentTargetApp() -> MediaApp? {
        guard let id = selectedTargetID else { return nil }
        return resolver.app(withID: id)
    }
}
