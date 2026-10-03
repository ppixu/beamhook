// BeamhookKit — pure, testable logic for Beamhook.

/// Where a hardware volume key press should land.
public enum VolumeKeyDestination: Equatable, Sendable {
    /// Swallow the key and drive the hooked app's own volume.
    case app
    /// Leave the key to macOS (with any Command flag stripped first, so the
    /// system sees an ordinary volume key rather than a modified shortcut).
    case system
}

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

    /// Command flips which volume the keys control, in both directions:
    ///
    ///     checkbox OFF (default)   plain → system      ⌘ → hooked app
    ///     checkbox ON              plain → hooked app  ⌘ → system
    ///
    /// - Parameters:
    ///   - commandHeld: the Command flag was set on the key event.
    ///   - hijacked: `shouldHijack` — the per-app checkbox is on for a
    ///     volume-capable target.
    ///   - commandRoutingEnabled: the global "⌘ + volume keys control the hooked
    ///     app" setting. It never governs the escape hatch out of a hijack; that
    ///     way turning it off can only ever hand keys back to macOS.
    ///   - targetCanTakeVolume: the target exposes a volume Beamhook can drive
    ///     AND is running. When it can't take the key we never swallow it —
    ///     a press that would otherwise die silently reaches the system instead.
    ///   - sessionSourceCanTakeVolume: nil outside the picker. In a session,
    ///     volume follows the selection, except Command with hijacking enabled
    ///     always escapes to system volume.
    public static func destination(
        commandHeld: Bool,
        hijacked: Bool,
        commandRoutingEnabled: Bool,
        targetCanTakeVolume: Bool,
        sessionSourceCanTakeVolume: Bool? = nil
    ) -> VolumeKeyDestination {
        if hijacked && commandHeld { return .system }
        if let sessionSourceCanTakeVolume {
            return sessionSourceCanTakeVolume ? .app : .system
        }
        guard targetCanTakeVolume else { return .system }
        if hijacked { return commandHeld ? .system : .app }
        return commandHeld && commandRoutingEnabled ? .app : .system
    }

    /// The mute key rides the same flip as the volume keys (see `destination`),
    /// with mute's own capability in place of volume's.
    ///
    /// During a picker session every mute press Beamhook would take — ⌘ + Mute,
    /// and plain Mute while the volume keys are hooked — toggles the picked
    /// source instead, so it is gated on that source, not the hooked app.
    /// `sessionSourceCanTakeMute` is nil outside a session, and inside one says
    /// whether the picked source can be muted right now (an app needs per-app
    /// mute and must be running; a browser tab is muted through its volume).
    /// When it can't, the press reaches the system exactly as it would for a
    /// hooked app that can't be muted. Plain Mute with the hook off stays the
    /// system's, session or not.
    public static func muteDestination(
        commandHeld: Bool,
        hijacked: Bool,
        commandRoutingEnabled: Bool,
        targetCanTakeMute: Bool,
        sessionSourceCanTakeMute: Bool? = nil
    ) -> VolumeKeyDestination {
        if hijacked && commandHeld { return .system }
        if let sessionSourceCanTakeMute, commandHeld || hijacked {
            return sessionSourceCanTakeMute ? .app : .system
        }
        return destination(commandHeld: commandHeld,
                           hijacked: hijacked,
                           commandRoutingEnabled: commandRoutingEnabled,
                           targetCanTakeVolume: targetCanTakeMute)
    }

    /// What Command reaches from the current configuration, or nil when Command
    /// changes nothing and the hint must stay hidden. Shared by the menu row and
    /// the overlay so the two can never advertise different chords.
    public static func commandHintDestination(
        hijacked: Bool,
        commandRoutingEnabled: Bool,
        targetCanTakeVolume: Bool
    ) -> VolumeKeyDestination? {
        guard targetCanTakeVolume else { return nil }
        if hijacked { return .system }
        return commandRoutingEnabled ? .app : nil
    }
}
