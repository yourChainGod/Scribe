//
//  MergeConflictResolverTests.swift
//  Phase 68 — verifies Accept Current / Incoming / Both produce
//  resolutions whose range+replacement can be applied directly to
//  the document via NSString replacement and come out looking
//  exactly like a manually-resolved merge.
//

import XCTest
@testable import Scribe

final class MergeConflictResolverTests: XCTestCase {

    // MARK: - Scaffolding

    private func firstConflict(in text: String) -> MergeConflict {
        let conflicts = MergeConflictParser.parse(text)
        precondition(conflicts.count == 1,
                     "fixture must produce exactly one conflict")
        return conflicts[0]
    }

    /// Apply a resolution and return the resulting whole-document
    /// text — mirrors how the editor uses the resolver output.
    private func apply(_ resolution: MergeConflictResolution,
                       to original: String) -> String {
        let mutable = NSMutableString(string: original)
        mutable.replaceCharacters(in: resolution.range,
                                  with: resolution.replacement)
        return mutable as String
    }

    // MARK: - Happy paths

    func test_acceptCurrent_keepsOursAndStripsMarkers() {
        let src = """
        prefix
        <<<<<<< HEAD
        ours
        =======
        theirs
        >>>>>>> feature
        suffix
        """
        let r = MergeConflictResolver.resolve(firstConflict(in: src),
                                               choice: .current,
                                               in: src)
        let out = apply(r, to: src)
        XCTAssertEqual(out, "prefix\nours\nsuffix")
    }

    func test_acceptIncoming_keepsTheirsAndStripsMarkers() {
        let src = """
        prefix
        <<<<<<< HEAD
        ours
        =======
        theirs
        >>>>>>> feature
        suffix
        """
        let r = MergeConflictResolver.resolve(firstConflict(in: src),
                                               choice: .incoming,
                                               in: src)
        let out = apply(r, to: src)
        XCTAssertEqual(out, "prefix\ntheirs\nsuffix")
    }

    func test_acceptBoth_concatenatesCurrentThenIncoming() {
        // Swift multi-line literals omit a trailing newline, so
        // the conflict sits at EOF with no final `\n`. Resolution
        // preserves that — both-sides join with a single `\n` in
        // between, no trailer.
        let src = """
        <<<<<<< HEAD
        ours
        =======
        theirs
        >>>>>>> feature
        """
        let r = MergeConflictResolver.resolve(firstConflict(in: src),
                                               choice: .both,
                                               in: src)
        let out = apply(r, to: src)
        XCTAssertEqual(out, "ours\ntheirs")
    }

    // MARK: - Multi-line bodies

    func test_multiLineBodies_surviveAcceptBoth() {
        let src = """
        prefix
        <<<<<<< HEAD
        A1
        A2
        =======
        B1
        B2
        >>>>>>> feature
        suffix
        """
        let r = MergeConflictResolver.resolve(firstConflict(in: src),
                                               choice: .both,
                                               in: src)
        let out = apply(r, to: src)
        XCTAssertEqual(out, "prefix\nA1\nA2\nB1\nB2\nsuffix")
    }

    // MARK: - Empty sides

    func test_emptyCurrent_acceptIncomingLeavesOnlyTheirs() {
        let src = """
        prefix
        <<<<<<< HEAD
        =======
        added
        >>>>>>> feature
        suffix
        """
        let r = MergeConflictResolver.resolve(firstConflict(in: src),
                                               choice: .incoming,
                                               in: src)
        XCTAssertEqual(apply(r, to: src), "prefix\nadded\nsuffix")
    }

    func test_emptyIncoming_acceptCurrentLeavesOnlyOurs() {
        let src = """
        prefix
        <<<<<<< HEAD
        kept
        =======
        >>>>>>> feature
        suffix
        """
        let r = MergeConflictResolver.resolve(firstConflict(in: src),
                                               choice: .current,
                                               in: src)
        XCTAssertEqual(apply(r, to: src), "prefix\nkept\nsuffix")
    }

    func test_bothSidesEmpty_acceptCurrentDropsEntireBlock() {
        let src = """
        prefix
        <<<<<<< HEAD
        =======
        >>>>>>> feature
        suffix
        """
        let r = MergeConflictResolver.resolve(firstConflict(in: src),
                                               choice: .current,
                                               in: src)
        // Both sides empty, Accept Current drops the block entirely.
        XCTAssertEqual(apply(r, to: src), "prefix\nsuffix")
    }

    func test_acceptBoth_withOneEmptySide_keepsTheOther() {
        let src = """
        prefix
        <<<<<<< HEAD
        ours only
        =======
        >>>>>>> feature
        suffix
        """
        let r = MergeConflictResolver.resolve(firstConflict(in: src),
                                               choice: .both,
                                               in: src)
        XCTAssertEqual(apply(r, to: src), "prefix\nours only\nsuffix")
    }

    // MARK: - EOF handling

    func test_conflictAtEOF_withoutTrailingNewline_preservesEOF() {
        // The closing `>>>>>>>` sits at the very end with no
        // trailing newline. Resolution must NOT add one.
        let src = "prefix\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature"
        let r = MergeConflictResolver.resolve(firstConflict(in: src),
                                               choice: .current,
                                               in: src)
        let out = apply(r, to: src)
        XCTAssertEqual(out, "prefix\nours")
        XCTAssertFalse(out.hasSuffix("\n"),
                       "must preserve the file's no-trailing-newline state")
    }

    func test_conflictInMiddle_keepsTrailingNewline() {
        // Conflict is followed by a real line, so resolution must
        // end with a newline to keep "ours\n" and "suffix\n"
        // separate.
        let src = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nsuffix\n"
        let r = MergeConflictResolver.resolve(firstConflict(in: src),
                                               choice: .current,
                                               in: src)
        let out = apply(r, to: src)
        XCTAssertEqual(out, "ours\nsuffix\n")
    }

    // MARK: - Range atomicity

    func test_resolution_rangeMatchesConflictRange_exactly() {
        let src = """
        <<<<<<< HEAD
        ours
        =======
        theirs
        >>>>>>> feature
        """
        let conflict = firstConflict(in: src)
        let r = MergeConflictResolver.resolve(conflict,
                                               choice: .current,
                                               in: src)
        XCTAssertEqual(r.range, conflict.range,
                       "resolution must target exactly the conflict block so "
                       + "editor undo / caret tracking stays sane")
    }
}
