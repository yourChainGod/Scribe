//
//  MarkdownConverterSourceLineTests.swift
//  Phase 52a — the converter now stamps every block-level element
//  with a `data-source-line="<N>"` attribute so the preview's
//  scroll-sync helpers can map an editor line to the rendered
//  block. These tests pin the line-number contract for each block
//  type independently of the slug / id / GFM tests, so a future
//  re-arrange of the dispatch order can't silently lose a
//  source-line stamp.
//

import XCTest
@testable import Scribe

final class MarkdownConverterSourceLineTests: XCTestCase {

    // MARK: - Headings

    func test_heading_carriesItsOwnSourceLine() {
        // Three-line file → second `## …` is on line 3.
        let md = "intro\n\n## Section"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<h2 id=\"section\" data-source-line=\"3\">"),
                      "got \(html)")
    }

    func test_eachHeadingGetsItsOwnLine() {
        let md = """
        # One
        text
        ## Two
        more
        ### Three
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("data-source-line=\"1\">One</h1>"))
        XCTAssertTrue(html.contains("data-source-line=\"3\">Two</h2>"))
        XCTAssertTrue(html.contains("data-source-line=\"5\">Three</h3>"))
    }

    // MARK: - Paragraphs

    func test_paragraph_usesItsOpeningLine() {
        // Paragraph spans lines 3–5; the stamp must point at the
        // first line, not the last.
        let md = """
        # Title

        body line one
        body line two
        body line three
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<p data-source-line=\"3\">"),
                      "paragraph must stamp the opening line — got \(html)")
    }

    func test_consecutiveParagraphsKeepIndependentLines() {
        let md = """
        first paragraph

        second paragraph
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<p data-source-line=\"1\">first paragraph</p>"))
        XCTAssertTrue(html.contains("<p data-source-line=\"3\">second paragraph</p>"))
    }

    // MARK: - Lists

    func test_unorderedListStampsContainerAndItems() {
        let md = """
        intro
        - one
        - two
        """
        let html = MarkdownConverter.render(md)
        // <ul> opens on the first list item line.
        XCTAssertTrue(html.contains("<ul data-source-line=\"2\">"))
        XCTAssertTrue(html.contains("<li data-source-line=\"2\">one</li>"))
        XCTAssertTrue(html.contains("<li data-source-line=\"3\">two</li>"))
    }

    func test_orderedListStampsContainerAndItems() {
        let md = """
        1. one
        2. two
        3. three
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<ol data-source-line=\"1\">"))
        XCTAssertTrue(html.contains("<li data-source-line=\"1\">one</li>"))
        XCTAssertTrue(html.contains("<li data-source-line=\"3\">three</li>"))
    }

    func test_taskListItemsStampSourceLine() {
        let md = """
        - regular
        - [ ] todo
        - [x] done
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<li data-source-line=\"1\">regular</li>"))
        XCTAssertTrue(html.contains("<li class=\"task-list-item\" data-source-line=\"2\">"))
        XCTAssertTrue(html.contains("<li class=\"task-list-item\" data-source-line=\"3\">"))
    }

    // MARK: - Blockquote

    func test_blockquoteStampsContainerAndInnerParagraphs() {
        let md = """

        > quote a
        > quote b
        """
        let html = MarkdownConverter.render(md)
        // Outer <blockquote> opens on the first `> ` line (line 2),
        // each inner `<p>` carries its own line.
        XCTAssertTrue(html.contains("<blockquote data-source-line=\"2\">"))
        XCTAssertTrue(html.contains("<p data-source-line=\"2\">quote a</p>"))
        XCTAssertTrue(html.contains("<p data-source-line=\"3\">quote b</p>"))
    }

    // MARK: - Fenced code

    func test_fencedCodeStampsOpeningPre() {
        let md = """
        intro

        ```swift
        let x = 1
        ```
        """
        let html = MarkdownConverter.render(md)
        // <pre> opens on the fence line (3). The inner <code> is
        // intentionally NOT stamped (hljs mutates that subtree, so
        // a stamp there would risk getting wiped).
        XCTAssertTrue(html.contains("<pre data-source-line=\"3\"><code"),
                      "got \(html)")
    }

    // MARK: - Thematic break

    func test_thematicBreakStampsHr() {
        let md = """
        before

        ---

        after
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<hr data-source-line=\"3\"/>"),
                      "got \(html)")
    }

    // MARK: - Tables

    func test_tableStampsHeaderLineOnTableElement() {
        // openTable fires on the alignment row (line 2) so the
        // converter has to back up by one to point at the actual
        // header (line 1) — the line a user sees as "the table".
        let md = """
        | a | b |
        | --- | --- |
        | 1 | 2 |
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<table data-source-line=\"1\">"))
    }

    func test_tableBodyRowsCarryTheirOwnLines() {
        let md = """
        | a | b |
        | --- | --- |
        | 1 | 2 |
        | 3 | 4 |
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<tr data-source-line=\"3\">"),
                      "first body row should be line 3 — got \(html)")
        XCTAssertTrue(html.contains("<tr data-source-line=\"4\">"),
                      "second body row should be line 4 — got \(html)")
    }

    // MARK: - Footnote definition lines must not shift line numbers

    func test_footnoteDefinitionLinesPreserveLineNumbering() {
        // The pre-pass replaces `[^id]: …` lines with blank lines
        // rather than dropping them, so the body lines after a
        // definition keep their original numbering. A paragraph
        // following a def must still stamp the line *as the user
        // sees it in the editor*, not a shifted-by-one line.
        let md = """
        [^a]: definition

        body[^a]
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<p data-source-line=\"3\">"),
                      "the body paragraph is on line 3 in the source — got \(html)")
    }

    // MARK: - CRLF handling

    func test_crlfSourceProducesSameLineStamps() {
        // Windows-saved file: identical block stamps to the LF form.
        let md = "# Title\r\n\r\nbody\r\n"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("data-source-line=\"1\">Title</h1>"))
        XCTAssertTrue(html.contains("<p data-source-line=\"3\">body</p>"))
    }

    // MARK: - Negative: no spurious stamps on inline elements

    func test_inlineElementsDoNotGetSourceLine() {
        // The attribute belongs on block-level openers only;
        // inline tags inside a paragraph (`<strong>`, `<em>`,
        // `<code>`, `<a>`) must stay clean so the JS DOM scan
        // doesn't double-count.
        let md = "**bold** and `code` and [x](https://e.test)"
        let html = MarkdownConverter.render(md)
        XCTAssertFalse(html.contains("<strong data-source-line"),
                       "inline <strong> must not be stamped")
        XCTAssertFalse(html.contains("<em data-source-line"),
                       "inline <em> must not be stamped")
        XCTAssertFalse(html.contains("<code data-source-line"),
                       "inline <code> must not be stamped")
        XCTAssertFalse(html.contains("<a data-source-line"),
                       "inline <a> must not be stamped")
    }
}
