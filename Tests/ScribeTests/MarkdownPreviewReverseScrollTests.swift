//
//  MarkdownPreviewReverseScrollTests.swift
//  Phase 52c — preview → editor scroll sync. Three testable
//  Swift-side surfaces:
//
//    1. `Document.previewViewportTopLine` — the reverse conduit.
//    2. `Coordinator.handleScrollMessage(name:body:)` — the Swift
//       dispatcher the JS `scribeScroll` message feeds into. This
//       is the bit that decides whether to propagate, drop, or
//       silently ignore each incoming payload.
//    3. `revealLineScript` contents — the JS string literal the
//       shell injects. We pin the structural invariants (scroll
//       listener exists, programmatic-scroll guard exists, rAF
//       throttle exists, postMessage target is `scribeScroll`).
//
//  The JS side's actual rAF / getBoundingClientRect behaviour
//  needs a live WKWebView and is out of scope for unit tests — the
//  integration is exercised by the manual demo checklist.
//

import XCTest
@testable import Scribe

@MainActor
final class MarkdownPreviewReverseScrollTests: XCTestCase {

    // MARK: - Document.previewViewportTopLine

    func test_previewViewportTopLineDefaultsToOne() {
        // Same convention as viewportTopLine: 1-based, starts at
        // "top of doc". The editor's fast-path gate in
        // `consumePreviewScrollIfNeeded` treats the *first*
        // distinct publish as the first real sync, not the
        // constructor's seed value.
        let doc = Document(title: "t")
        XCTAssertEqual(doc.previewViewportTopLine, 1)
    }

    func test_previewViewportTopLineIsPublished() {
        // @Published so SwiftUI re-evaluates ScintillaCodeEditor's
        // updateNSView whenever the preview publishes a new top
        // line. If the publisher is missing, the reverse leg dies
        // silently at the Document boundary.
        let doc = Document(title: "t")
        var tickCount = 0
        let cancellable = doc.$previewViewportTopLine.sink { _ in tickCount += 1 }
        doc.previewViewportTopLine = 17
        // Combine delivers initial + new.
        XCTAssertEqual(tickCount, 2)
        cancellable.cancel()
    }

    // MARK: - handleScrollMessage filtering

    func test_handleScrollMessage_acceptsValidPayload() {
        // The happy path: the JS listener posted a positive 1-based
        // line. We should capture it as the last-reported value and
        // fire the callback.
        let coord = MarkdownPreviewPane.Coordinator()
        var captured: Int?
        coord.onPreviewScroll = { captured = $0 }
        coord.handleScrollMessage(name: "scribeScroll", body: NSNumber(value: 42))
        XCTAssertEqual(captured, 42)
        XCTAssertEqual(coord.lastReportedPreviewLine, 42)
    }

    func test_handleScrollMessage_rejectsWrongName() {
        // WKUserContentController is shared infrastructure; a
        // future message handler on a different name must not
        // accidentally drive the scroll sync. The filter on
        // `message.name == "scribeScroll"` is load-bearing.
        let coord = MarkdownPreviewPane.Coordinator()
        var called = false
        coord.onPreviewScroll = { _ in called = true }
        coord.handleScrollMessage(name: "somethingElse",
                                  body: NSNumber(value: 12))
        XCTAssertFalse(called)
        XCTAssertEqual(coord.lastReportedPreviewLine, 0)
    }

    func test_handleScrollMessage_rejectsNonNumberBody() {
        // A malformed JS patch could post a string or dict. We
        // should drop the message rather than crash on a forced
        // cast.
        let coord = MarkdownPreviewPane.Coordinator()
        var called = false
        coord.onPreviewScroll = { _ in called = true }
        coord.handleScrollMessage(name: "scribeScroll", body: "hello")
        XCTAssertFalse(called)
        XCTAssertEqual(coord.lastReportedPreviewLine, 0)
    }

    func test_handleScrollMessage_rejectsNonPositiveLine() {
        // `scribeTopBlockLine` returns `0` when the block index is
        // empty. The JS-side `scribePostScroll` already filters
        // that, but the Swift-side belt-and-braces guards too —
        // a negative or zero line isn't a valid source-line
        // coordinate.
        let coord = MarkdownPreviewPane.Coordinator()
        var called = false
        coord.onPreviewScroll = { _ in called = true }
        coord.handleScrollMessage(name: "scribeScroll", body: NSNumber(value: 0))
        coord.handleScrollMessage(name: "scribeScroll", body: NSNumber(value: -3))
        XCTAssertFalse(called)
        XCTAssertEqual(coord.lastReportedPreviewLine, 0)
    }

    func test_handleScrollMessage_updatesLastReportedEvenWithoutCallback() {
        // Some integration tests don't attach a callback but still
        // want to observe the last line the preview reported. The
        // state write happens *before* the callback so those tests
        // can read it even when the callback is nil.
        let coord = MarkdownPreviewPane.Coordinator()
        coord.onPreviewScroll = nil
        coord.handleScrollMessage(name: "scribeScroll", body: NSNumber(value: 7))
        XCTAssertEqual(coord.lastReportedPreviewLine, 7)
    }

    // MARK: - revealLineScript structural invariants

    func test_revealLineScript_stampsProgrammaticScrollEpoch() {
        // The ping-pong guard rests entirely on this timestamp
        // being written *before* `scrollIntoView`. If the stamp is
        // missing, an editor-driven reveal would immediately
        // bounce back through `scribePostScroll` and create an
        // infinite scroll loop.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("__scribeProgrammaticScroll"),
                      "programmatic-scroll epoch variable missing")
        XCTAssertTrue(js.contains("__scribeProgrammaticScroll = Date.now()"),
                      "reveal helper must stamp the epoch before scrolling")
    }

    func test_revealLineScript_installsScrollListener() {
        // Plain `window.addEventListener('scroll', …)` with
        // `{passive: true}` — anything less and we'd block the
        // compositor thread on every wheel tick.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("addEventListener('scroll'"),
                      "scroll listener must be registered")
        XCTAssertTrue(js.contains("passive: true"),
                      "scroll listener must be passive")
    }

    func test_revealLineScript_usesRequestAnimationFrame() {
        // rAF throttling keeps the postMessage flood bounded to
        // ~60 Hz; without it a smooth scroll fires dozens of
        // events per second and the WKScriptMessage queue backs
        // up.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("requestAnimationFrame"),
                      "scroll handler must be rAF-throttled")
    }

    func test_revealLineScript_postsToScribeScrollChannel() {
        // The Swift side registers the handler under the name
        // "scribeScroll"; the JS side has to post to the same
        // name or nothing ever reaches the Coordinator.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("webkit.messageHandlers.scribeScroll.postMessage"),
                      "JS must post to the scribeScroll handler")
    }

    func test_revealLineScript_guardsAgainstMissingBridge() {
        // Running the script in a non-WKWebView context (tests,
        // standalone render) would crash on `webkit.messageHandlers`
        // if we didn't null-check first. The guard lets the shell
        // degrade gracefully.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("!window.webkit"),
                      "scroll reporter must guard the WKWebView bridge")
    }

    func test_revealLineScript_respectsProgrammaticScrollGuard() {
        // The 250 ms window is the lower bound for the ping-pong
        // mute. Anything shorter risks genuine user scrolls being
        // swallowed; anything longer delays the reverse sync
        // noticeably. Pin the exact threshold as a regression hook.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("Date.now() - window.__scribeProgrammaticScroll < 250"),
                      "scroll handler must mute replies within 250 ms of a reveal")
    }

    func test_revealLineScript_exportsScribeTopBlockLine() {
        // The helper is the one the scroll listener calls to pick
        // which block to report. Exposed on `window` so future
        // manual-driven tests (e.g. evaluateJavaScript with a
        // stubbed scroll offset) can exercise it.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("window.scribeTopBlockLine"),
                      "top-block helper must be exported for JS callers")
        XCTAssertTrue(js.contains("getBoundingClientRect"),
                      "top-block helper must inspect geometry")
    }
}
