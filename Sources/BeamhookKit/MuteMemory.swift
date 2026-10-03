import Foundation

/// During a volume-source picker session, ⌘ + Mute mutes a browser tab by
/// setting its volume: a process-tap mute would silence the whole browser.
/// (Apps use the process-tap mute instead.) Muting remembers what it silenced
/// so the next toggle can put it back. In-process only: after a restart, or
/// when the user dragged a tab to 0 themselves, unmuting restores
/// `fallbackRestore`.
public struct MuteMemory: Sendable {
    public static let fallbackRestore = 50

    private var saved: [String: Int] = [:]

    public init() {}

    /// What unmuting `sourceID` restores to.
    public func restoreVolume(for sourceID: String) -> Int {
        saved[sourceID] ?? Self.fallbackRestore
    }

    /// The toggle itself: anything audible goes to 0, silence goes to `restore`.
    /// Static and pure so it can run inside an off-main read-modify-write.
    public static func toggled(from current: Int, restore: Int) -> Int {
        current > 0 ? 0 : restore
    }

    /// Record a completed toggle so the next one can undo it.
    public mutating func record(sourceID: String, previous: Int, new: Int) {
        if new == 0, previous > 0 {
            saved[sourceID] = previous
        } else {
            saved[sourceID] = nil
        }
    }
}
