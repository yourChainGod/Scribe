//
//  OutlineFilterTests.swift
//  Phase 50a — substring filter for the symbol outline. Pure helper
//  is unit-testable; the SwiftUI rendering path stays out of XCTest.
//

import XCTest
@testable import Scribe

@MainActor
final class OutlineFilterTests: XCTestCase {

    // MARK: - Empty / whitespace queries pass through

    func test_emptyQuery_returnsAllSymbols() {
        let symbols = makeSymbols(["alpha", "beta", "gamma"])
        XCTAssertEqual(
            OutlineSidebar.filterSymbols(symbols, by: "").map(\.name),
            ["alpha", "beta", "gamma"]
        )
    }

    func test_whitespaceOnlyQuery_returnsAllSymbols() {
        let symbols = makeSymbols(["alpha", "beta"])
        XCTAssertEqual(
            OutlineSidebar.filterSymbols(symbols, by: "   ").map(\.name),
            ["alpha", "beta"]
        )
        XCTAssertEqual(
            OutlineSidebar.filterSymbols(symbols, by: "\n\t ").map(\.name),
            ["alpha", "beta"]
        )
    }

    // MARK: - Substring matching

    func test_substringMatch_caseInsensitive() {
        let symbols = makeSymbols([
            "loadDocument",
            "saveDocument",
            "newDocument",
            "openFile"
        ])
        XCTAssertEqual(
            OutlineSidebar.filterSymbols(symbols, by: "Doc").map(\.name),
            ["loadDocument", "saveDocument", "newDocument"]
        )
        // Lowercase needle still matches the camel-cased haystack.
        XCTAssertEqual(
            OutlineSidebar.filterSymbols(symbols, by: "document").map(\.name),
            ["loadDocument", "saveDocument", "newDocument"]
        )
    }

    func test_substringMatch_partialNeedle() {
        // Substring (not prefix) — needle in the middle of the
        // identifier still matches. Callers shouldn't have to type
        // the leading characters.
        let symbols = makeSymbols(["renderRow", "OutlineRow", "TabBarRow"])
        XCTAssertEqual(
            OutlineSidebar.filterSymbols(symbols, by: "Row").map(\.name),
            ["renderRow", "OutlineRow", "TabBarRow"]
        )
        XCTAssertEqual(
            OutlineSidebar.filterSymbols(symbols, by: "Outline").map(\.name),
            ["OutlineRow"]
        )
    }

    func test_queryWithSurroundingSpaces_isTrimmedBeforeMatching() {
        // Users routinely paste with stray whitespace; trimming
        // matches what every search field on macOS already does.
        let symbols = makeSymbols(["calculate", "compile", "compare"])
        XCTAssertEqual(
            OutlineSidebar.filterSymbols(symbols, by: "  comp ").map(\.name),
            ["compile", "compare"]
        )
    }

    func test_unicodeSymbols_matchInsensitive() {
        // Chinese symbol names are common in markdown headings
        // ("# 设计 / 实现"); the filter must not silently drop them.
        let symbols = makeSymbols([
            "设计文档",
            "实现细节",
            "Implementation"
        ])
        XCTAssertEqual(
            OutlineSidebar.filterSymbols(symbols, by: "设计").map(\.name),
            ["设计文档"]
        )
        XCTAssertEqual(
            OutlineSidebar.filterSymbols(symbols, by: "imp").map(\.name),
            ["Implementation"]
        )
    }

    // MARK: - No match

    func test_noMatch_returnsEmptyList() {
        let symbols = makeSymbols(["alpha", "beta", "gamma"])
        XCTAssertTrue(
            OutlineSidebar.filterSymbols(symbols, by: "zzz").isEmpty,
            "expected empty filter result for 'zzz', got something"
        )
    }

    // MARK: - Stability

    func test_filterPreservesOriginalSymbolOrder() {
        // The outline relies on declaration order to render the
        // symbol list. The filter must never reorder; only drop.
        let symbols = makeSymbols([
            "zeta",      // first declaration
            "alpha",
            "alpha2",
            "beta"
        ])
        XCTAssertEqual(
            OutlineSidebar.filterSymbols(symbols, by: "a").map(\.name),
            ["zeta", "alpha", "alpha2", "beta"]
        )
    }

    func test_emptySymbolListReturnsEmpty() {
        XCTAssertTrue(
            OutlineSidebar.filterSymbols([], by: "anything").isEmpty
        )
        XCTAssertTrue(
            OutlineSidebar.filterSymbols([], by: "").isEmpty
        )
    }

    // MARK: - Helpers

    private func makeSymbols(_ names: [String]) -> [SymbolEntry] {
        // Line numbers don't affect the filter — keep them
        // monotonically increasing so a future order-sensitive
        // assertion has a stable secondary signal to debug from.
        names.enumerated().map { index, name in
            SymbolEntry(
                kind: .function,
                name: name,
                lineNumber: index + 1
            )
        }
    }
}
