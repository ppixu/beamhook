// BeamhookKit — pure, testable logic for Beamhook.
public enum VolumeKeyRouting {
    /// Volume-key routing is opt-in. A missing preference must never be interpreted
    /// as enabled, regardless of the current output device or target.
    public static func isEnabled(
        for bundleID: String,
        preferences: [String: Bool]
    ) -> Bool {
        preferences[bundleID] == true
    }

    /// The hardware volume keys are intercepted only for a volume-capable target
    /// whose checkbox has been explicitly enabled.
    public static func shouldHijack(
        targetBundleID: String?,
        targetSupportsVolume: Bool,
        preferences: [String: Bool]
    ) -> Bool {
        guard targetSupportsVolume, let targetBundleID else { return false }
        return isEnabled(for: targetBundleID, preferences: preferences)
    }
}
