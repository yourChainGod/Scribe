//
//  DocumentFlushTests.swift
//  Phase 28c — pin the Document.flushPendingEdit drain-hook contract
//  so a future refactor can't accidentally remove the throttle escape
//  hatch that `Workspace.write` and `handleExternalChange` rely on.
//
//  We deliberately don't spin up a real ScintillaView here — that
//  would need an NSWindow + a runloop, which the unit-test target
//  doesn't have. The contract this test pins is purely about
//  `Document` storing & invoking the closure, which is what
//  `Workspace.save` exercises in production.
//

import XCTest
@testable import Scribe

@MainActor
final class DocumentFlushTests: XCTestCase {

    /// Default state: hook is nil, optional-call is a no-op.
    func test_flushHook_isNilByDefault() {
        let doc = Document(title: "untitled")
        XCTAssertNil(doc.flushPendingEdit)
        // Calling through the optional chain mustn't crash even when
        // unset. Workspace.save reaches for this on every doc and
        // some docs (placeholder during async load, freshly-created
        // untitled tabs) won't have an editor coordinator yet.
        doc.flushPendingEdit?()
    }

    /// Hook fires when invoked and can mutate the document — the
    /// canonical use case (Coordinator.flushDocSync writes
    /// `view.string()` into `doc.text`).
    func test_flushHook_runsAndCanMutateText() {
        let doc = Document(title: "untitled")
        var fireCount = 0
        doc.flushPendingEdit = {
            fireCount += 1
            doc.text = "drained"
        }

        XCTAssertEqual(doc.text, "")
        doc.flushPendingEdit?()
        XCTAssertEqual(fireCount, 1)
        XCTAssertEqual(doc.text, "drained")
    }

    /// Replacing the hook (the doc-swap path — a new Coordinator
    /// takes over the doc) keeps invocations going through the
    /// freshest closure, never the stale one.
    func test_flushHook_replacementSurvivesDocSwap() {
        let doc = Document(title: "untitled")
        var firstFires = 0
        var secondFires = 0
        doc.flushPendingEdit = { firstFires += 1 }
        doc.flushPendingEdit?()
        XCTAssertEqual(firstFires, 1)

        // Simulate a new Coordinator taking over.
        doc.flushPendingEdit = { secondFires += 1 }
        doc.flushPendingEdit?()
        XCTAssertEqual(firstFires, 1, "old hook must not fire after replacement")
        XCTAssertEqual(secondFires, 1)
    }
}
