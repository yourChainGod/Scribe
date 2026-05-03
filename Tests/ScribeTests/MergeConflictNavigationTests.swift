//
//  MergeConflictNavigationTests.swift
//  Phase 68b — exercise the next / previous helpers the Tools
//  menu and command palette dispatch through. The Coordinator's
//  beep / move-caret wrapping is trivial; what matters is the
//  pure navigation rule and its wrap-around edge cases.
//

import XCTest
@testable import Scribe

final class MergeConflictNavigationTests: XCTestCase {

    /// Build a stub conflict whose only navigation-relevant field
    /// is `startLine`. The other fields (range / labels / texts)
    /// don't enter the navigation logic so we feed dummies.
    private func stub(startLine: Int) -> MergeConflict {
        MergeConflict(
            id: UUID(),
            range: NSRange(location: 0, length: 0),
            startLine: startLine,
            endLine: startLine,
            currentText: "",
            incomingText: "",
            baseText: nil,
            currentLabel: "",
            incomingLabel: "",
            baseLabel: nil)
    }

    // MARK: - next(after:in:)

    func test_next_emptyArray_isNil() {
        XCTAssertNil(MergeConflictNavigation.next(after: 1, in: []))
    }

    func test_next_caretBeforeAll_returnsFirst() {
        let cs = [stub(startLine: 5), stub(startLine: 12), stub(startLine: 30)]
        XCTAssertEqual(MergeConflictNavigation.next(after: 1, in: cs), 5)
    }

    func test_next_caretBetweenBlocks_returnsFollowing() {
        let cs = [stub(startLine: 5), stub(startLine: 12), stub(startLine: 30)]
        // Caret at line 8 → next conflict is line 12.
        XCTAssertEqual(MergeConflictNavigation.next(after: 8, in: cs), 12)
    }

    func test_next_caretOnConflictLine_jumpsToFollowingNotItself() {
        let cs = [stub(startLine: 5), stub(startLine: 12), stub(startLine: 30)]
        // Mashing Next on a conflict's first line must walk forward,
        // not loop back to the same block. This is the strict-
        // inequality contract the docstring guarantees.
        XCTAssertEqual(MergeConflictNavigation.next(after: 5, in: cs), 12)
    }

    func test_next_caretPastLast_wrapsToFirst() {
        let cs = [stub(startLine: 5), stub(startLine: 12), stub(startLine: 30)]
        XCTAssertEqual(MergeConflictNavigation.next(after: 100, in: cs), 5)
    }

    // MARK: - previous(before:in:)

    func test_previous_emptyArray_isNil() {
        XCTAssertNil(MergeConflictNavigation.previous(before: 1, in: []))
    }

    func test_previous_caretAfterAll_returnsLast() {
        let cs = [stub(startLine: 5), stub(startLine: 12), stub(startLine: 30)]
        XCTAssertEqual(MergeConflictNavigation.previous(before: 100, in: cs), 30)
    }

    func test_previous_caretBetweenBlocks_returnsPreceding() {
        let cs = [stub(startLine: 5), stub(startLine: 12), stub(startLine: 30)]
        // Caret at line 20 → previous conflict is line 12.
        XCTAssertEqual(MergeConflictNavigation.previous(before: 20, in: cs), 12)
    }

    func test_previous_caretOnConflictLine_jumpsToPrecedingNotItself() {
        let cs = [stub(startLine: 5), stub(startLine: 12), stub(startLine: 30)]
        // Symmetric to the next() strict-inequality test.
        XCTAssertEqual(MergeConflictNavigation.previous(before: 12, in: cs), 5)
    }

    func test_previous_caretBeforeFirst_wrapsToLast() {
        let cs = [stub(startLine: 5), stub(startLine: 12), stub(startLine: 30)]
        XCTAssertEqual(MergeConflictNavigation.previous(before: 1, in: cs), 30)
    }

    // MARK: - Single-conflict files

    func test_singleConflict_next_alwaysReturnsThatBlock() {
        let cs = [stub(startLine: 7)]
        XCTAssertEqual(MergeConflictNavigation.next(after: 1, in: cs), 7)
        XCTAssertEqual(MergeConflictNavigation.next(after: 7, in: cs), 7)
        XCTAssertEqual(MergeConflictNavigation.next(after: 99, in: cs), 7)
    }

    func test_singleConflict_previous_alwaysReturnsThatBlock() {
        let cs = [stub(startLine: 7)]
        XCTAssertEqual(MergeConflictNavigation.previous(before: 1, in: cs), 7)
        XCTAssertEqual(MergeConflictNavigation.previous(before: 7, in: cs), 7)
        XCTAssertEqual(MergeConflictNavigation.previous(before: 99, in: cs), 7)
    }
}
