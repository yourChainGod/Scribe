//
//  MarkdownPreviewScrollSyncTests.swift
//  Phase 52b — editor scroll → preview follow. The wiring has four
//  moving parts:
//
//    1. `Document.viewportTopLine` — published by the editor, read
//       by the preview.
//    2. `MarkdownPreviewPane.viewportLine` — the input plumbed
//       through from the document.
//    3. `MarkdownPreviewPane.decideReveal` — the pure predicate that
//       picks between `viewport` / `cursor` / `none`.
//    4. The JS side `scribeRevealLine` (already covered by
//       `MarkdownPreviewTOCTests`).
//
//  These tests lock in (1), (2) and (3). The JS round-trip can only
//  be exercised with a live WKWebView, which is flaky inside XCTest
//  and not worth the infrastructure cost given that the Swift-side
//  decision is the one that determines when a reveal fires.
//

import XCTest
@testable import Scribe

@MainActor
final class MarkdownPreviewScrollSyncTests: XCTestCase {

    // MARK: - Document.viewportTopLine

    func test_document_viewportTopLineDefaultsToOne() {
        // A fresh document opens on its first line; the preview's
        // scroll-sync code treats that as "no scroll has happened
        // yet" so the reveal fast path stays dormant until the
        // editor actually fires its first V_SCROLL.
        let doc = Document(title: "t")
        XCTAssertEqual(doc.viewport.viewportTopLine, 1)
    }

    func test_document_viewportTopLineIsPublished() {
        // @Published so SwiftUI re-evaluates the preview's body
        // whenever the editor publishes a new top line. Without the
        // publisher the scroll-sync signal would silently die at
        // the Document/View boundary.
        let doc = Document(title: "t")
        var tickCount = 0
        let cancellable = doc.viewport.$viewportTopLine.sink { _ in tickCount += 1 }
        doc.viewport.viewportTopLine = 42
        // Combine delivers the initial value + the new one.
        XCTAssertEqual(tickCount, 2)
        cancellable.cancel()
    }

    // MARK: - decideReveal — neither signal moved

    func test_decideReveal_noChangeReturnsNone() {
        let r = MarkdownPreviewPane.decideReveal(cursorLine: 5,
                                                 viewportLine: 5,
                                                 lastCursor: 5,
                                                 lastViewport: 5)
        XCTAssertEqual(r, .none)
    }

    func test_decideReveal_bothNilReturnsNone() {
        // Scratch / preview-only callers that aren't plugged into a
        // Document pass nil for both signals. The fast path must
        // be a no-op in that case.
        let r = MarkdownPreviewPane.decideReveal(cursorLine: nil,
                                                 viewportLine: nil,
                                                 lastCursor: -1,
                                                 lastViewport: -1)
        XCTAssertEqual(r, .none)
    }

    // MARK: - decideReveal — caret-only move

    func test_decideReveal_cursorMoveWithoutViewportChange() {
        // Typing inside the visible viewport only moves the caret.
        // The preview should follow the caret to the new block.
        let r = MarkdownPreviewPane.decideReveal(cursorLine: 10,
                                                 viewportLine: 1,
                                                 lastCursor: 5,
                                                 lastViewport: 1)
        XCTAssertEqual(r, .cursor(10))
    }

    func test_decideReveal_cursorMoveWithNilViewport() {
        // Non-document preview (no Document wiring) — cursor is the
        // only signal. Still drives a reveal.
        let r = MarkdownPreviewPane.decideReveal(cursorLine: 7,
                                                 viewportLine: nil,
                                                 lastCursor: 3,
                                                 lastViewport: -1)
        XCTAssertEqual(r, .cursor(7))
    }

    // MARK: - decideReveal — scroll-only move

    func test_decideReveal_viewportMoveWithoutCursorChange() {
        // The user drags the editor's scroll thumb without moving the
        // caret. The preview should follow the viewport top.
        let r = MarkdownPreviewPane.decideReveal(cursorLine: 5,
                                                 viewportLine: 40,
                                                 lastCursor: 5,
                                                 lastViewport: 1)
        XCTAssertEqual(r, .viewport(40))
    }

    func test_decideReveal_viewportMoveWithNilCursor() {
        let r = MarkdownPreviewPane.decideReveal(cursorLine: nil,
                                                 viewportLine: 25,
                                                 lastCursor: -1,
                                                 lastViewport: 1)
        XCTAssertEqual(r, .viewport(25))
    }

    // MARK: - decideReveal — priority ordering

    func test_decideReveal_viewportBeatsCursorWhenBothMoved() {
        // Tick where the editor reports both signals changed — e.g.
        // the user dragged the scroll thumb, which auto-moves the
        // caret too (SCROLLCARET). We want the preview to land on
        // the viewport intent, not the incidental caret tag-along.
        let r = MarkdownPreviewPane.decideReveal(cursorLine: 30,
                                                 viewportLine: 60,
                                                 lastCursor: 5,
                                                 lastViewport: 1)
        XCTAssertEqual(r, .viewport(60),
                       "viewport scroll must win when both moved")
    }

    // MARK: - decideReveal — same line, different signal

    func test_decideReveal_viewportUnchangedValueIsNotReFired() {
        // Steady state: V_SCROLL bit fires on every tick Scintilla
        // touches the viewport, even when the top line is already
        // what it was. decideReveal must short-circuit on that so
        // we don't spam scribeRevealLine.
        let r = MarkdownPreviewPane.decideReveal(cursorLine: 5,
                                                 viewportLine: 20,
                                                 lastCursor: 5,
                                                 lastViewport: 20)
        XCTAssertEqual(r, .none)
    }

    func test_decideReveal_cursorUnchangedValueIsNotReFired() {
        let r = MarkdownPreviewPane.decideReveal(cursorLine: 8,
                                                 viewportLine: nil,
                                                 lastCursor: 8,
                                                 lastViewport: -1)
        XCTAssertEqual(r, .none)
    }

    // MARK: - decideReveal — cold-start semantics

    func test_decideReveal_coldStartFiresOnFirstCursorSignal() {
        // Fresh Coordinator — both `last*` are -1. The very first
        // tick where Document publishes a real cursor line should
        // trigger a reveal so the preview lands on the user's
        // starting position instead of showing the first paragraph.
        let r = MarkdownPreviewPane.decideReveal(cursorLine: 1,
                                                 viewportLine: 1,
                                                 lastCursor: -1,
                                                 lastViewport: -1)
        // Viewport beats cursor, both "moved" from -1.
        XCTAssertEqual(r, .viewport(1))
    }
}
