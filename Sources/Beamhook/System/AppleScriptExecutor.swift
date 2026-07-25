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

enum BrowserKind: String, CaseIterable, Sendable {
    case safari, chrome, brave, arc, vivaldi

    static func target(id: String?) -> BrowserKind? {
        switch id {
        case "safari-youtube": return .safari
        case "chrome-youtube": return .chrome
        case "brave-youtube": return .brave
        case "arc-youtube": return .arc
        case "vivaldi-youtube": return .vivaldi
        default: return nil
        }
    }

    static func browser(bundleID: String) -> BrowserKind? {
        allCases.first { $0.bundleID == bundleID }
    }

    var applicationName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .brave: "Brave Browser"
        case .arc: "Arc"
        case .vivaldi: "Vivaldi"
        }
    }

    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .arc: "company.thebrowser.Browser"
        case .vivaldi: "com.vivaldi.Vivaldi"
        }
    }
}

struct BrowserMediaCandidate: Identifiable, Hashable, Sendable {
    let browser: BrowserKind
    /// Random identifier owned by the current page. Unlike browser window/tab
    /// indexes, it remains stable when the user reorders tabs and is discarded
    /// on cross-origin navigation rather than ever pointing at a different page.
    let sourceID: String
    let title: String
    let artist: String
    let isPlaying: Bool
    let isSelected: Bool
    var volume: Int?

    var id: String { "\(browser.rawValue):\(sourceID)" }
    var label: String { artist.isEmpty ? title : "\(title) — \(artist)" }
}

struct BrowserMediaScan: Sendable {
    let injectionAvailable: Bool
    let candidates: [BrowserMediaCandidate]
}

/// Discovers media-bearing tabs and marks one tab for the static browser command
/// scripts in BeamhookKit. Runs only on a ScriptRunner queue.
final class BrowserMediaController: @unchecked Sendable {
    private let executor: ScriptExecuting

    private struct Payload: Decodable {
        let sourceID: String
        let title: String
        let artist: String
        let playing: Bool
        let selected: Bool
        let volume: Int?
    }

    init(executor: ScriptExecuting = AppleScriptExecutor()) {
        self.executor = executor
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
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  Self.isValidSourceID(payload.sourceID)
            else { return nil }
            // Parsing the indexes validates the row format, but deliberately do
            // not retain them: positions are not identities and must never be
            // used by a later action after the browser can have reordered tabs.
            _ = window
            _ = tab
            return BrowserMediaCandidate(
                browser: browser, sourceID: payload.sourceID,
                title: payload.title, artist: payload.artist,
                isPlaying: payload.playing, isSelected: payload.selected,
                volume: payload.volume.map { min(max($0, 0), 100) })
        }
        return BrowserMediaScan(injectionAvailable: true, candidates: candidates)
    }

    func select(_ candidate: BrowserMediaCandidate) -> Bool {
        executor.run(selectionScript(candidate)).succeeded
    }

    func setVolume(_ percent: Int, for candidate: BrowserMediaCandidate) -> Bool {
        executor.run(volumeScript(percent, candidate: candidate)).succeeded
    }

    private func scanScript(_ browser: BrowserKind) -> String {
        let js = """
        (() => { const all = Array.from(document.querySelectorAll('video,audio')); const m = all.find(x => !x.paused && !x.ended) || all[0]; const md = navigator.mediaSession && navigator.mediaSession.metadata; if (!m && !md) return null; const key = '__beamhookSourceID_v1'; const makeID = () => globalThis.crypto && globalThis.crypto.randomUUID ? globalThis.crypto.randomUUID() : [Date.now().toString(36), Math.random().toString(36).slice(2)].join('-'); const sourceID = globalThis[key] || (globalThis[key] = makeID()); return JSON.stringify({sourceID,title:(md && md.title) || document.title || location.hostname,artist:(md && md.artist) || '',playing:m ? (!m.paused && !m.ended) : navigator.mediaSession.playbackState === 'playing',selected:sessionStorage.getItem('beamhook-selected') === '1',volume:m ? Math.round(m.volume * 100) : null}); })()
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

    private func volumeScript(_ percent: Int, candidate: BrowserMediaCandidate) -> String {
        let clamped = min(max(percent, 0), 100)
        let js = """
        (() => { const key = '__beamhookSourceID_v1'; if (globalThis[key] !== '\(candidate.sourceID)') return 'NO'; const all = Array.from(document.querySelectorAll('video,audio')); const active = all.filter(x => !x.paused && !x.ended); const targets = active.length ? active : (all[0] ? [all[0]] : []); targets.forEach(x => { x.volume = \(clamped) / 100; if (\(clamped) > 0) x.muted = false; }); return targets.length > 0 ? 'MATCH' : 'NO'; })()
        """
        let evaluate = candidate.browser == .safari
            ? "do JavaScript javascriptSource in candidateTab"
            : "execute candidateTab javascript javascriptSource"
        return """
        set javascriptSource to "\(js)"
        set targetFound to false
        tell application "\(candidate.browser.applicationName)"
            repeat with browserWindow in windows
                repeat with candidateTab in tabs of browserWindow
                    try
                        set actionResult to \(evaluate)
                        if actionResult is "MATCH" then set targetFound to true
                    end try
                end repeat
            end repeat
        end tell
        if targetFound is false then error "Selected browser media source is no longer available"
        return true
        """
    }

    private func selectionScript(_ candidate: BrowserMediaCandidate) -> String {
        let evaluate: String
        if candidate.browser == .safari {
            evaluate = "do JavaScript javascriptSource in candidateTab"
        } else {
            evaluate = "execute candidateTab javascript javascriptSource"
        }
        let js = """
        (() => { const key = '__beamhookSourceID_v1'; const matches = globalThis[key] === '\(candidate.sourceID)'; if (matches) sessionStorage.setItem('beamhook-selected','1'); else sessionStorage.removeItem('beamhook-selected'); return matches ? 'MATCH' : 'NO'; })()
        """
        return """
        set javascriptSource to "\(js)"
        set targetFound to false
        tell application "\(candidate.browser.applicationName)"
            repeat with browserWindow in windows
                repeat with candidateTab in tabs of browserWindow
                    try
                        set actionResult to \(evaluate)
                        if actionResult is "MATCH" then set targetFound to true
                    end try
                end repeat
            end repeat
        end tell
        if targetFound is false then error "Selected browser media source is no longer available"
        return true
        """
    }

    private static func isValidSourceID(_ value: String) -> Bool {
        guard (8...64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }
}
