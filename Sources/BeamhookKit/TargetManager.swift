import Foundation

public final class TargetManager {
    private let defaults: UserDefaults
    private let resolver: MediaAppResolver
    private let runner: ScriptRunning
    private let volumeStep: Int
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
    public func route(_ key: MediaKey) async {
        guard let command = key.command else { return }
        guard let app = currentTargetApp(), app.isReady else { return }
        await runner.run { app.perform(command) }   // perform() re-checks readiness off-main
    }

    /// Applies `steps` volume-key presses (positive = up) to the target in a single
    /// off-main round-trip: read current, clamp, set. Returns the app it acted on and
    /// the new volume 0...100, or nil if there's nothing to do (no target / not ready /
    /// no scriptable volume). Returning the bundle id (resolved inside the same off-main
    /// closure) lets callers key their volume cache to the app actually adjusted, even
    /// if the selected target changed while this was in flight.
    ///
    /// Coalescing note: a burst of N presses is applied as one pre-clamped net delta,
    /// so the final volume can differ from applying each press individually across the
    /// 0/100 boundary (e.g. down-then-up near 0). That's intentional and benign for a
    /// held/bursty key; it keeps holding the key to one round-trip.
    public func adjustVolume(bySteps steps: Int) async -> (bundleID: String, volume: Int)? {
        guard steps != 0, let app = currentTargetApp() else { return nil }
        let delta = steps * volumeStep
        return await runner.run {
            guard app.isReady, app.supportsVolume, let current = app.currentVolume() else { return nil }
            let next = min(100, max(0, current + delta))
            app.setVolume(next)
            return (app.bundleID, next)
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
