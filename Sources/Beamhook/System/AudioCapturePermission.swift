import Foundation

/// System Audio Recording (TCC's `kTCCServiceAudioCapture`) has no public
/// status API, and a denied tap fails silently: creating it and starting its IO
/// both succeed, then every buffer is zeros. A volume renderer on such a tap
/// mutes the app and replays silence. Preflight through TCC's SPI — the same
/// one AudioCap uses — so a denial is known before any capture starts.
enum AudioCapturePermission: Equatable {
    case granted
    case denied
    /// Not asked yet, or the SPI is unavailable. Capture may proceed: starting
    /// IO is what shows the prompt.
    case unknown

    init(preflightResult: Int) {
        switch preflightResult {
        case 0: self = .granted
        case 1: self = .denied
        default: self = .unknown
        }
    }

    /// Blocks on an XPC round-trip to tccd; keep it off the main thread.
    static func current() -> AudioCapturePermission {
        guard let preflight else { return .unknown }
        return AudioCapturePermission(preflightResult: preflight("kTCCServiceAudioCapture" as CFString, nil))
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int

    private static let preflight: Preflight? = {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()
}
