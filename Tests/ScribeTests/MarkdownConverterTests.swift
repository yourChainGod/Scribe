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

    // MARK: Phase 32 · GFM tables

    func testBasicTableTwoColumns() {
        let md = """
        | Name | Age |
        | --- | --- |
        | Alice | 30 |
        | Bob | 25 |
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<thead>"))
        XCTAssertTrue(html.contains("<th>Name</th>"))
        XCTAssertTrue(html.contains("<th>Age</th>"))
        XCTAssertTrue(html.contains("<td>Alice</td>"))
        XCTAssertTrue(html.contains("<td>30</td>"))
        XCTAssertTrue(html.hasSuffix("</tbody>\n</table>\n"))
    }

    func testTableAlignmentColons() {
        // :--- left, ---: right, :---: center, --- none.
        let md = """
        | L | R | C | N |
        | :--- | ---: | :---: | --- |
        | a | b | c | d |
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">L</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:right\">R</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:center\">C</th>"))
        // The "none" cell should NOT carry a style attribute.
        XCTAssertTrue(html.contains("<th>N</th>"))
        // Body picks up the same alignment.
        XCTAssertTrue(html.contains("<td style=\"text-align:right\">b</td>"))
    }

    func testTableInlineEmphasisInCells() {
        let md = """
        | name | note |
        | --- | --- |
        | **bold** | `code` |
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<td><strong>bold</strong></td>"))
        XCTAssertTrue(html.contains("<td><code>code</code></td>"))
    }

    func testTableShortRowsRightPadded() {
        // Body rows with fewer cells than the header get empty
        // <td>s appended so the column count stays uniform.
        let md = """
        | a | b | c |
        | --- | --- | --- |
        | 1 |
        """
        let html = MarkdownConverter.render(md)
        // First body cell, then two empty placeholders.
        XCTAssertTrue(html.contains("<tr><td>1</td><td></td><td></td></tr>"))
    }

    func testTableEndsAtBlankLineThenParagraph() {
        let md = """
        | a | b |
        | --- | --- |
        | 1 | 2 |

        after
        """
        let html = MarkdownConverter.render(md)
        // Table closes, then a fresh <p>after</p>.
        XCTAssertTrue(html.contains("</tbody>\n</table>\n<p>after</p>"))
    }

    func testPipeRowWithoutAlignmentStaysParagraph() {
        // No alignment row → the pipe line is just text. Output
        // should be a paragraph with the literal pipes.
        let md = "| this is | not a table |"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<p>"))
        XCTAssertTrue(html.contains("| this is | not a table |"))
        XCTAssertFalse(html.contains("<table>"))
    }

    func testBlockquoteWithPipeStaysBlockquote() {
        // A `>` line containing a `|` must remain a blockquote,
        // not get hijacked by the table-stash gate.
        let md = "> | inside | quote |"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertFalse(html.contains("<table>"))
    }

    // MARK: Phase 32 · Task lists

    func testTaskListUnchecked() {
        let md = "- [ ] todo"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<li class=\"task-list-item\">"))
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled/> todo"))
        XCTAssertFalse(html.contains("checked"))
    }

    func testTaskListChecked() {
        let md = "- [x] done"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled checked/> done"))
    }

    func testTaskListUppercaseXAlsoChecked() {
        let md = "- [X] also done"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("checked"))
    }

    func testTaskListMixedWithRegularItems() {
        let md = """
        - regular
        - [ ] todo
        - [x] done
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<li>regular</li>"))
        XCTAssertTrue(html.contains("<li class=\"task-list-item\">"))
        XCTAssertTrue(html.contains("checked"))
    }

    func testTaskListInlineEmphasisInContent() {
        let md = "- [ ] **bold** task"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled/> "
                                    + "<strong>bold</strong> task"))
    }

    // MARK: Phase 32 · Footnotes

    func testSingleFootnote() {
        let md = """
        Body with[^a] note.

        [^a]: definition text
        """
        let html = MarkdownConverter.render(md)
        // Inline ref is numbered [1] and links to fn-a.
        XCTAssertTrue(html.contains(
            "<sup class=\"footnote-ref\"><a href=\"#fn-a\" id=\"fnref-a\">[1]</a></sup>"
        ))
        // Trailing footnotes section appears with the def text and
        // a back-ref anchor.
        XCTAssertTrue(html.contains("<section class=\"footnotes\">"))
        XCTAssertTrue(html.contains("<li id=\"fn-a\">definition text"))
        XCTAssertTrue(html.contains("<a href=\"#fnref-a\" class=\"footnote-back\""))
    }

    func testTwoFootnotesNumberedInOrder() {
        let md = """
        First[^foo] then[^bar] then[^foo] again.

        [^bar]: bee
        [^foo]: eff
        """
        let html = MarkdownConverter.render(md)
        // foo encountered first → [1]; bar second → [2]; second foo
        // reuses [1]. Definition order in the source doesn't change
        // numbering — encounter order in the body does.
        XCTAssertTrue(html.contains("href=\"#fn-foo\" id=\"fnref-foo\">[1]"))
        XCTAssertTrue(html.contains("href=\"#fn-bar\" id=\"fnref-bar\">[2]"))
        // foo definition listed before bar in the trailing <ol>.
        if let fooPos = html.range(of: "id=\"fn-foo\""),
           let barPos = html.range(of: "id=\"fn-bar\"") {
            XCTAssertLessThan(fooPos.lowerBound, barPos.lowerBound)
        } else {
            XCTFail("Expected both footnote li ids in the rendered output")
        }
    }

    func testFootnoteRefWithoutDefStaysLiteral() {
        // No def for ^missing → the ref stays as the literal text
        // and no footnotes section is emitted.
        let md = "see[^missing] note"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("see[^missing] note"))
        XCTAssertFalse(html.contains("<section class=\"footnotes\">"))
    }

    func testFootnoteDefWithoutRefIsDropped() {
        // No reference points at the def → no section in output,
        // and the def line is consumed (not rendered as a paragraph).
        let md = """
        plain paragraph

        [^orphan]: forgotten
        """
        let html = MarkdownConverter.render(md)
        XCTAssertFalse(html.contains("forgotten"))
        XCTAssertFalse(html.contains("<section class=\"footnotes\">"))
        XCTAssertTrue(html.contains("<p>plain paragraph</p>"))
    }

    func testFootnoteWithEmphasisInDef() {
        let md = """
        ref[^x]

        [^x]: with **bold** word
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<li id=\"fn-x\">with <strong>bold</strong> word"))
    }

    // MARK: Pipe row at EOF

    func testPendingPipeRowAtEOFFallsBackToParagraph() {
        // No alignment row arrives — the stashed line should be
        // emitted as a paragraph at EOF, not silently dropped.
        let md = "| just text |"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<p>"))
        XCTAssertTrue(html.contains("| just text |"))
        XCTAssertFalse(html.contains("<table>"))
    }
}
