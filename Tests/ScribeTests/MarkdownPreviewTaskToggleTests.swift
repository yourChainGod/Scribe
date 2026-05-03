//
//  MarkdownPreviewTaskToggleTests.swift
//  Phase 53b — preview-side click → editor toggle. Three Swift
//  surfaces under test:
//
//    1. `Coordinator.handleScrollMessage` — the dispatcher now
//       splits on the message name to either scroll or toggle.
//    2. `revealLineScript` — JS string contains the structural
//       pieces the click handler needs (delegated listener,
//       `.scribe-task` selector, postMessage to scribeToggleTask).
//    3. MarkdownConverter — emits a clickable checkbox with the
//       `scribe-task` class so the JS selector matches.
//
//  The actual click event flow needs a live WKWebView and is
//  exercised manually; the structural invariants pinned here
//  guarantee the wiring stays correct across refactors.
//

import XCTest
@testable import Scribe

@MainActor
final class MarkdownPreviewTaskToggleTests: XCTestCase {

    // MARK: - Coordinator dispatch

    func test_handleScrollMessage_routesScrollName() {
        // Existing scroll path must still flow into onPreviewScroll
        // and stamp `lastReportedPreviewLine`. Adding the toggle
        // arm should not break the scroll arm — pin it explicitly.
        let coord = MarkdownPreviewPane.Coordinator()
        var scrollCaptured: Int?
        var toggleCaptured: Int?
        coord.onPreviewScroll = { scrollCaptured = $0 }
        coord.onToggleTask = { toggleCaptured = $0 }
        coord.handleScrollMessage(name: "scribeScroll",
                                  body: NSNumber(value: 11))
        XCTAssertEqual(scrollCaptured, 11)
        XCTAssertEqual(coord.lastReportedPreviewLine, 11)
        XCTAssertNil(toggleCaptured, "toggle handler must not fire on scroll name")
        XCTAssertEqual(coord.lastToggledTaskLine, 0)
    }

    func test_handleScrollMessage_routesToggleName() {
        // The new arm. Click handler in the preview posts a line
        // number under the `scribeToggleTask` name; we stamp
        // `lastToggledTaskLine` and fire `onToggleTask`.
        let coord = MarkdownPreviewPane.Coordinator()
        var scrollCaptured: Int?
        var toggleCaptured: Int?
        coord.onPreviewScroll = { scrollCaptured = $0 }
        coord.onToggleTask = { toggleCaptured = $0 }
        coord.handleScrollMessage(name: "scribeToggleTask",
                                  body: NSNumber(value: 7))
        XCTAssertEqual(toggleCaptured, 7)
        XCTAssertEqual(coord.lastToggledTaskLine, 7)
        XCTAssertNil(scrollCaptured, "scroll handler must not fire on toggle name")
    }

    func test_handleScrollMessage_dropsUnknownName() {
        // Any other handler name is silently dropped — protects
        // the dispatcher against future siblings landing on the
        // shared userContentController without an explicit case
        // here.
        let coord = MarkdownPreviewPane.Coordinator()
        var scrollCaptured: Int?
        var toggleCaptured: Int?
        coord.onPreviewScroll = { scrollCaptured = $0 }
        coord.onToggleTask = { toggleCaptured = $0 }
        coord.handleScrollMessage(name: "scribeMystery",
                                  body: NSNumber(value: 4))
        XCTAssertNil(scrollCaptured)
        XCTAssertNil(toggleCaptured)
    }

    func test_handleToggle_rejectsNonNumberBody() {
        // Same defensive shape as the scroll path: a string body
        // must not crash or call the handler.
        let coord = MarkdownPreviewPane.Coordinator()
        var called = false
        coord.onToggleTask = { _ in called = true }
        coord.handleScrollMessage(name: "scribeToggleTask",
                                  body: "garbage")
        XCTAssertFalse(called)
    }

    func test_handleToggle_rejectsNonPositiveLine() {
        // Source lines are 1-based and must be > 0. Fall through
        // silently to protect the editor from a stray `0` payload.
        let coord = MarkdownPreviewPane.Coordinator()
        var called = false
        coord.onToggleTask = { _ in called = true }
        coord.handleScrollMessage(name: "scribeToggleTask",
                                  body: NSNumber(value: 0))
        coord.handleScrollMessage(name: "scribeToggleTask",
                                  body: NSNumber(value: -3))
        XCTAssertFalse(called)
        XCTAssertEqual(coord.lastToggledTaskLine, 0)
    }

    // MARK: - revealLineScript JS structure

    func test_revealLineScript_containsCheckboxClickHandler() {
        // Click handler is delegated on document so dynamically
        // injected checkboxes (post-51b incremental swap) work
        // without re-binding. Pin the load-bearing pieces.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("addEventListener('click'"),
                      "click listener missing")
        XCTAssertTrue(js.contains("input.scribe-task"),
                      "checkbox selector missing — converter and JS would diverge")
        XCTAssertTrue(js.contains("preventDefault"),
                      "without preventDefault, browser flips the DOM and we lose source-of-truth")
    }

    func test_revealLineScript_postsToToggleTaskHandler() {
        // The Swift handler is registered under
        // "scribeToggleTask"; the JS has to post to the exact
        // same name.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("webkit.messageHandlers.scribeToggleTask.postMessage"),
                      "JS must post to the scribeToggleTask handler")
    }

    func test_revealLineScript_climbsToSourceLineLi() {
        // The handler reads the source line off the closest
        // ancestor `<li[data-source-line]>` — `getAttribute` on
        // the input itself wouldn't work because the converter
        // stamps the line on the `<li>`, not the checkbox.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("closest('li[data-source-line]')"),
                      "click handler must climb to the source-line-bearing <li>")
    }

    // MARK: - MarkdownConverter output (re-pin alongside JS)

    func test_converter_emitsClickableScribeTaskClass() {
        // Companion check to the converter tests in
        // MarkdownConverterTests; pinning here too means a future
        // refactor that drops the class can't break the JS click
        // handler without also tripping a preview-side test.
        let html = MarkdownConverter.render("- [ ] todo")
        XCTAssertTrue(html.contains("class=\"scribe-task\""),
                      "checkbox must carry the scribe-task class for click delegation")
        XCTAssertFalse(html.contains("disabled"),
                      "checkbox must be interactive — disabled blocks the click event")
    }
}
