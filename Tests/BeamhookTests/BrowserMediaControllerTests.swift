import XCTest
import CoreServices
import BeamhookKit
@testable import Beamhook

final class BrowserMediaControllerTests: XCTestCase {
    func testCandidateIdentitySurvivesTabReordering() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        let sourceID = "550e8400-e29b-41d4-a716-446655440000"

        executor.output = scanOutput(window: 1, tab: 2, sourceID: sourceID)
        let first = controller.scan(.chrome).candidates.first
        executor.output = scanOutput(window: 4, tab: 9, sourceID: sourceID)
        let reordered = controller.scan(.chrome).candidates.first

        XCTAssertEqual(first?.id, reordered?.id)
        XCTAssertEqual(first?.id, "chrome:\(sourceID)")
        XCTAssertEqual(first?.windowIndex, 1)
        XCTAssertEqual(first?.tabIndex, 2)
        XCTAssertEqual(reordered?.windowIndex, 4)
        XCTAssertEqual(reordered?.tabIndex, 9)
    }

    func testInvalidPageSuppliedSourceIdentityIsRejected() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        executor.output = scanOutput(window: 1, tab: 1,
                                     sourceID: "'; do shell script \"bad\"; '")

        XCTAssertTrue(controller.scan(.safari).candidates.isEmpty)
    }

    func testSelectionResolvesSourceIdentityInsideBrowser() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        let candidate = makeCandidate()

        XCTAssertTrue(controller.select(candidate))

        let script = try? XCTUnwrap(executor.scripts.last)
        XCTAssertTrue(script?.contains(candidate.sourceID) == true)
        XCTAssertTrue(script?.contains("repeat with browserWindow in windows") == true)
        XCTAssertFalse(script?.contains("set targetTab to tab") == true)
    }

    func testVolumeWriteResolvesSourceIdentityInsideBrowser() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        let candidate = makeCandidate()

        XCTAssertTrue(controller.setVolume(75, for: candidate))

        let script = try? XCTUnwrap(executor.scripts.last)
        XCTAssertTrue(script?.contains(candidate.sourceID) == true)
        XCTAssertTrue(script?.contains("x.volume = 75 / 100") == true)
        XCTAssertTrue(script?.contains("set candidateTab to tab 9 of window 4") == true)
        XCTAssertTrue(script?.contains("targetFound is false") == true)
    }

    func testPlayPauseResolvesExactSourceIdentityInsideBrowser() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        let candidate = makeCandidate()

        XCTAssertTrue(controller.togglePlayPause(candidate))

        let script = try? XCTUnwrap(executor.scripts.last)
        XCTAssertTrue(script?.contains(candidate.sourceID) == true)
        XCTAssertTrue(script?.contains("repeat with browserWindow in windows") == true)
        XCTAssertTrue(script?.contains("set candidateTab to tab 9 of window 4") == true)
        XCTAssertTrue(script?.contains("if targetFound then") == true)
        let cachedLookup = script?.range(of: "set candidateTab to tab 9 of window 4")
        let fallbackLookup = script?.range(of: "repeat with browserWindow in windows")
        XCTAssertNotNil(cachedLookup)
        XCTAssertNotNil(fallbackLookup)
        if let cachedLookup, let fallbackLookup {
            XCTAssertLessThan(cachedLookup.lowerBound, fallbackLookup.lowerBound)
        }
        XCTAssertTrue(script?.contains("p.el.pause()") == true)
        XCTAssertTrue(script?.contains("p.el.play()") == true)
        XCTAssertFalse(script?.contains("set targetTab to tab") == true)
    }

    func testPlaybackStateReadsExactSourceIdentity() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        let candidate = makeCandidate()

        executor.output = "PLAYING"
        XCTAssertEqual(controller.isPlaying(candidate), true)
        executor.output = "PAUSED"
        XCTAssertEqual(controller.isPlaying(candidate), false)

        let script = try? XCTUnwrap(executor.scripts.last)
        XCTAssertTrue(script?.contains(candidate.sourceID) == true)
        XCTAssertTrue(script?.contains("set candidateTab to tab 9 of window 4") == true)
        XCTAssertTrue(script?.contains("repeat with browserWindow in windows") == true)
        let cachedLookup = script?.range(of: "set candidateTab to tab 9 of window 4")
        let fallbackLookup = script?.range(of: "repeat with browserWindow in windows")
        XCTAssertNotNil(cachedLookup)
        XCTAssertNotNil(fallbackLookup)
        if let cachedLookup, let fallbackLookup {
            XCTAssertLessThan(cachedLookup.lowerBound, fallbackLookup.lowerBound)
        }
    }

    func testPlaybackStateReturnsNilWhenExactSourceCannotBeRead() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        executor.output = "NO"

        XCTAssertNil(controller.isPlaying(makeCandidate()))

        executor.succeeds = false
        XCTAssertNil(controller.isPlaying(makeCandidate()))
    }

    func testTargetedSafariPlaybackStateAppleScriptCompiles() throws {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        executor.output = "PLAYING"

        XCTAssertEqual(controller.isPlaying(makeCandidate(browser: .safari)), true)

        let source = try XCTUnwrap(executor.scripts.last)
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])")
    }

    func testNextAndPreviousUseValidatedCachedTarget() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        let candidate = makeCandidate()

        XCTAssertTrue(controller.perform(.next, on: candidate))
        XCTAssertTrue(executor.scripts.last?.contains(".ytp-next-button") == true)
        XCTAssertTrue(executor.scripts.last?.contains(
            "set candidateTab to tab 9 of window 4"
        ) == true)

        XCTAssertTrue(controller.perform(.previous, on: candidate))
        XCTAssertTrue(executor.scripts.last?.contains(".ytp-prev-button") == true)
    }

    func testTargetedSafariActionAppleScriptCompiles() throws {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)

        XCTAssertTrue(controller.togglePlayPause(makeCandidate(browser: .safari)))

        let source = try XCTUnwrap(executor.scripts.last)
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])")
    }

    func testFocusResolvesSourceIdentityInsideBrowser() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        let candidate = makeCandidate()

        XCTAssertTrue(controller.focus(candidate))

        let script = try? XCTUnwrap(executor.scripts.last)
        // Focus must be aimed by the page-owned identity, never by the cached
        // position alone: raising the wrong tab is a visible, focus-stealing
        // mistake, and the cache is stale the moment a tab moves.
        XCTAssertTrue(script?.contains(candidate.sourceID) == true)
        XCTAssertTrue(script?.contains("repeat with browserWindow in windows") == true)
        XCTAssertTrue(script?.contains("targetFound is false") == true)
    }

    func testFocusRaisesTheMatchingTabAndItsWindow() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)

        XCTAssertTrue(controller.focus(makeCandidate(browser: .safari)))
        let safari = try? XCTUnwrap(executor.scripts.last)
        XCTAssertTrue(safari?.contains("set current tab of browserWindow") == true)
        XCTAssertTrue(safari?.contains("set index of browserWindow to 1") == true)

        XCTAssertTrue(controller.focus(makeCandidate(browser: .chrome)))
        let chrome = try? XCTUnwrap(executor.scripts.last)
        XCTAssertTrue(chrome?.contains("set active tab index of browserWindow") == true)
        XCTAssertTrue(chrome?.contains("set index of browserWindow to 1") == true)
    }

    func testSafariFocusAppleScriptCompiles() throws {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)

        XCTAssertTrue(controller.focus(makeCandidate(browser: .safari)))

        let source = try XCTUnwrap(executor.scripts.last)
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])")
    }

    func testChromiumFocusAppleScriptCompiles() throws {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)

        XCTAssertTrue(controller.focus(makeCandidate(browser: .brave)))

        let source = try XCTUnwrap(executor.scripts.last)
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])")
    }

    // MARK: - Frozen Chromium tabs

    func testChromiumScanAsksEveryTabAtOnce() {
        let executor = ChromiumTabsExecutor(tabs: [(1, 1, "101"), (1, 2, "102"), (2, 1, "103")])
        executor.delay = 0.2
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)

        let scan = controller.scan(.chrome)

        // Chrome answers a frozen tab never, so each one waits out its timeout.
        // Asked one after another, a window of frozen tabs took minutes.
        XCTAssertEqual(executor.maxInFlight, 3)
        XCTAssertTrue(scan.injectionAvailable)
        XCTAssertEqual(Set(scan.candidates.map(\.tabIndex)), [1, 2])
        XCTAssertEqual(scan.candidates.count, 3)
    }

    func testChromiumScanAsksTabsWithoutTheAppleScriptInterpreter() {
        let executor = ChromiumTabsExecutor(tabs: [(1, 1, "101"), (1, 2, "102")])
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)

        _ = controller.scan(.chrome)

        // Scripts running at once inside the interpreter corrupted 1.5.3's heap.
        // Only the tab listing may be a script; the per-tab questions are events.
        XCTAssertEqual(executor.scripts.count, 1)
        XCTAssertFalse(executor.scripts.contains { $0.contains("javascript") })
        XCTAssertEqual(executor.evaluations, 2)
    }

    func testExecuteEventAddressesAChromeTabByPosition() throws {
        let event = AppleEventTabEvaluator.executeEvent("1 + 1", in: .chrome, window: 2, tab: 3)

        XCTAssertEqual(event.eventClass, fourCharCode("CrSu"))
        XCTAssertEqual(event.eventID, fourCharCode("ExJa"))
        XCTAssertEqual(event.paramDescriptor(forKeyword: fourCharCode("JvSc"))?.stringValue, "1 + 1")
        XCTAssertEqual(
            targetBundleID(event),
            "com.google.Chrome")
        let tab = try XCTUnwrap(specifier(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))))
        XCTAssertEqual(tab.desiredClass, fourCharCode("CrTb"))
        XCTAssertEqual(tab.index, 3)
        let window = try XCTUnwrap(specifier(tab.container))
        XCTAssertEqual(window.desiredClass, fourCharCode("cwin"))
        XCTAssertEqual(window.index, 2)
        XCTAssertEqual(window.container?.descriptorType, DescType(typeNull))
    }

    func testExecuteEventUsesArcsOwnClassCodes() throws {
        let event = AppleEventTabEvaluator.executeEvent("1 + 1", in: .arc, window: 1, tab: 4)

        // Arc's dictionary names its windows and tabs differently from Chromium's.
        let tab = try XCTUnwrap(specifier(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))))
        XCTAssertEqual(tab.desiredClass, fourCharCode("tAbB"))
        XCTAssertEqual(try XCTUnwrap(specifier(tab.container)).desiredClass, fourCharCode("WiND"))
        XCTAssertEqual(
            targetBundleID(event),
            "company.thebrowser.Browser")
    }

    func testSilentChromiumTabIsLeftOutAndSkippedByTheWalks() throws {
        let executor = ChromiumTabsExecutor(tabs: [(1, 1, "101"), (1, 2, "102"), (1, 3, "103")])
        executor.silentTabIDs = ["102"]
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)

        let scan = controller.scan(.chrome)

        XCTAssertTrue(scan.injectionAvailable)
        XCTAssertEqual(scan.candidates.map(\.tabIndex).sorted(), [1, 3])
        let candidate = try XCTUnwrap(scan.candidates.first)
        _ = controller.select(candidate)
        XCTAssertTrue(executor.scripts.last?.contains(#"set silentTabIDs to {"102"}"#) == true)
        _ = controller.focus(candidate)
        XCTAssertTrue(executor.scripts.last?.contains(#"set silentTabIDs to {"102"}"#) == true)
        _ = controller.togglePlayPause(candidate)
        XCTAssertTrue(executor.scripts.last?.contains(#"set silentTabIDs to {"102"}"#) == true)
    }

    func testChromiumTabThatAnswersAgainIsNoLongerSkipped() {
        let executor = ChromiumTabsExecutor(tabs: [(1, 1, "101"), (1, 2, "102")])
        executor.silentTabIDs = ["102"]
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        _ = controller.scan(.chrome)

        // A frozen tab revives when the user switches to it, and may start playing.
        executor.silentTabIDs = []
        let scan = controller.scan(.chrome)

        XCTAssertEqual(scan.candidates.count, 2)
        _ = controller.select(scan.candidates[0])
        XCTAssertTrue(executor.scripts.last?.contains("set silentTabIDs to {}") == true)
    }

    func testChromiumScanWhereNoTabAnswersIsUnavailable() {
        let executor = ChromiumTabsExecutor(tabs: [(1, 1, "101"), (1, 2, "102")])
        executor.silentTabIDs = ["101", "102"]
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)

        XCTAssertFalse(controller.scan(.chrome).injectionAvailable)
    }

    func testChromiumScanWithoutWindowsIsAvailableAndEmpty() {
        let executor = ChromiumTabsExecutor(tabs: [])
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)

        let scan = controller.scan(.chrome)

        XCTAssertTrue(scan.injectionAvailable)
        XCTAssertTrue(scan.candidates.isEmpty)
    }

    func testChromiumScanAndWalkAppleScriptsCompile() throws {
        let executor = ChromiumTabsExecutor(tabs: [(1, 1, "101"), (1, 2, "102")])
        executor.silentTabIDs = ["102"]
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        let candidate = try XCTUnwrap(controller.scan(.brave).candidates.first)
        _ = controller.select(candidate)
        _ = controller.togglePlayPause(candidate)
        _ = controller.isPlaying(candidate)
        _ = controller.transportFacts(candidate)
        _ = controller.focus(candidate)

        for source in Set(executor.scripts) {
            let script = try XCTUnwrap(NSAppleScript(source: source))
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])\n\(source)")
        }
    }

    func testCallTabIsListedButCannotBeDrivenByTransport() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        executor.output = scanOutput(window: 1, tab: 1,
                                     sourceID: "550e8400-e29b-41d4-a716-446655440000",
                                     live: true)

        let candidates = controller.scan(.chrome).candidates

        // A meeting keeps its row — the volume slider is the point — but must
        // never offer transport: pausing a live MediaStream freezes the call.
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.supportsTransport, false)
    }

    func testRegularMediaTabSupportsTransport() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        executor.output = scanOutput(window: 1, tab: 1,
                                     sourceID: "550e8400-e29b-41d4-a716-446655440000")

        XCTAssertEqual(controller.scan(.chrome).candidates.first?.supportsTransport, true)
    }

    func testEachSourceCarriesItsOwnTransportCapability() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        let meeting = "550e8400-e29b-41d4-a716-446655440000"
        let video = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
        executor.output = """
        OK
        \(row(window: 1, tab: 1, sourceID: meeting, live: true))
        \(row(window: 1, tab: 2, sourceID: video, live: false))
        """

        let candidates = controller.scan(.safari).candidates

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.first(where: { $0.sourceID == meeting })?.supportsTransport,
                       false)
        XCTAssertEqual(candidates.first(where: { $0.sourceID == video })?.supportsTransport,
                       true)
    }

    func testScanCarriesTheTabHostname() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        executor.output = scanOutput(window: 1, tab: 1,
                                     sourceID: "550e8400-e29b-41d4-a716-446655440000",
                                     host: "music.youtube.com")

        // The hostname is what badges the menu-bar icon; the title can't stand in
        // for it, since a page is free to call itself anything.
        XCTAssertEqual(controller.scan(.chrome).candidates.first?.host, "music.youtube.com")
    }

    func testTabWithoutAHostStillYieldsACandidate() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        executor.output = """
        OK
        1\t1\t{"sourceID":"550e8400-e29b-41d4-a716-446655440000","title":"Local file","artist":"","playing":true,"selected":false,"live":false,"volume":50}
        """

        // A file:// or about: tab reports no host. That costs the icon its badge,
        // never the tab its row.
        let candidates = controller.scan(.safari).candidates
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.host, "")
    }

    func testTransportScriptsDeclineALiveStream() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)

        _ = controller.togglePlayPause(makeCandidate())
        let playPause = executor.scripts.last
        _ = controller.setVolume(30, for: makeCandidate())
        let volume = executor.scripts.last

        // The backstop behind the hidden UI control: even a stale selection that
        // reaches a call tab must refuse to touch its transport. Volume, which is
        // meaningful on a call, carries no such guard and writes the whole group.
        XCTAssertTrue(playPause?.contains("if (!p || p.live) return 'NO'") == true)
        XCTAssertTrue(volume?.contains("p.group.forEach") == true)
        XCTAssertFalse(volume?.contains("p.live") == true)
    }

    private func makeCandidate(browser: BrowserKind = .chrome) -> BrowserMediaCandidate {
        BrowserMediaCandidate(
            browser: browser,
            sourceID: "550e8400-e29b-41d4-a716-446655440000",
            windowIndex: 4,
            tabIndex: 9,
            title: "Test video",
            artist: "Test artist",
            host: "www.youtube.com",
            isPlaying: true,
            isSelected: false,
            supportsTransport: true,
            volume: 50
        )
    }

    private func scanOutput(window: Int, tab: Int, sourceID: String,
                            live: Bool = false, host: String = "www.youtube.com") -> String {
        """
        OK
        \(row(window: window, tab: tab, sourceID: sourceID, live: live, host: host))
        """
    }

    private func row(window: Int, tab: Int, sourceID: String, live: Bool,
                     host: String = "www.youtube.com") -> String {
        let escapedID = sourceID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        \(window)\t\(tab)\t{"sourceID":"\(escapedID)","title":"Test","artist":"","host":"\(host)","playing":true,"selected":false,"live":\(live),"volume":50}
        """
    }

    // MARK: - Short skip

    func testTransportFactsDecodeThePagesAnswer() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        executor.output = #"{"host":"youtube.com","duration":3600.5,"hasListParam":false,"nextButton":"enabled","live":false}"#
        let facts = controller.transportFacts(makeCandidate())
        XCTAssertEqual(facts, BrowserPlaybackFacts(host: "youtube.com", duration: 3600.5,
                                                   hasListParam: false, nextButton: .enabled, live: false))
        let script = executor.scripts.last ?? ""
        XCTAssertTrue(script.contains("550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertTrue(script.contains("hasListParam"))
        XCTAssertTrue(script.contains("ytmusic-player-bar .next-button"))
        XCTAssertTrue(script.contains(".inline_player .nextbutton"))
    }

    func testTransportFactsAreNilWhenTheSourceIsGoneOrScriptFails() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        executor.output = "NO"
        XCTAssertNil(controller.transportFacts(makeCandidate()))
        executor.output = "{}"
        executor.succeeds = false
        XCTAssertNil(controller.transportFacts(makeCandidate()))
    }

    func testSeekMovesCurrentTimeBySignedSeconds() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        XCTAssertTrue(controller.seek(by: -10, on: makeCandidate()))
        let script = executor.scripts.last ?? ""
        XCTAssertTrue(script.contains("currentTime"))
        XCTAssertTrue(script.contains("(-10)"))
    }

    func testBrowserScriptsKeepJavaScriptFreeOfDoubleQuotes() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        _ = controller.transportFacts(makeCandidate())
        _ = controller.seek(by: 15, on: makeCandidate())
        let prefix = "set javascriptSource to \""
        for script in executor.scripts {
            // Take the whole line after the prefix and drop only the final
            // closing quote, so a mid-line quote can't hide.
            let line = script.components(separatedBy: prefix).dropFirst().first?
                .components(separatedBy: "\n").first ?? ""
            XCTAssertTrue(line.hasSuffix("\""))
            let js = String(line.dropLast())
            XCTAssertFalse(js.isEmpty)
            XCTAssertFalse(js.contains("\""))
            XCTAssertFalse(js.contains("\\"))
        }
    }

    func testNextAndPreviousAlsoReachBandcampAndYouTubeMusicButtons() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor, tabEvaluator: executor)
        _ = controller.perform(.next, on: makeCandidate())
        _ = controller.perform(.previous, on: makeCandidate())
        XCTAssertTrue(executor.scripts[0].contains(".inline_player .nextbutton"))
        XCTAssertTrue(executor.scripts[1].contains(".inline_player .prevbutton"))
        XCTAssertFalse(executor.scripts[0].contains("'.nextbutton"))
        XCTAssertFalse(executor.scripts[1].contains("'.prevbutton"))
        XCTAssertTrue(executor.scripts[0].contains("document.querySelector('ytmusic-player-bar .next-button') || document.querySelector('.ytp-next-button')"))
        XCTAssertTrue(executor.scripts[1].contains("document.querySelector('ytmusic-player-bar .previous-button') || document.querySelector('.ytp-prev-button')"))
        XCTAssertTrue(executor.scripts[0].contains("ytmusic-player-bar .next-button"))
        XCTAssertTrue(executor.scripts[1].contains("ytmusic-player-bar .previous-button"))
    }
}

final class PlaybackStatusTests: XCTestCase {
    func testUnknownPlaybackIsNotRenderedOrToggledAsPaused() {
        let music = context(target: "music", revision: 1)
        var status = PlaybackStatus()
        status.reset(for: music)
        XCTAssertEqual(PlaybackStatus.symbol(for: status.isPlaying), "playpause.fill")
        XCTAssertTrue(status.beginToggle(for: music))
        XCTAssertNil(status.isPlaying)
        status.finishToggle(succeeded: false, confirmedState: nil, previousState: nil, for: music)
        XCTAssertNil(status.isPlaying)
    }

    func testFirstGrantedCommandUsesConfirmedState() {
        let music = context(target: "music", revision: 1)
        var status = PlaybackStatus()
        status.reset(for: music)
        XCTAssertTrue(status.beginToggle(for: music))
        status.finishToggle(succeeded: true, confirmedState: false, previousState: nil, for: music)
        XCTAssertEqual(status.isPlaying, false)
        XCTAssertEqual(PlaybackStatus.symbol(for: status.isPlaying), "play.fill")
        XCTAssertEqual(PlaybackStatus.symbol(for: true), "pause.fill")
    }

    func testLatePollFromPreviousTargetIsIgnored() throws {
        let safari = context(target: "safari-youtube", source: "safari:video", revision: 1)
        let spotify = context(target: "spotify", revision: 2)
        var status = PlaybackStatus()

        status.reset(for: safari)
        observe(true, for: safari, with: &status)
        let staleObservation = try XCTUnwrap(status.observation(for: safari))
        status.reset(for: spotify)
        observe(false, for: spotify, with: &status)
        status.accept(true, from: staleObservation)

        XCTAssertEqual(status.context, spotify)
        XCTAssertEqual(status.isPlaying, false)
    }

    func testLateCommandCompletionCannotOverwriteNewTarget() {
        let safari = context(target: "safari-youtube", source: "safari:video", revision: 1)
        let spotify = context(target: "spotify", revision: 2)
        var status = PlaybackStatus()

        status.reset(for: safari)
        observe(true, for: safari, with: &status)
        XCTAssertTrue(status.beginToggle(for: safari))
        status.reset(for: spotify)
        observe(true, for: spotify, with: &status)
        status.finishToggle(
            succeeded: false,
            confirmedState: nil,
            previousState: true,
            for: safari
        )

        XCTAssertEqual(status.context, spotify)
        XCTAssertEqual(status.isPlaying, true)
        XCTAssertFalse(status.commandInFlight)
    }

    func testOldCompletionIsIgnoredAfterSwitchingBackToSameTarget() {
        let firstSafari = context(
            target: "safari-youtube",
            source: "safari:video",
            revision: 1
        )
        let spotify = context(target: "spotify", revision: 2)
        let secondSafari = context(
            target: "safari-youtube",
            source: "safari:video",
            revision: 3
        )
        var status = PlaybackStatus()

        status.reset(for: firstSafari)
        XCTAssertTrue(status.beginToggle(for: firstSafari))
        status.reset(for: spotify)
        status.reset(for: secondSafari)
        observe(false, for: secondSafari, with: &status)
        status.finishToggle(
            succeeded: true,
            confirmedState: true,
            previousState: false,
            for: firstSafari
        )

        XCTAssertEqual(status.context, secondSafari)
        XCTAssertEqual(status.isPlaying, false)
    }

    func testStaleConfirmationDoesNotReverseOptimisticToggle() {
        let spotify = context(target: "spotify", revision: 1)
        var status = PlaybackStatus()

        status.reset(for: spotify)
        observe(false, for: spotify, with: &status)
        XCTAssertTrue(status.beginToggle(for: spotify))
        XCTAssertEqual(status.isPlaying, true)
        status.finishToggle(
            succeeded: true,
            confirmedState: false,
            previousState: false,
            for: spotify
        )

        XCTAssertEqual(status.isPlaying, true)
        XCTAssertFalse(status.commandInFlight)
    }

    func testPollStartedBeforeToggleIsIgnoredAfterCommandFinishes() throws {
        let spotify = context(target: "spotify", revision: 1)
        var status = PlaybackStatus()

        status.reset(for: spotify)
        observe(false, for: spotify, with: &status)
        let preCommandObservation = try XCTUnwrap(status.observation(for: spotify))
        XCTAssertTrue(status.beginToggle(for: spotify))
        status.finishToggle(
            succeeded: true,
            confirmedState: true,
            previousState: false,
            for: spotify
        )
        status.accept(false, from: preCommandObservation)

        XCTAssertEqual(status.isPlaying, true)
    }

    func testMatchingConfirmationKeepsOptimisticState() {
        let spotify = context(target: "spotify", revision: 1)
        var status = PlaybackStatus()

        status.reset(for: spotify)
        observe(false, for: spotify, with: &status)
        XCTAssertTrue(status.beginToggle(for: spotify))
        status.finishToggle(
            succeeded: true,
            confirmedState: true,
            previousState: false,
            for: spotify
        )

        XCTAssertEqual(status.isPlaying, true)
        XCTAssertFalse(status.commandInFlight)
    }

    func testFailedToggleRestoresPreviousState() {
        let spotify = context(target: "spotify", revision: 1)
        var status = PlaybackStatus()

        status.reset(for: spotify)
        observe(false, for: spotify, with: &status)
        XCTAssertTrue(status.beginToggle(for: spotify))
        status.finishToggle(
            succeeded: false,
            confirmedState: nil,
            previousState: false,
            for: spotify
        )

        XCTAssertEqual(status.isPlaying, false)
        XCTAssertFalse(status.commandInFlight)
    }

    private func observe(
        _ value: Bool?,
        for context: PlaybackTargetContext,
        with status: inout PlaybackStatus
    ) {
        guard let observation = status.observation(for: context) else {
            XCTFail("Expected playback observation")
            return
        }
        status.accept(value, from: observation)
    }

    private func context(
        target: String?,
        source: String? = nil,
        revision: UInt64
    ) -> PlaybackTargetContext {
        PlaybackTargetContext(
            targetID: target,
            browserMediaID: source,
            revision: revision
        )
    }
}

private func fourCharCode(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}

/// The bundle id an Apple Event is addressed to.
private func targetBundleID(_ event: NSAppleEventDescriptor) -> String? {
    guard let address = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)),
          address.descriptorType == DescType(typeApplicationBundleID) else { return nil }
    return String(data: address.data, encoding: .utf8)
}

/// The class, index and container of an index-form object specifier.
private func specifier(_ descriptor: NSAppleEventDescriptor?)
    -> (desiredClass: FourCharCode, index: Int32, container: NSAppleEventDescriptor?)? {
    guard let descriptor, descriptor.descriptorType == DescType(typeObjectSpecifier),
          let record = descriptor.coerce(toDescriptorType: DescType(typeAERecord)),
          let desiredClass = record.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue,
          let index = record.forKeyword(AEKeyword(keyAEKeyData))?.int32Value
    else { return nil }
    return (desiredClass, index, record.forKeyword(AEKeyword(keyAEContainer)))
}

/// Plays a Chromium browser for the two-step scan: the tab listing script, then
/// one page evaluation per tab, run concurrently. A tab in `silentTabIDs` fails
/// the way a frozen tab does — the send times out — and every other tab answers
/// with media.
private final class ChromiumTabsExecutor: ScriptExecuting, ChromiumTabEvaluating,
                                          @unchecked Sendable {
    let tabs: [(window: Int, tab: Int, id: String)]
    var silentTabIDs: Set<String> = []
    var delay: TimeInterval = 0
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private var evaluated = 0
    var evaluations: Int { lock.withLock { evaluated } }
    private var recorded: [String] = []
    var scripts: [String] { lock.withLock { recorded } }

    init(tabs: [(window: Int, tab: Int, id: String)]) {
        self.tabs = tabs
    }

    func run(_ source: String) -> ScriptResult {
        lock.withLock { recorded.append(source) }
        if source.contains("id of tab") {
            let rows = tabs.map { "\($0.window)\t\($0.tab)\t\($0.id)" }
            return ScriptResult(output: (["OK"] + rows).joined(separator: "\n"), succeeded: true)
        }
        return ScriptResult(output: "true", succeeded: true)
    }

    func evaluate(_ javascript: String, in browser: BrowserKind,
                  window: Int, tab: Int, timeout: TimeInterval) -> ScriptResult {
        lock.withLock {
            evaluated += 1
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }

        Thread.sleep(forTimeInterval: delay)
        guard let entry = tabs.first(where: { $0.window == window && $0.tab == tab }),
              !silentTabIDs.contains(entry.id) else {
            return ScriptResult(output: nil, succeeded: false)
        }
        let sourceID = "550e8400-e29b-41d4-a716-44665544\(entry.id.suffix(4).padding(toLength: 4, withPad: "0", startingAt: 0))"
        return ScriptResult(
            output: #"{"sourceID":"\#(sourceID)","title":"Test","artist":"","host":"www.youtube.com","playing":true,"selected":false,"live":false,"volume":50}"#,
            succeeded: true)
    }
}

/// Answers every script with `output`. As a Chromium browser it lists the rows
/// of `output` as its tabs, and each tab's page answers with its row's JSON.
private final class RecordingScriptExecutor: ScriptExecuting, ChromiumTabEvaluating,
                                             @unchecked Sendable {
    var scripts: [String] = []
    var output: String? = "true"
    var succeeds = true

    func run(_ source: String) -> ScriptResult {
        scripts.append(source)
        return ScriptResult(output: output, succeeded: succeeds)
    }

    func evaluate(_ javascript: String, in browser: BrowserKind,
                  window: Int, tab: Int, timeout: TimeInterval) -> ScriptResult {
        let row = output?.split(separator: "\n").dropFirst().first {
            $0.hasPrefix("\(window)\t\(tab)\t")
        }
        return ScriptResult(output: row.map { String($0.split(separator: "\t", maxSplits: 2)[2]) },
                            succeeded: succeeds)
    }
}
