import Foundation

/// Runs blocking scripting work on a single dedicated serial queue, off the main
/// thread. `NSAppleScript.executeAndReturnError` blocks its thread until the target
/// app replies (or the Apple-event send times out — up to ~1 minute for an app that
/// is launching or wedged). Doing that on the main thread froze the whole Mac: the
/// UI couldn't draw and the session-level media-key event tap's handler couldn't
/// drain, so system input stalled. Confining it here means the worst case is that
/// this one background queue is briefly busy — the app and the tap stay responsive.
///
/// Serial (not concurrent) on purpose: it gives every caller single-flight for free,
/// so a held volume key or a repeating poll can't stack up dozens of blocked sends.
public final class ScriptRunner: ScriptRunning {
    private let queue = DispatchQueue(label: "com.beamhook.applescript", qos: .userInitiated)

    public init() {}

    public func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
