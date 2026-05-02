//
//  OutlineFilterClearOnDocSwitchTests.swift
//  Bug 3 regression coverage. The pre-fix behaviour explicitly kept
//  the outline filter across document switches; users reported this
//  as confusing because a stale "load" query would carry over to
//  a doc that didn't have any "load*" symbols and the sidebar would
//  look empty for no apparent reason. The fix scopes the filter to
//  the current doc by clearing on a true A→B switch — but NOT on
//  first-render (no doc was previously bound) and NOT on doc-closed
//  (current doc just went away).
//
//  The view-side `.onChange` is a one-line call into
//  `OutlineSidebar.shouldClearFilter(currentDocID:lastDocID:)`, so
//  this suite asserts the helper's contract directly and lets
//  XCTest stay out of SwiftUI internals.
//

import XCTest
@testable import Scribe

@MainActor
final class OutlineFilterClearOnDocSwitchTests: XCTestCase {

    // MARK: - True A→B switches: clear

    func test_switchFromOneDocToAnother_clears() {
        let docA = UUID()
        let docB = UUID()
        XCTAssertTrue(
            OutlineSidebar.shouldClearFilter(currentDocID: docB, lastDocID: docA),
            "moving from doc A to a different doc B must clear the filter"
        )
    }

    func test_switchBackToOriginalAfterDetour_clears() {
        // A → B → A still requires clearing on the second hop because
        // the user's filter was tied to whatever doc they typed it
        // against; coming back to A is a fresh tab event from the
        // sidebar's perspective.
        let docA = UUID()
        XCTAssertTrue(
            OutlineSidebar.shouldClearFilter(currentDocID: docA, lastDocID: UUID()),
            "returning to doc A after visiting doc B must still clear"
        )
    }

    // MARK: - Same id: preserve (re-render)

    func test_sameDocID_doesNotClear() {
        // SwiftUI re-runs `.onChange` callbacks on body recomposition
        // for reasons unrelated to the user — we MUST NOT wipe the
        // query just because the same doc came through again.
        let doc = UUID()
        XCTAssertFalse(
            OutlineSidebar.shouldClearFilter(currentDocID: doc, lastDocID: doc),
            "same doc id (re-render) must preserve the filter"
        )
    }

    // MARK: - First binding: preserve

    func test_firstBinding_doesNotClear() {
        // Sidebar mounts with no prior doc; if the user has typed a
        // filter into the field while the placeholder was up (edge
        // case but not impossible), don't drop it the moment a doc
        // gets selected. lastDocID == nil ⇒ no "switch" happened.
        XCTAssertFalse(
            OutlineSidebar.shouldClearFilter(currentDocID: UUID(), lastDocID: nil),
            "first time we see a doc id is a binding event, not a switch"
        )
    }

    // MARK: - Doc closed: preserve

    func test_currentBecomesNil_doesNotClear() {
        // Last doc closed; we don't render a filter row in the
        // no-doc placeholder anyway, but we shouldn't lose the
        // user's text either — they may reopen the same doc and
        // expect the field to still hold their query.
        XCTAssertFalse(
            OutlineSidebar.shouldClearFilter(currentDocID: nil, lastDocID: UUID()),
            "doc closing (current goes nil) must not wipe the filter"
        )
    }

    func test_bothNil_doesNotClear() {
        // Idempotent no-op edge case.
        XCTAssertFalse(
            OutlineSidebar.shouldClearFilter(currentDocID: nil, lastDocID: nil)
        )
    }
}
