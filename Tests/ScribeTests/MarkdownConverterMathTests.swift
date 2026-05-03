//
//  MarkdownConverterMathTests.swift
//  Phase 53c — the converter half of KaTeX support. These tests
//  pin the Swift-side "don't let markdown break LaTeX" invariants:
//
//    1. `$x$` / `$$x$$` inline shapes land inside dedicated
//       span classes KaTeX can pick up.
//    2. `$$ \n ... \n $$` display-math fence preserves every byte
//       verbatim (LaTeX control sequences include `_`, `*`, `\`,
//       `{`, `}` — every one of them a landmine for the markdown
//       emphasis / code / link regexes).
//    3. Math extraction beats emphasis: `$x_i$` must not leave
//       `<em>i</em>` behind.
//    4. Math extraction loses to code spans: `` `$x$` `` stays a
//       literal code span.
//    5. Dangling fences don't eat unrelated paragraphs; a
//       malformed `$$` without a close still produces useful HTML.
//    6. Source-line stamps land on the math block's opener so the
//       preview-scroll sync (Phase 52a/b) can reveal it.
//
//  JS-side rendering (katex.render) needs a live WKWebView; its
//  structural invariants are pinned in MarkdownPreviewMathTests.
//

import XCTest
@testable import Scribe

final class MarkdownConverterMathTests: XCTestCase {

    // MARK: - Inline shapes

    func testInlineMathWrapsInMathInlineSpan() {
        let html = MarkdownConverter.render("Cost is $c$ per item.")
        XCTAssertTrue(html.contains("<span class=\"math-inline\">c</span>"),
                      "inline math must land in .math-inline span")
    }

    func testInlineDisplayMathOnSingleLineWrapsInMathDisplaySpan() {
        // `$$E=mc^2$$` on a content-bearing line is *inline* display
        // math (no surrounding block). The converter still uses a
        // span (not div) so it can sit inside a `<p>`.
        let html = MarkdownConverter.render("See $$E=mc^2$$ for intuition.")
        XCTAssertTrue(html.contains("<span class=\"math-display\">E=mc^2</span>"),
                      "single-line $$…$$ must land in .math-display span")
    }

    func testDisplayMathWinsOverInlineRegex() {
        // `$$x$$` on its own line must parse as one display span,
        // not `$<empty>$` + `x` + `$<empty>$`. The display regex
        // has to run before the inline regex for this to work.
        let html = MarkdownConverter.render("$$x$$")
        XCTAssertTrue(html.contains("<span class=\"math-display\">x</span>"),
                      "display regex must run before inline")
        XCTAssertFalse(html.contains("<span class=\"math-inline\"></span>"),
                       "inline regex must not match empty `$$`")
    }

    // MARK: - LaTeX survival

    func testInlineMathPreservesUnderscores() {
        // Without a park stage, `$x_i$` would have its `_i` turned
        // into `<em>i</em>` by the emphasis regex — catastrophic
        // for math because KaTeX wouldn't see the subscript syntax
        // at all. Parking math *before* emphasis is the whole point
        // of this regression test.
        let html = MarkdownConverter.render("Subscript: $x_i$")
        XCTAssertTrue(html.contains("<span class=\"math-inline\">x_i</span>"),
                      "underscore inside math must survive untouched")
        XCTAssertFalse(html.contains("<em>"),
                       "emphasis must not reach inside math")
    }

    func testInlineMathPreservesBackslashSequences() {
        // `\alpha`, `\beta` — the daily bread of LaTeX. The HTML
        // escaper passes backslash through unchanged, so the only
        // risk is a stray regex chewing them up.
        let html = MarkdownConverter.render("Greek: $\\alpha + \\beta$")
        XCTAssertTrue(html.contains("<span class=\"math-inline\">\\alpha + \\beta</span>"),
                      "backslash sequences must survive")
    }

    func testInlineMathEscapesHTMLSpecials() {
        // LaTeX often uses `<` / `>`; the content goes into
        // textContent so we must emit HTML-escaped characters or
        // the browser parses them as stray tags.
        let html = MarkdownConverter.render("Compare $a<b$ still.")
        XCTAssertTrue(html.contains("<span class=\"math-inline\">a&lt;b</span>"),
                      "HTML-special characters inside math must be escaped")
    }

    // MARK: - Boundary with other inline rules

    func testMathInsideInlineCodeIsLiteral() {
        // A code span is the one place markdown refuses to process
        // anything — including our math regex. `` `$x$` `` should
        // emit `<code>$x$</code>` with the dollars intact.
        let html = MarkdownConverter.render("Literal: `$x$`")
        XCTAssertTrue(html.contains("<code>$x$</code>"),
                      "math inside code span must stay literal")
        XCTAssertFalse(html.contains("<span class=\"math-inline\">x</span>"),
                       "code span must win over math regex")
    }

    func testMathInsideLinkLabelStillDetected() {
        // Link labels recurse through renderInline, so a math span
        // inside the label *does* get converted. Pinning this case
        // so a future refactor that breaks the recursion trips a
        // test rather than silently regressing.
        let html = MarkdownConverter.render("[$x$](https://ex.com)")
        XCTAssertTrue(html.contains("<span class=\"math-inline\">x</span>"),
                      "math inside link label must be detected via recursion")
        XCTAssertTrue(html.contains("<a href=\"https://ex.com\">"),
                      "link wrapping must still happen")
    }

    // MARK: - Display block fence

    func testDisplayMathFenceEmitsMathDisplayDiv() {
        let md = """
        Text before.

        $$
        \\int_0^1 x\\,dx = \\tfrac{1}{2}
        $$

        Text after.
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<div class=\"math-display\" data-source-line=\"3\">"),
                      "display fence must emit a div stamped at its opening $$ line")
        // Both the integral and the fraction should be inside the div.
        XCTAssertTrue(html.contains("\\int_0^1 x\\,dx = \\tfrac{1}{2}"),
                      "fence body must survive verbatim")
        XCTAssertTrue(html.contains("</div>"),
                      "fence must close with </div>")
    }

    func testDisplayMathFenceMultiline() {
        // Multi-line LaTeX (common for matrices / aligned
        // equations) needs each line preserved *with* the
        // newlines between them. KaTeX's tokenizer treats newlines
        // as whitespace but we keep them for readability in the
        // rendered source.
        let md = """
        $$
        \\begin{matrix}
        a & b \\\\
        c & d
        \\end{matrix}
        $$
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("\\begin{matrix}"))
        XCTAssertTrue(html.contains("\\end{matrix}"))
        // Newlines inside should still be there. `&` is HTML-escaped
        // to `&amp;` because the fence content goes through
        // htmlEscape — KaTeX's textContent reader unescapes back to
        // the literal `&` once the DOM lands.
        XCTAssertTrue(html.contains("a &amp; b"))
        XCTAssertTrue(html.contains("c &amp; d"))
    }

    func testDisplayMathFenceDoesNotParseMarkdownInside() {
        // `_i_` inside a fence would be emphasis in regular
        // markdown. The fence must short-circuit all of that.
        let md = """
        $$
        _i_ and *j*
        $$
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("_i_ and *j*"),
                      "markdown must not reach inside the math fence")
        XCTAssertFalse(html.contains("<em>i</em>"),
                       "emphasis must not fire inside the math fence")
    }

    func testUnclosedDisplayMathFenceStillEmitsContent() {
        // EOF-inside-fence is a malformed doc, but the user's
        // content should still show up as a math-display div so
        // KaTeX can try to render it (and fall back to literal
        // text on failure).
        let md = """
        $$
        x^2 + y^2 = r^2
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<div class=\"math-display\""),
                      "unclosed fence must still emit a div")
        XCTAssertTrue(html.contains("x^2 + y^2 = r^2"),
                      "content must survive the unclosed fence")
    }

    // MARK: - Non-math lines unaffected

    func testPlainParagraphIsUnaffected() {
        // Fast-path sanity: a dollar-free line must not touch the
        // math regex at all. We can't observe the fast path
        // directly, but a stable output on a pure-prose line
        // at least proves we didn't corrupt the text.
        let html = MarkdownConverter.render("Hello world")
        XCTAssertTrue(html.contains("<p"))
        XCTAssertTrue(html.contains("Hello world</p>"))
    }

    func testLoneDollarSignDoesNotMatch() {
        // One `$` on a line must not be misread as an empty math
        // span. Users write about prices (`$5`), shell (`$HOME`),
        // etc., all the time.
        let html = MarkdownConverter.render("Cost: $5 each")
        XCTAssertFalse(html.contains("<span class=\"math-inline\""),
                       "solitary $ must not trigger math parsing")
        XCTAssertTrue(html.contains("Cost: $5 each"),
                      "original text must reach the <p>")
    }

    func testDollarSignsSeparatedByNewlineDoNotMatch() {
        // The inline regex excludes `\n`, so a `$` on one line
        // and another a few lines down must not silently eat
        // everything between them.
        let md = """
        Price: $5 and up.

        More text.

        Discount: $2 off.
        """
        let html = MarkdownConverter.render(md)
        XCTAssertFalse(html.contains("<span class=\"math-inline\""),
                       "dollars on distinct lines must not span-match")
    }
}
