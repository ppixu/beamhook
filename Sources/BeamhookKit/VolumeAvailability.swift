import Foundation

/// Why a row does or does not offer a volume slider. Keeping this a value decided
/// from three inputs — rather than a bare `scriptable` boolean — is what lets the
/// menu tell "this app has no volume control" apart from "you said no when macOS
/// asked", which look identical to a caller that only sees a failed read.
public enum VolumeAvailability: Equatable, Sendable {
    /// The app is scriptable and the read worked: show the slider.
    case slider
    /// Beamhook may not send Apple events to this app, so the read can never
    /// succeed until the user allows it. Recoverable, and worth saying out loud.
    case permissionDenied
    /// The app genuinely offers no volume control — a menu-driven target, or an
    /// app playing audio that Beamhook has no definition for.
    case systemVolumeOnly

    /// - Parameters:
    ///   - definitionSupportsVolume: the app's definition carries volume scripts.
    ///   - readSucceeded: a live volume read returned a value.
    ///   - automationAllowed: whether macOS permits Apple events to this app.
    ///     nil when unknown (not running, or the check itself failed), which is
    ///     treated as "not the permission's fault" so a transient miss never
    ///     accuses the user of denying something.
    public static func resolve(definitionSupportsVolume: Bool,
                               readSucceeded: Bool,
                               automationAllowed: Bool?) -> VolumeAvailability {
        if readSucceeded { return .slider }
        guard definitionSupportsVolume else { return .systemVolumeOnly }
        return automationAllowed == false ? .permissionDenied : .systemVolumeOnly
    }
}
