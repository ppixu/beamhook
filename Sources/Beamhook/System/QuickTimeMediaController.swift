import AppKit
import os
import BeamhookKit

struct QuickTimeMovie: Identifiable, Equatable, Sendable {
    let processID: Int32
    let windowID: Int
    let title: String
    let isPlaying: Bool

    var id: String { "\(processID):\(windowID)" }
}

/// Window IDs survive window reordering. The process ID prevents a stale choice
/// from addressing a reused window ID after QuickTime restarts.
final class QuickTimeMediaController: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "QuickTime")
    private let executor: ScriptExecuting
    private let processID: () -> Int32?

    init(executor: ScriptExecuting = AppleScriptExecutor(),
         processID: @escaping () -> Int32? = {
             NSRunningApplication.runningApplications(
                 withBundleIdentifier: BuiltInApps.quickTime.bundleID
             ).first(where: { $0.isFinishedLaunching })?.processIdentifier
         }) {
        self.executor = executor
        self.processID = processID
    }

    /// nil means unavailable; an empty array means no playable movies.
    func scan() -> [QuickTimeMovie]? {
        guard let pid = processID() else {
            Self.log.info("Movie scan: QuickTime Player is not running")
            return []
        }
        let result = executor.run(Self.scanScript)
        guard result.succeeded, let output = result.output,
              output.hasPrefix("OK\n"), processID() == pid else {
            Self.log.error("Movie scan failed: succeeded=\(result.succeeded), output=\(result.output ?? "nil", privacy: .public)")
            return nil
        }
        let rows = output.split(separator: "\n").dropFirst()
        let movies = parse(rows, pid: pid)
        if movies.count != rows.count {
            Self.log.error("Movie scan parsed \(movies.count) of \(rows.count) rows: \(output, privacy: .public)")
        }
        return movies
    }

    private func parse(_ rows: ArraySlice<Substring>, pid: Int32) -> [QuickTimeMovie] {
        rows.compactMap { row in
            let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let id = Int(fields[0]), id > 0,
                  fields[1] == "true" || fields[1] == "false" else { return nil }
            return QuickTimeMovie(processID: pid, windowID: id,
                                  title: String(fields[2]), isPlaying: fields[1] == "true")
        }
    }

    func toggle(_ movie: QuickTimeMovie) -> Bool {
        guard processID() == movie.processID else { return false }
        let result = executor.run(Self.script(for: movie, toggle: true))
        return result.succeeded && result.output == "OK"
    }

    func isPlaying(_ movie: QuickTimeMovie) -> Bool? {
        guard processID() == movie.processID else { return nil }
        let result = executor.run(Self.script(for: movie, toggle: false))
        guard result.succeeded else { return nil }
        switch result.output {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Jumps the chosen movie by `seconds`, clamped to its length.
    func seek(_ movie: QuickTimeMovie, by seconds: Int) -> Bool {
        guard processID() == movie.processID else { return false }
        let result = executor.run(Self.seekScript(for: movie, seconds: seconds))
        return result.succeeded && result.output == "OK"
    }

    /// The arithmetic stays in AppleScript; times read as text are
    /// locale-formatted (`12,5` on comma locales).
    static func seekScript(for movie: QuickTimeMovie, seconds: Int) -> String {
        """
        tell application "QuickTime Player"
            if not (exists window id \(movie.windowID)) then return "missing"
            set targetMovie to document of window id \(movie.windowID)
            if targetMovie is missing value then return "missing"
            set newTime to (current time of targetMovie) + (\(seconds))
            if newTime < 0 then set newTime to 0
            if newTime > (duration of targetMovie) then set newTime to duration of targetMovie
            set current time of targetMovie to newTime
            return "OK"
        end tell
        """
    }

    static func script(for movie: QuickTimeMovie, toggle: Bool) -> String {
        let action = toggle ? """
        if playing of targetMovie then
            stop targetMovie
        else
            play targetMovie
        end if
        return "OK"
        """ : "return (playing of targetMovie) as text"
        return """
        tell application "QuickTime Player"
            if not (exists window id \(movie.windowID)) then return "missing"
            set targetMovie to document of window id \(movie.windowID)
            if targetMovie is missing value then return "missing"
            if duration of targetMovie ≤ 0 then return "missing"
            \(action)
        end tell
        """
    }

    static let scanScript = """
    tell application "QuickTime Player"
        set rows to "OK" & linefeed
        repeat with movieWindow in windows
            try
                set movie to document of movieWindow
                if duration of movie > 0 then
                    set movieTitle to ""
                    set rawTitle to name of movie as text
                    repeat with c in characters of rawTitle
                        if c as text is in {tab, return, linefeed} then
                            set movieTitle to movieTitle & " "
                        else
                            set movieTitle to movieTitle & c
                        end if
                    end repeat
                    set rows to rows & (id of movieWindow as text) & tab & (playing of movie as text) & tab & movieTitle & linefeed
                end if
            end try
        end repeat
        return rows
    end tell
    """
}
