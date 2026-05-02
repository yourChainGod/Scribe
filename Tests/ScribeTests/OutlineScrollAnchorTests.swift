//
//  OutlineScrollAnchorTests.swift
//  Phase 50c — auto-reveal active symbol in the outline sidebar.
//  The SwiftUI scroll side-effect isn't easily unit-tested, but the
//  anchor selection rule is a pure function — lock it down so a
//  future refactor can't silently swap .top/.center/.bottom.
//

import SwiftUI
import XCTest
@testable import Scribe

@MainActor
final class OutlineScrollAnchorTests: XCTestCase {

    // MARK: - Edge-row pinning

    func test_firstSymbolAnchors_top() {
        let symbols = makeSymbols(["a", "b", "c"])
        XCTAssertEqual(
            OutlineSidebar.scrollAnchor(forActive: symbols[0].id, in: symbols),
            .top,
            "first symbol must anchor to the top edge so it doesn't scroll past the header"
        )
    }

    func test_lastSymbolAnchors_bottom() {
        let symbols = makeSymbols(["a", "b", "c"])
        XCTAssertEqual(
            OutlineSidebar.scrollAnchor(forActive: symbols.last!.id, in: symbols),
            .bottom,
            "last symbol must anchor to the bottom edge so it doesn't stick halfway up"
        )
    }

    // MARK: - Middle symbols centre

    func test_middleSymbolAnchors_center() {
        let symbols = makeSymbols(["a", "b", "c", "d", "e"])
        for idx in 1..<(symbols.count - 1) {
            XCTAssertEqual(
                OutlineSidebar.scrollAnchor(forActive: symbols[idx].id, in: symbols),
                .center,
                "symbol at index \(idx) should centre; edges should win only for first/last"
            )
        }
    }

    // MARK: - Degenerate lists

    func test_singleSymbolAnchors_top() {
        // The only symbol is both the first and the last — first
        // check wins so the .top branch lands, which keeps the
        // header in view alongside the highlight.
        let symbols = makeSymbols(["solo"])
        XCTAssertEqual(
            OutlineSidebar.scrollAnchor(forActive: symbols[0].id, in: symbols),
            .top
        )
    }

    func test_twoSymbols_anchorTopThenBottom() {
        let symbols = makeSymbols(["first", "second"])
        XCTAssertEqual(
            OutlineSidebar.scrollAnchor(forActive: symbols[0].id, in: symbols),
            .top
        )
        XCTAssertEqual(
            OutlineSidebar.scrollAnchor(forActive: symbols[1].id, in: symbols),
            .bottom
        )
    }

    // MARK: - Unknown id

    func test_unknownSymbolAnchors_center_asSafeFallback() {
        // The active id can lag the outline model by one frame (e.g.
        // parse just finished, new symbols pushed; caret still on
        // an id that was dropped). `.center` is a sensible default
        // that SwiftUI will silently no-op on anyway — we just want
        // a non-nil anchor so the call site doesn't branch.
        let symbols = makeSymbols(["a", "b", "c"])
        let stranger = UUID()
        XCTAssertEqual(
            OutlineSidebar.scrollAnchor(forActive: stranger, in: symbols),
            .center
        )
    }

    func test_emptySymbolsFallsBackTo_center() {
        let stranger = UUID()
        XCTAssertEqual(
            OutlineSidebar.scrollAnchor(forActive: stranger, in: []),
            .center
        )
    }

    // MARK: - Helpers

    private func makeSymbols(_ names: [String]) -> [SymbolEntry] {
        names.enumerated().map { index, name in
            SymbolEntry(
                kind: .function,
                name: name,
                lineNumber: index + 1
            )
        }
    }
}
