//
//  FoldPresentationTests.swift
//  Phase 82 — code folding. The only fold logic that runs without a
//  live ScintillaView is the lexer→margin-width gate. Everything else
//  (marker glyphs, fold-level walking, FOLDLINE / FOLDALL dispatch) is
//  Scintilla message-passing that needs a real NSView the XCTest
//  bundle can't stand up headlessly — the view segfaults in `dealloc`
//  under `swift test` (confirmed across Phases 47+). So we pin the one
//  pure seam: empty lexer ⇒ no strip, any real lexer ⇒ a 14 px strip.
//  The visual behaviour (markers, click-to-fold, ⌥⌘[ / ⌥⌘], theme
//  recolour) is covered by the runtime screenshot QA pass.
//

import XCTest
@testable import Scribe

@MainActor
final class FoldPresentationTests: XCTestCase {

    // MARK: - foldMarginWidth gate

    func test_foldMarginWidth_emptyLexer_isZero() {
        // Plain text (the null lexer) emits no fold levels, so the
        // strip must collapse to 0 — otherwise plain .txt buffers
        // would carry a dead empty column next to the line numbers.
        XCTAssertEqual(
            ScintillaCodeEditor.Coordinator.foldMarginWidth(forLexillaName: ""),
            0)
    }

    func test_foldMarginWidth_realLexers_areFixedWidth() {
        // Every real lexer gets the same 14 px strip — the width
        // doesn't vary per language, only present-vs-absent does.
        for name in ["cpp", "python", "json", "bash", "xml", "markdown"] {
            XCTAssertEqual(
                ScintillaCodeEditor.Coordinator.foldMarginWidth(forLexillaName: name),
                14,
                "lexer \(name) should get the standard fold strip width")
        }
    }

    func test_foldMarginWidth_isBinary_presentOrAbsent() {
        // The gate is strictly empty ⇄ non-empty; there is no third
        // width. Guards against a future refactor sneaking in a
        // per-language width that would break the "blends seamlessly
        // with the line-number margin" assumption.
        let widths = Set(["", "cpp", "swift", "x"].map {
            ScintillaCodeEditor.Coordinator.foldMarginWidth(forLexillaName: $0)
        })
        XCTAssertEqual(widths, [0, 14])
    }
}
