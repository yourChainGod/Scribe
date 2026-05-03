//
//  SnippetSessionTests.swift
//  Phase 63 — locks down `SnippetSession`'s offset arithmetic so the
//  Coordinator can rely on:
//    1. `make(parsed:insertedAt:)` translates UTF-16 stop ranges
//       into UTF-8 byte ranges, including non-ASCII default text.
//    2. Inserting before / inside / after a stop shifts boundaries
//       with the documented asymmetry (insert at start keeps start;
//       insert at end extends end).
//    3. Delete cases (before / overlapping / after) collapse into
//       the right ranges without producing negative widths.
//    4. `advance` / `retreat` step through the visit order without
//       overrunning ends.
//    5. A snippet with only the synthetic `$0` returns no session.
//

import XCTest
@testable import Scribe

final class SnippetSessionTests: XCTestCase {

    // MARK: - Construction

    func test_make_returnsNilForBodyWithoutPlaceholders() {
        let parsed = SnippetParser.parse("plain text")
        XCTAssertNil(SnippetSession.make(parsed: parsed, insertedAt: 0))
    }

    func test_make_translatesUtf16OffsetsToBytes_ascii() {
        let parsed = SnippetParser.parse("call(${1:arg})")
        // plainText is "call(arg)" — pure ASCII, so UTF-16 == UTF-8.
        let session = SnippetSession.make(parsed: parsed, insertedAt: 100)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.stops.first?.start, 105)
        XCTAssertEqual(session?.stops.first?.end, 108)
        XCTAssertEqual(session?.stops.last?.index, 0)
        // Synthetic $0 lives at the end of "call(arg)" — 9 bytes
        // past the insertion point.
        XCTAssertEqual(session?.stops.last?.start, 109)
        XCTAssertEqual(session?.stops.last?.end, 109)
    }

    func test_make_translatesUtf16OffsetsToBytes_chinese() {
        // "中" is 1 UTF-16 unit + 3 UTF-8 bytes. The default text
        // "中文" is 2 UTF-16 / 6 bytes; the prefix "[" is 1/1.
        let parsed = SnippetParser.parse("[${1:中文}]")
        let session = SnippetSession.make(parsed: parsed, insertedAt: 0)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.stops.first?.start, 1)
        XCTAssertEqual(session?.stops.first?.end, 1 + 6)   // 6 UTF-8 bytes
        // Trailing $0 sits after "中文]" → 1 + 6 + 1 = 8 bytes.
        XCTAssertEqual(session?.stops.last?.start, 8)
    }

    func test_make_initialIndexIsFirstStop() {
        let parsed = SnippetParser.parse("$2 $1")
        let session = SnippetSession.make(parsed: parsed, insertedAt: 0)
        XCTAssertEqual(session?.currentIndex, 0)
        XCTAssertEqual(session?.current.index, 1)
        XCTAssertEqual(session?.isOnTerminalStop, false)
    }

    // MARK: - Insertions

    func test_insert_beforeStop_shiftsBoth() {
        var session = SnippetSession(stops: [
            .init(index: 1, start: 10, end: 13)
        ], currentIndex: 0)
        session.apply(modificationAt: 5, length: 3)
        XCTAssertEqual(session.stops[0].start, 13)
        XCTAssertEqual(session.stops[0].end, 16)
    }

    func test_insert_atStartOfStop_keepsStartExtendsEnd() {
        var session = SnippetSession(stops: [
            .init(index: 1, start: 10, end: 13)
        ], currentIndex: 0)
        session.apply(modificationAt: 10, length: 2)
        XCTAssertEqual(session.stops[0].start, 10)
        XCTAssertEqual(session.stops[0].end, 15)
    }

    func test_insert_insideStop_extendsEndOnly() {
        var session = SnippetSession(stops: [
            .init(index: 1, start: 10, end: 13)
        ], currentIndex: 0)
        session.apply(modificationAt: 11, length: 4)
        XCTAssertEqual(session.stops[0].start, 10)
        XCTAssertEqual(session.stops[0].end, 17)
    }

    func test_insert_atEndOfStop_extendsEnd() {
        var session = SnippetSession(stops: [
            .init(index: 1, start: 10, end: 13)
        ], currentIndex: 0)
        session.apply(modificationAt: 13, length: 2)
        XCTAssertEqual(session.stops[0].start, 10)
        XCTAssertEqual(session.stops[0].end, 15)
    }

    func test_insert_afterStop_unchanged() {
        var session = SnippetSession(stops: [
            .init(index: 1, start: 10, end: 13)
        ], currentIndex: 0)
        session.apply(modificationAt: 20, length: 5)
        XCTAssertEqual(session.stops[0].start, 10)
        XCTAssertEqual(session.stops[0].end, 13)
    }

    func test_insert_zeroWidthStop_atItsPosition_grows() {
        // Empty `${1}` placeholder. Typing one byte should make
        // the stop carry that byte.
        var session = SnippetSession(stops: [
            .init(index: 1, start: 5, end: 5)
        ], currentIndex: 0)
        session.apply(modificationAt: 5, length: 1)
        XCTAssertEqual(session.stops[0].start, 5)
        XCTAssertEqual(session.stops[0].end, 6)
    }

    func test_insert_betweenTwoStops_shiftsLaterOnly() {
        var session = SnippetSession(stops: [
            .init(index: 1, start: 5, end: 8),
            .init(index: 2, start: 20, end: 25),
        ], currentIndex: 0)
        session.apply(modificationAt: 12, length: 3)
        XCTAssertEqual(session.stops[0].start, 5)
        XCTAssertEqual(session.stops[0].end, 8)
        XCTAssertEqual(session.stops[1].start, 23)
        XCTAssertEqual(session.stops[1].end, 28)
    }

    // MARK: - Deletions

    func test_delete_beforeStop_shiftsLeft() {
        var session = SnippetSession(stops: [
            .init(index: 1, start: 10, end: 13)
        ], currentIndex: 0)
        session.apply(modificationAt: 4, length: -3)
        XCTAssertEqual(session.stops[0].start, 7)
        XCTAssertEqual(session.stops[0].end, 10)
    }

    func test_delete_afterStop_unchanged() {
        var session = SnippetSession(stops: [
            .init(index: 1, start: 10, end: 13)
        ], currentIndex: 0)
        session.apply(modificationAt: 20, length: -5)
        XCTAssertEqual(session.stops[0].start, 10)
        XCTAssertEqual(session.stops[0].end, 13)
    }

    func test_delete_overlapsStartOfStop_collapsesStart() {
        // Delete bytes [8, 12) — overlaps stop's start (10).
        var session = SnippetSession(stops: [
            .init(index: 1, start: 10, end: 15)
        ], currentIndex: 0)
        session.apply(modificationAt: 8, length: -4)
        // Boundaries inside [8, 12): start (10) collapses to 8.
        // Boundaries past delEnd (12): end (15) shifts left by 4 → 11.
        XCTAssertEqual(session.stops[0].start, 8)
        XCTAssertEqual(session.stops[0].end, 11)
    }

    func test_delete_overlapsEndOfStop_collapsesEnd() {
        // Delete bytes [13, 17) — overlaps stop's end (15).
        var session = SnippetSession(stops: [
            .init(index: 1, start: 10, end: 15)
        ], currentIndex: 0)
        session.apply(modificationAt: 13, length: -4)
        // start (10) is before delStart → unchanged.
        // end (15) is inside [13, 17) → collapses to 13.
        XCTAssertEqual(session.stops[0].start, 10)
        XCTAssertEqual(session.stops[0].end, 13)
    }

    func test_delete_swallowsStop_collapsesToZeroWidth() {
        // Delete bytes [8, 18) — fully covers the stop [10, 15).
        var session = SnippetSession(stops: [
            .init(index: 1, start: 10, end: 15)
        ], currentIndex: 0)
        session.apply(modificationAt: 8, length: -10)
        // Both boundaries collapse to delStart (8).
        XCTAssertEqual(session.stops[0].start, 8)
        XCTAssertEqual(session.stops[0].end, 8)
    }

    func test_delete_inMiddleOfStop_shrinksStop() {
        // Delete bytes [11, 13) — fully inside stop [10, 15).
        var session = SnippetSession(stops: [
            .init(index: 1, start: 10, end: 15)
        ], currentIndex: 0)
        session.apply(modificationAt: 11, length: -2)
        XCTAssertEqual(session.stops[0].start, 10)
        XCTAssertEqual(session.stops[0].end, 13)
    }

    // MARK: - Navigation

    func test_advance_walksVisitOrder() {
        var session = SnippetSession(stops: [
            .init(index: 1, start: 0, end: 0),
            .init(index: 2, start: 1, end: 1),
            .init(index: 0, start: 2, end: 2),
        ], currentIndex: 0)
        XCTAssertTrue(session.advance())
        XCTAssertEqual(session.current.index, 2)
        XCTAssertTrue(session.advance())
        XCTAssertEqual(session.current.index, 0)
        XCTAssertTrue(session.isOnTerminalStop)
        XCTAssertFalse(session.advance(), "advancing past $0 should fail")
        XCTAssertEqual(session.current.index, 0,
                       "failed advance must not bump currentIndex")
    }

    func test_retreat_walksBackwardsButStopsAtFirst() {
        var session = SnippetSession(stops: [
            .init(index: 1, start: 0, end: 0),
            .init(index: 2, start: 1, end: 1),
        ], currentIndex: 1)
        XCTAssertTrue(session.retreat())
        XCTAssertEqual(session.current.index, 1)
        XCTAssertFalse(session.retreat(), "retreating past stop 0 must fail")
    }

    // MARK: - End-to-end flow

    func test_endToEnd_callSnippet_typingReplacesPlaceholder() {
        // Body "call(${1:arg})" inserted at byte 0 of an empty buffer.
        let parsed = SnippetParser.parse("call(${1:arg})")
        guard var session = SnippetSession.make(parsed: parsed,
                                                insertedAt: 0) else {
            XCTFail("expected non-nil session"); return
        }
        // First stop covers "arg" → bytes [5, 8).
        XCTAssertEqual(session.current.start, 5)
        XCTAssertEqual(session.current.end, 8)

        // User selects the placeholder and types "x" — Scintilla
        // emits a delete of [5, 8) followed by an insert of 1 byte
        // at 5.
        session.apply(modificationAt: 5, length: -3)
        // After the delete the stop is [5, 5).
        XCTAssertEqual(session.current.end, 5)
        session.apply(modificationAt: 5, length: 1)
        XCTAssertEqual(session.current.start, 5)
        XCTAssertEqual(session.current.end, 6, "typing must extend the stop")

        // Second stop is the synthetic $0 — its start should have
        // shifted from 9 → 7 (delete -3, then insert +1).
        XCTAssertEqual(session.stops.last?.start, 7)

        // Tab to $0 ends the navigable portion of the session.
        XCTAssertTrue(session.advance())
        XCTAssertTrue(session.isOnTerminalStop)
        XCTAssertFalse(session.advance())
    }
}
