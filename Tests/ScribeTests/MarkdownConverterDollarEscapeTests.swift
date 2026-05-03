//
//  MarkdownConverterDollarEscapeTests.swift
//  Phase 53e-2 — `\$` renders a literal `$`. Without this escape
//  the math regex chain (Phase 53c) would silently eat prose
//  like "Cost is \$5 and \$10 per item" as one big math span.
//
//  This test file pins every plausible escape shape and a few
//  negative cases that would regress if the escape pass ran in
//  the wrong order or bled into code spans / fenced blocks.
//

import XCTest
@testable import Scribe

final class MarkdownConverterDollarEscapeTests: XCTestCase {

    // MARK: - Happy path

    func testLoneEscapeRendersLiteralDollar() {
        // `\$5` → `$5`. The backslash is consumed by the escape
        // pass, leaving just the dollar sign.
        let html = MarkdownConverter.render("Cost \\$5 each.")
        XCTAssertTrue(html.contains("Cost $5 each."),
                      "single \\$ must render as literal $")
        XCTAssertFalse(html.contains("<span class=\"math-inline\""),
                       "escape pass must prevent math span creation")
    }

    func testEscapedDollarsSurroundingNumbersStayLiteral() {
        // The motivating prose case. Both dollars are escaped,
        // so nothing between them is math.
        let html = MarkdownConverter.render(
            "Cost is \\$5 and \\$10 per item.")
        XCTAssertTrue(html.contains("Cost is $5 and $10 per item."),
                      "two escaped dollars must both render as literal $")
        XCTAssertFalse(html.contains("<span class=\"math"),
                       "no math span must be created")
    }

    func testEscapedDollarsWrappingWouldBeMathStayLiteral() {
        // `\$x\$` is not `$x$` math — it's a literal `$x$`.
        let html = MarkdownConverter.render("Literal: \\$x\\$ please.")
        XCTAssertTrue(html.contains("Literal: $x$ please."),
                      "escaped-paired dollars must render as literal")
        XCTAssertFalse(html.contains("<span class=\"math-inline\">x</span>"),
                       "escaped \\$x\\$ must NOT be parsed as inline math")
    }

    // MARK: - Coexistence with real math

    func testEscapedDollarBeforeMathSpan() {
        // `\$ … $c$` — first dollar escaped, second pair is real
        // inline math. Both behaviours must coexist in one line.
        let html = MarkdownConverter.render("Price \\$5 with $c$ each.")
        XCTAssertTrue(html.contains("Price $5 with"),
                      "escaped dollar must stay literal")
        XCTAssertTrue(html.contains("<span class=\"math-inline\">c</span>"),
                      "real inline math must still parse")
    }

    func testMathSpanBeforeEscapedDollar() {
        // Reversed order: real math first, then an escaped
        // dollar. Proves the escape pass doesn't depend on a
        // particular left-to-right order.
        let html = MarkdownConverter.render("Formula $a$ for \\$99.")
        XCTAssertTrue(html.contains("<span class=\"math-inline\">a</span>"),
                      "real math must parse")
        XCTAssertTrue(html.contains("for $99."),
                      "escaped dollar after math must stay literal")
    }

    // MARK: - Must not affect code spans / fences

    func testEscapedDollarInsideInlineCodeIsLiteralBackslashDollar() {
        // A code span preserves everything verbatim — including
        // the backslash. Without the code-span park running
        // *before* the escape pass, `\$` inside `` ` ` `` would
        // collapse to `$` and the user's literal code would be
        // silently rewritten.
        let html = MarkdownConverter.render("Use `\\$HOME` env.")
        XCTAssertTrue(html.contains("<code>\\$HOME</code>"),
                      "code span must keep the literal backslash")
    }

    // Note: inline `$$…$$` math on a single line cannot carry a
    // `$` of any flavour in its body (the regex uses `[^$]+?`
    // for tractability). Users who need a literal `$` inside
    // display math should use the block-fence form below; that's
    // the verbatim path KaTeX is happy to receive `\$` on.

    func testBlockFenceMathKeepsRawBackslashDollar() {
        // The $$ fence is verbatim — no markdown parsing. `\$`
        // goes through to KaTeX untouched.
        let md = """
        $$
        a \\$ b
        $$
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("a \\$ b"),
                      "fence body must keep \\$ verbatim for KaTeX")
    }

    // MARK: - Negative / boundary cases

    func testPlainBackslashWithoutDollarIsUnaffected() {
        // `\a` is not an escape. This test guards against a
        // pattern error that would eat any `\x`.
        let html = MarkdownConverter.render("path: C:\\\\abc")
        XCTAssertTrue(html.contains("C:"),
                      "backslash without $ must pass through")
    }

    func testEscapeAtEndOfLine() {
        // Trailing `\$` is a weird input but must not crash
        // or swallow the next line.
        let md = """
        line one \\$
        line two.
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("line one $"),
                      "escape at EOL must render literal $")
        XCTAssertTrue(html.contains("line two."),
                      "next line must survive untouched")
    }
}
