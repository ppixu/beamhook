import Foundation

/// What to tell the user when a transport key press was deliberately handed
/// back to macOS instead of being routed to the hooked browser. macOS then
/// gives the key to whichever app most recently owned the system's now-playing
/// session — which is frequently not the hooked browser — so the press can
/// visibly "control the wrong app" while Beamhook appears hooked. Naming the
/// reason at press time is what turns that from a mystery into a fix.
public enum PassthroughNotice: Equatable, Sendable {
    /// Nothing more specific is known: say only that macOS routed the key.
    case handledByMacOS
    /// The hooked browser isn't running, so there was nothing to route to.
    case browserNotRunning
    /// The browser refused tab JavaScript, which is the one capability tab
    /// routing is built on. Recoverable by the user, so worth saying out loud.
    case enableBrowserJavaScript

    /// - Parameters:
    ///   - browserRunningNow: live process check at the moment of the press.
    ///   - scanSawBrowserRunning: whether the last browser scan found it
    ///     running. nil when no scan has answered for this hook yet.
    ///   - injectionAvailable: the last scan's verdict on tab JavaScript. Only
    ///     meaningful when that scan actually reached a running browser — a
    ///     scan of a quit browser records `false` as a side effect, and a
    ///     stale `false` must never accuse the user's browser settings.
    public static func resolve(browserRunningNow: Bool,
                               scanSawBrowserRunning: Bool?,
                               injectionAvailable: Bool?) -> PassthroughNotice {
        guard browserRunningNow else { return .browserNotRunning }
        guard scanSawBrowserRunning == true else { return .handledByMacOS }
        return injectionAvailable == false ? .enableBrowserJavaScript : .handledByMacOS
    }
}
