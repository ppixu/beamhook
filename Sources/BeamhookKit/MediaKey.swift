import Foundation

public enum MediaCommand: Equatable {
    case playPause, next, previous
}

public enum MediaKey: Equatable {
    case playPause, next, previous, fastForward, rewind, volumeUp, volumeDown, mute

    /// Keycodes from <IOKit/hidsystem/ev_keymap.h>.
    init?(keyCode: Int) {
        switch keyCode {
        case 16: self = .playPause
        case 17: self = .next
        case 18: self = .previous
        case 19: self = .fastForward
        case 20: self = .rewind
        case 0:  self = .volumeUp
        case 1:  self = .volumeDown
        case 7:  self = .mute
        default: return nil
        }
    }

    /// Keys we intercept (swallow) and forward to the target app.
    public var isHandledTransport: Bool {
        switch self {
        case .playPause, .next, .previous: return true
        default: return false
        }
    }

    public var command: MediaCommand? {
        switch self {
        case .playPause: return .playPause
        case .next: return .next
        case .previous: return .previous
        default: return nil
        }
    }
}

public struct MediaKeyEvent: Equatable {
    public let key: MediaKey
    public let isDown: Bool
    public let isRepeat: Bool

    public init(key: MediaKey, isDown: Bool, isRepeat: Bool) {
        self.key = key
        self.isDown = isDown
        self.isRepeat = isRepeat
    }
}
