//
//  MarkdownConverterTests.swift
//  Phase 30 — coverage for the hand-rolled MarkdownConverter.
//
//  We don't aim for full CommonMark compliance (that's why we shipped
//  a hand-roll); we *do* aim to lock in the subset we promised in
//  the converter doc-comment, so a future tweak can't silently
//  regress headings or fenced code without a red test.
//

import XCTest
@testable import Scribe

final class MarkdownConverterTests: XCTestCase {

    // MARK: Headings

    func testHeadingsByLevel() {
        for n in 1...6 {
            let prefix = String(repeating: "#", count: n)
            let html = MarkdownConverter.render("\(prefix) Title")
            XCTAssertEqual(html, "<h\(n)>Title</h\(n)>\n")
        }
    }

    func testHashWithoutSpaceIsNotHeading() {
        let html = MarkdownConverter.render("#NotAHeading")
        // Falls back to a paragraph; the # is HTML-safe (still #).
        XCTAssertEqual(html, "<p>#NotAHeading</p>\n")
    }

    func testHeadingTrailingHashesStripped() {
        let html = MarkdownConverter.render("## Heading ##")
        XCTAssertEqual(html, "<h2>Heading</h2>\n")
    }

    // MARK: Paragraphs + soft / hard breaks

    func testParagraphFoldsSoftWraps() {
        let md = """
        line one
        line two
        line three
        """
        let html = MarkdownConverter.render(md)
        XCTAssertEqual(html, "<p>line one line two line three</p>\n")
    }

    func testHardBreakViaTwoTrailingSpaces() {
        // The trailing two spaces request a <br/>; the converter
        // emits the break and joins with no extra space.
        let md = "line one  \nline two"
        let html = MarkdownConverter.render(md)
        XCTAssertEqual(html, "<p>line one<br/>line two</p>\n")
    }

    // MARK: Inline emphasis

    func testBoldAndItalic() {
        let html = MarkdownConverter.render("**bold** and *italic*")
        XCTAssertEqual(html,
                       "<p><strong>bold</strong> and <em>italic</em></p>\n")
    }

    func testTripleAsteriskNests() {
        // CommonMark allows either nesting order. Our two-pass
        // emphasis scanner has bold consume the inner `**both**`
        // pair, leaving `*…*` for italic to wrap around it →
        // <em><strong>both</strong></em>.
        let html = MarkdownConverter.render("***both***")
        XCTAssertEqual(html, "<p><em><strong>both</strong></em></p>\n")
    }

    func testUnderscoreEmphasisIgnoredInsideWords() {
        // snake_case_var must NOT become <em>case</em>.
        let html = MarkdownConverter.render("snake_case_var")
        XCTAssertEqual(html, "<p>snake_case_var</p>\n")
    }

    // MARK: Inline code

    func testInlineCodeEscapesAngleBrackets() {
        let html = MarkdownConverter.render("`<div>` is HTML")
        XCTAssertEqual(html,
                       "<p><code>&lt;div&gt;</code> is HTML</p>\n")
    }

    func testInlineCodeProtectedFromEmphasis() {
        // ** inside ` ` should render as literal stars.
        let html = MarkdownConverter.render("`**not bold**`")
        XCTAssertEqual(html,
                       "<p><code>**not bold**</code></p>\n")
    }

    // MARK: Fenced code blocks

    func testFencedCodeWithLanguageHint() {
        let md = """
        ```swift
        let x = 1
        ```
        """
        let html = MarkdownConverter.render(md)
        XCTAssertEqual(html,
                       "<pre><code class=\"language-swift\">let x = 1\n</code></pre>\n")
    }

    func testFencedCodeEscapesHTML() {
        let md = """
        ```
        <html>&amp;</html>
        ```
        """
        let html = MarkdownConverter.render(md)
        // The literal &amp; should escape its `&` so the rendered
        // page actually shows `&amp;`, not collapse to `&`.
        XCTAssertEqual(html,
                       "<pre><code>&lt;html&gt;&amp;amp;&lt;/html&gt;\n</code></pre>\n")
    }

    func testFencedCodeNeverParsedAsMarkdown() {
        let md = """
        ```
        # not a heading
        - not a list
        **not bold**
        ```
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("# not a heading\n"),
                      "literal `#` should survive inside fenced code")
        XCTAssertTrue(html.contains("- not a list\n"))
        XCTAssertTrue(html.contains("**not bold**\n"))
    }

    // MARK: Lists

    func testUnorderedList() {
        let md = """
        - apple
        - banana
        - cherry
        """
        let html = MarkdownConverter.render(md)
        XCTAssertEqual(html,
                       """
                       <ul>
                       <li>apple</li>
                       <li>banana</li>
                       <li>cherry</li>
                       </ul>

                       """)
    }

    func testOrderedList() {
        let md = """
        1. one
        2. two
        3. three
        """
        let html = MarkdownConverter.render(md)
        XCTAssertEqual(html,
                       """
                       <ol>
                       <li>one</li>
                       <li>two</li>
                       <li>three</li>
                       </ol>

                       """)
    }

    func testListClosesWhenBlankLineEnds() {
        let md = """
        - first
        - second

        paragraph
        """
        let html = MarkdownConverter.render(md)
        XCTAssertEqual(html,
                       """
                       <ul>
                       <li>first</li>
                       <li>second</li>
                       </ul>
                       <p>paragraph</p>

                       """)
    }

    // MARK: Blockquote

    func testBlockquoteFolds() {
        let md = """
        > line a
        > line b
        """
        let html = MarkdownConverter.render(md)
        XCTAssertEqual(html,
                       """
                       <blockquote>
                       <p>line a</p>
                       <p>line b</p>
                       </blockquote>

                       """)
    }

    // MARK: Links + images

    func testLinkRendersAnchor() {
        let html = MarkdownConverter.render("see [docs](https://x.test/y)")
        XCTAssertEqual(html,
                       "<p>see <a href=\"https://x.test/y\">docs</a></p>\n")
    }

    func testImageRendersImg() {
        let html = MarkdownConverter.render("![logo](logo.png)")
        XCTAssertEqual(html,
                       "<p><img src=\"logo.png\" alt=\"logo\"/></p>\n")
    }

    // MARK: Thematic break

    func testThematicBreak() {
        let html = MarkdownConverter.render("---")
        XCTAssertEqual(html, "<hr/>\n")
    }

    func testThematicBreakWithSpaces() {
        let html = MarkdownConverter.render("- - -")
        XCTAssertEqual(html, "<hr/>\n")
    }

    // MARK: Whole document smoke test

    func testCombinedDocumentSmoke() {
        let md = """
        # Title

        Intro paragraph with **bold** and `code`.

        ## Sub

        - one
        - two

        > Quote line.

        ```js
        console.log("hi");
        ```
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<h2>Sub</h2>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>one</li>"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("language-js"))
        XCTAssertTrue(html.contains("console.log(&quot;hi&quot;);"))
    }

    // MARK: Hostile input

    func testStrayLeftAngleEscaped() {
        let html = MarkdownConverter.render("a < b")
        XCTAssertEqual(html, "<p>a &lt; b</p>\n")
    }

    func testEmptyInput() {
        XCTAssertEqual(MarkdownConverter.render(""), "")
    }

    func testCRLFNormalised() {
        // Windows-saved README: same output as LF source.
        let md = "# Title\r\n\r\nbody"
        let html = MarkdownConverter.render(md)
        XCTAssertEqual(html, "<h1>Title</h1>\n<p>body</p>\n")
    }

    func testUnclosedFenceStillCloses() {
        // Hitting EOF mid-fence shouldn't leak <pre>.
        let md = """
        ```
        let x = 1
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.hasPrefix("<pre><code>"))
        XCTAssertTrue(html.hasSuffix("</code></pre>\n"))
    }
}
