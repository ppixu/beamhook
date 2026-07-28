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
    /// Last position observed by the browser scan. This is only a fast-path cache:
    /// every action validates `sourceID` in the page before doing anything, and
    /// falls back to an identity-based browser-wide search if the tab moved.
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let artist: String
    /// Hostname of the page, used to badge the menu-bar icon. Empty when the scan
    /// predates this field or the page has no host (a `file://` or `about:` tab).
    let host: String
    let isPlaying: Bool
    let isSelected: Bool
    /// False for a call/conference tab, whose only media is a live `MediaStream`.
    /// Volume still applies; play/pause does not, since pausing a live stream
    /// just freezes the user's view of the meeting.
    let supportsTransport: Bool
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
        /// Optional so a page that answers without it still yields a usable
        /// candidate — a missing host only costs the icon its badge.
        let host: String?
        let playing: Bool
        let selected: Bool
        let live: Bool
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
            // Positions are retained only as a fast-path cache. Every later action
            // validates the page-owned source id before using them.
            return BrowserMediaCandidate(
                browser: browser, sourceID: payload.sourceID,
                windowIndex: window, tabIndex: tab,
                title: payload.title, artist: payload.artist,
                host: payload.host ?? "",
                isPlaying: payload.playing, isSelected: payload.selected,
                supportsTransport: !payload.live,
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

    func togglePlayPause(_ candidate: BrowserMediaCandidate) -> Bool {
        perform(.playPause, on: candidate)
    }

    /// Read one exact browser source using the scan's cached location as a fast
    /// path and its page-owned source ID as the authority.
    func isPlaying(_ candidate: BrowserMediaCandidate) -> Bool? {
        let result = executor.run(playbackStateScript(candidate))
        guard result.succeeded else { return nil }
        switch result.output?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "PLAYING": return true
        case "PAUSED": return false
        default: return nil
        }
    }

    func perform(_ command: MediaCommand, on candidate: BrowserMediaCandidate) -> Bool {
        let script: String
        switch command {
        case .playPause: script = playPauseScript(candidate)
        case .next: script = nextScript(candidate)
        case .previous: script = previousScript(candidate)
        }
        return executor.run(script).succeeded
    }

    private func scanScript(_ browser: BrowserKind) -> String {
        let js = """
        (() => { \(BrowserJS.pick) const p = bhPick(); const md = navigator.mediaSession && navigator.mediaSession.metadata; if (!p && !md) return null; const key = '__beamhookSourceID_v1'; const makeID = () => globalThis.crypto && globalThis.crypto.randomUUID ? globalThis.crypto.randomUUID() : [Date.now().toString(36), Math.random().toString(36).slice(2)].join('-'); const sourceID = globalThis[key] || (globalThis[key] = makeID()); return JSON.stringify({sourceID,title:(md && md.title) || document.title || location.hostname,artist:(md && md.artist) || '',host:location.hostname || '',playing:p ? (!p.el.paused && !p.el.ended) : navigator.mediaSession.playbackState === 'playing',live:p ? p.live : false,selected:sessionStorage.getItem('beamhook-selected') === '1',volume:p ? Math.round(p.el.volume * 100) : null}); })()
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
        (() => { const key = '__beamhookSourceID_v1'; if (globalThis[key] !== '\(candidate.sourceID)') return 'NO'; \(BrowserJS.pick) const p = bhPick(); if (!p) return 'NO'; p.group.forEach(x => { x.volume = \(clamped) / 100; if (\(clamped) > 0) x.muted = false; }); return 'MATCH'; })()
        """
        return targetedActionScript(js, candidate: candidate)
    }

    private func playPauseScript(_ candidate: BrowserMediaCandidate) -> String {
        let js = """
        (() => { const key = '__beamhookSourceID_v1'; if (globalThis[key] !== '\(candidate.sourceID)') return 'NO'; \(BrowserJS.pick) const p = bhPick(); if (!p || p.live) return 'NO'; const youtube = document.querySelector('.ytp-play-button'); if (youtube) youtube.click(); else if (p.el.paused || p.el.ended) void p.el.play(); else p.el.pause(); return 'MATCH'; })()
        """
        return targetedActionScript(js, candidate: candidate)
    }

    private func playbackStateScript(_ candidate: BrowserMediaCandidate) -> String {
        let js = """
        (() => { const key = '__beamhookSourceID_v1'; if (globalThis[key] !== '\(candidate.sourceID)') return 'NO'; \(BrowserJS.pick) const p = bhPick(); if (!p) return 'NO'; return (!p.el.paused && !p.el.ended) ? 'PLAYING' : 'PAUSED'; })()
        """
        let evaluate = candidate.browser == .safari
            ? "do JavaScript javascriptSource in candidateTab"
            : "execute candidateTab javascript javascriptSource"
        return """
        set javascriptSource to "\(js)"
        set targetFound to false
        set playbackState to "NO"
        tell application "\(candidate.browser.applicationName)"
            try
                set candidateTab to tab \(candidate.tabIndex) of window \(candidate.windowIndex)
                set queryResult to \(evaluate)
                if queryResult is not "NO" then
                    set targetFound to true
                    set playbackState to queryResult
                end if
            end try
            if targetFound is false then
                repeat with browserWindow in windows
                    repeat with candidateTab in tabs of browserWindow
                        try
                            set queryResult to \(evaluate)
                            if queryResult is not "NO" then
                                set targetFound to true
                                set playbackState to queryResult
                                exit repeat
                            end if
                        end try
                    end repeat
                    if targetFound then
                        exit repeat
                    end if
                end repeat
            end if
        end tell
        if targetFound is false then error "Selected browser media source is no longer available"
        return playbackState
        """
    }

    private func nextScript(_ candidate: BrowserMediaCandidate) -> String {
        let js = """
        (() => { const key = '__beamhookSourceID_v1'; if (globalThis[key] !== '\(candidate.sourceID)') return 'NO'; const b = document.querySelector('.ytp-next-button'); if (!b) return 'NO'; b.click(); return 'MATCH'; })()
        """
        return targetedActionScript(js, candidate: candidate)
    }

    private func previousScript(_ candidate: BrowserMediaCandidate) -> String {
        let js = """
        (() => { const key = '__beamhookSourceID_v1'; if (globalThis[key] !== '\(candidate.sourceID)') return 'NO'; const b = document.querySelector('.ytp-prev-button'); if (!b) return 'NO'; b.click(); return 'MATCH'; })()
        """
        return targetedActionScript(js, candidate: candidate)
    }

    /// Try the scan's last-known tab first, but treat it strictly as a cache. The
    /// page-owned source id is validated before the JS can act, so a reordered or
    /// replaced tab is harmless. A cache miss falls back to the safe identity scan.
    private func targetedActionScript(
        _ javascript: String,
        candidate: BrowserMediaCandidate
    ) -> String {
        let evaluate = candidate.browser == .safari
            ? "do JavaScript javascriptSource in candidateTab"
            : "execute candidateTab javascript javascriptSource"
        return """
        set javascriptSource to "\(javascript)"
        set targetFound to false
        tell application "\(candidate.browser.applicationName)"
            try
                set candidateTab to tab \(candidate.tabIndex) of window \(candidate.windowIndex)
                set actionResult to \(evaluate)
                if actionResult is "MATCH" then set targetFound to true
            end try
            if targetFound is false then
                repeat with browserWindow in windows
                    repeat with candidateTab in tabs of browserWindow
                        try
                            set actionResult to \(evaluate)
                            if actionResult is "MATCH" then
                                set targetFound to true
                                exit repeat
                            end if
                        end try
                    end repeat
                    if targetFound then
                        exit repeat
                    end if
                end repeat
            end if
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
