import Foundation

/// A picker keystroke: ⌘↑ / ⌘↓ select and ⌘← / ⌘→ adjust volume.
/// ⌘PgUp / ⌘PgDn are selection aliases for external keyboards. Anything with
/// ⇧, ⌥ or ⌃ as well is left alone — ⌘⇧↑ is "select to start" in every editor.
public enum SourcePickerKey: Equatable, Sendable {
    case previous, next, volumeDown, volumeUp, hook

    /// Virtual key codes from Carbon's HIToolbox `Events.h`.
    private static let upArrow = 126, downArrow = 125, pageUp = 116, pageDown = 121

    /// The fn and numeric-pad flags that arrow and page keys carry are not
    /// parameters on purpose: they say nothing about intent and must be ignored.
    public static func match(keyCode: Int, command: Bool, shift: Bool,
                             option: Bool, control: Bool) -> SourcePickerKey? {
        guard command, !shift, !option, !control else { return nil }
        switch keyCode {
        case upArrow, pageUp: return .previous
        case downArrow, pageDown: return .next
        case 123: return .volumeDown
        case 124: return .volumeUp
        case 4: return .hook // H
        default: return nil
        }
    }
}
