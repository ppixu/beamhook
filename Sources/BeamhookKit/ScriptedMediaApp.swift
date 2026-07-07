import Foundation

/// Immutable after init; its collaborators (executor, presence) are stateless, so
/// it is safe to hand to `ScriptRunning.run` and touch on the scripting queue.
public final class ScriptedMediaApp: MediaApp, @unchecked Sendable {
    public let definition: AppDefinition
    private let executor: ScriptExecuting
    private let presence: AppPresenceChecking

    public init(definition: AppDefinition, executor: ScriptExecuting, presence: AppPresenceChecking) {
        self.definition = definition
        self.executor = executor
        self.presence = presence
    }

    public var id: String { definition.id }
    public var displayName: String { definition.displayName }
    public var bundleID: String { definition.bundleID }
    public var isRunning: Bool { presence.isRunning(bundleID: definition.bundleID) }
    public var isReady: Bool { presence.isReady(bundleID: definition.bundleID) }

    public func perform(_ command: MediaCommand) {
        // Ready (not merely running): scripting a still-launching app can block the
        // Apple-event send for a long time.
        guard isReady else { return }
        let script: String?
        switch command {
        case .playPause: script = definition.playPauseScript
        case .next:      script = definition.nextScript
        case .previous:  script = definition.previousScript
        }
        if let script, !script.isEmpty {
            _ = executor.run(script)
        }
    }

    public var supportsVolume: Bool {
        if case .none = definition.volumeScaleKind { return false }
        return definition.volumeGetScript != nil && definition.volumeSetScript != nil
    }

    public func currentVolume() -> Int? {
        guard supportsVolume, isReady, let getScript = definition.volumeGetScript else { return nil }
        let result = executor.run(getScript)
        guard result.succeeded,
              let out = result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
              let raw = Double(out) else { return nil }
        return VolumeScale.toPercent(raw: raw, kind: definition.volumeScaleKind)
    }

    public func setVolume(_ percent: Int) {
        guard supportsVolume, isReady,
              let template = definition.volumeSetScript,
              let rawStr = VolumeScale.rawString(fromPercent: percent, kind: definition.volumeScaleKind)
        else { return }
        guard template.contains("{volume}") else { return }
        let script = template.replacingOccurrences(of: "{volume}", with: rawStr)
        _ = executor.run(script)
    }

    public func isPlaying() -> Bool? {
        guard isReady, let script = definition.playStateScript else { return nil }
        let result = executor.run(script)
        guard result.succeeded,
              let out = result.output?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return nil }
        if out == "playing" || out == "true" { return true }
        if out == "paused" || out == "stopped" || out == "false" { return false }
        return nil
    }
}
