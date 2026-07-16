import Foundation
import BeamhookKit

/// Runs AppleScript via NSAppleScript. Blocks the calling thread until the target
/// replies, so it must be driven from a `ScriptRunning` serial queue — never the
/// main thread. A fresh NSAppleScript is created per call and used entirely on the
/// caller's thread, so instances are never shared across threads.
final class AppleScriptExecutor: ScriptExecuting {
    /// Cap on how long a single send waits for the target's Apple-event reply.
    /// NSAppleScript otherwise uses the ~60s default, so one beachballing/network-
    /// stalled (but already-launched) app could occupy the scripting queue for a
    /// minute and starve the next command. `with timeout` bounds the wait and raises
    /// errAETimeout (-1712), which we surface as a failed result (a safe no-op).
    private static let timeoutSeconds = 5

    func run(_ source: String) -> ScriptResult {
        let bounded = "with timeout of \(Self.timeoutSeconds) seconds\n\(source)\nend timeout"
        guard let script = NSAppleScript(source: bounded) else {
            return ScriptResult(output: nil, succeeded: false)
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            NSLog("AppleScript error: \(errorInfo)")
            return ScriptResult(output: nil, succeeded: false)
        }
        return ScriptResult(output: descriptor.stringValue, succeeded: true)
    }
}

enum BrowserKind: String, Sendable {
    case safari, chrome, brave

    static func target(id: String?) -> BrowserKind? {
        switch id {
        case "safari-youtube": return .safari
        case "chrome-youtube": return .chrome
        case "brave-youtube": return .brave
        default: return nil
        }
    }

    var applicationName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .brave: "Brave Browser"
        }
    }

    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        }
    }
}

struct BrowserMediaCandidate: Identifiable, Hashable, Sendable {
    let browser: BrowserKind
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let artist: String
    let url: String
    let isPlaying: Bool
    let isSelected: Bool

    var id: String { "\(browser.rawValue):\(windowIndex):\(tabIndex)" }
    var label: String { artist.isEmpty ? title : "\(title) — \(artist)" }
}

struct BrowserMediaScan: Sendable {
    let injectionAvailable: Bool
    let candidates: [BrowserMediaCandidate]
}

/// Discovers media-bearing tabs and marks one tab for the static browser command
/// scripts in BeamhookKit. Runs only on a ScriptRunner queue.
final class BrowserMediaController: @unchecked Sendable {
    private let executor = AppleScriptExecutor()

    private struct Payload: Decodable {
        let title: String
        let artist: String
        let url: String
        let playing: Bool
        let selected: Bool
    }

    func scan(_ browser: BrowserKind) -> BrowserMediaScan {
        let result = executor.run(scanScript(browser))
        guard result.succeeded, let output = result.output, output.hasPrefix("OK") else {
            return BrowserMediaScan(injectionAvailable: false, candidates: [])
        }

        let rows = output.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
        let candidates = rows.compactMap { row -> BrowserMediaCandidate? in
            let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let window = Int(fields[0]), let tab = Int(fields[1]),
                  let data = String(fields[2]).data(using: .utf8),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data)
            else { return nil }
            return BrowserMediaCandidate(
                browser: browser, windowIndex: window, tabIndex: tab,
                title: payload.title, artist: payload.artist, url: payload.url,
                isPlaying: payload.playing, isSelected: payload.selected)
        }
        return BrowserMediaScan(injectionAvailable: true, candidates: candidates)
    }

    func select(_ candidate: BrowserMediaCandidate) -> Bool {
        executor.run(selectionScript(candidate)).succeeded
    }

    private func scanScript(_ browser: BrowserKind) -> String {
        let js = """
        (() => { const all = Array.from(document.querySelectorAll('video,audio')); const m = all.find(x => !x.paused && !x.ended) || all[0]; const md = navigator.mediaSession && navigator.mediaSession.metadata; if (!m && !md) return null; return JSON.stringify({title:(md && md.title) || document.title || location.hostname,artist:(md && md.artist) || '',url:location.href,playing:m ? (!m.paused && !m.ended) : navigator.mediaSession.playbackState === 'playing',selected:sessionStorage.getItem('beamhook-selected') === '1'}); })()
        """
        let evaluate = browser == .safari
            ? "do JavaScript javascriptSource in candidateTab"
            : "execute candidateTab javascript javascriptSource"
        return """
        set outputRows to {}
        set injectionWorked to false
        set javascriptSource to "\(js)"
        tell application "\(browser.applicationName)"
            if not (exists front window) then return "OK"
            repeat with windowIndex from 1 to count of windows
                repeat with tabIndex from 1 to count of tabs of window windowIndex
                    set candidateTab to tab tabIndex of window windowIndex
                    try
                        set mediaInfo to \(evaluate)
                        set injectionWorked to true
                        if mediaInfo is not missing value and mediaInfo is not "null" then
                            set end of outputRows to (windowIndex as text) & (ASCII character 9) & (tabIndex as text) & (ASCII character 9) & mediaInfo
                        end if
                    end try
                end repeat
            end repeat
        end tell
        if injectionWorked is false then error "Browser tab JavaScript is unavailable"
        set oldDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set joinedRows to outputRows as text
        set AppleScript's text item delimiters to oldDelimiters
        if joinedRows is "" then return "OK"
        return "OK" & linefeed & joinedRows
        """
    }

    private func selectionScript(_ candidate: BrowserMediaCandidate) -> String {
        let clear: String
        let set: String
        if candidate.browser == .safari {
            clear = "do JavaScript \"sessionStorage.removeItem('beamhook-selected'); true\" in candidateTab"
            set = "do JavaScript \"sessionStorage.setItem('beamhook-selected','1'); true\" in targetTab"
        } else {
            clear = "execute candidateTab javascript \"sessionStorage.removeItem('beamhook-selected'); true\""
            set = "execute targetTab javascript \"sessionStorage.setItem('beamhook-selected','1'); true\""
        }
        return """
        tell application "\(candidate.browser.applicationName)"
            repeat with browserWindow in windows
                repeat with candidateTab in tabs of browserWindow
                    try
                        \(clear)
                    end try
                end repeat
            end repeat
            set targetTab to tab \(candidate.tabIndex) of window \(candidate.windowIndex)
            \(set)
        end tell
        """
    }
}
