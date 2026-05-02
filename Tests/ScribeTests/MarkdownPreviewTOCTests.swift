//
//  MarkdownPreviewTOCTests.swift
//  Phase 51e — pin the heading scanner, the inline-TOC HTML builder
//  and the reveal-line script so the markdown preview's caret-driven
//  scroll sync stays grounded in the same slug rules the converter
//  emits. Three concerns:
//
//    · `extractHeadings` walks the source markdown and surfaces ATX
//      headings *outside* fenced code blocks.
//    · `renderTOC` lays a navigation block at the top of #md-root
//      when there are at least 3 headings (≤ H3); fewer or higher
//      level headings shouldn't materialise chrome.
//    · `revealLineScript` packs the heading line→id map into a JS
//      object literal the caret-sync runtime can iterate.
//
//  All three live as static helpers on `MarkdownPreviewPane`; the
//  WKWebView round-trip is deliberately out of scope for these tests
//  (it'd be flaky inside XCTest and the JS shape is what we actually
//  need to nail down).
//

import XCTest
@testable import Scribe

final class MarkdownPreviewTOCTests: XCTestCase {

    // MARK: - extractHeadings

    func test_extract_returnsEmptyForBlankInput() {
        XCTAssertEqual(MarkdownPreviewPane.extractHeadings(""), [])
        XCTAssertEqual(MarkdownPreviewPane.extractHeadings("just text\nand more"), [])
    }

    func test_extract_capturesATXHeading() {
        let md = "# Hello"
        let result = MarkdownPreviewPane.extractHeadings(md)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].line, 1)
        XCTAssertEqual(result[0].level, 1)
        XCTAssertEqual(result[0].slug, "hello")
        XCTAssertEqual(result[0].title, "Hello")
    }

    func test_extract_capturesMultipleLevels() {
        let md = "# Top\n## Middle\n### Leaf"
        let r = MarkdownPreviewPane.extractHeadings(md)
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r[0].level, 1)
        XCTAssertEqual(r[1].level, 2)
        XCTAssertEqual(r[2].level, 3)
        XCTAssertEqual(r.map(\.line), [1, 2, 3])
    }

    func test_extract_skipsHashesInsideFencedCode() {
        let md = """
        # Real
        ```
        # Fake
        ## Also Fake
        ```
        ## Back Outside
        """
        let r = MarkdownPreviewPane.extractHeadings(md)
        XCTAssertEqual(r.map(\.title), ["Real", "Back Outside"])
    }

    func test_extract_skipsTildeFencedCode() {
        let md = """
        # Real
        ~~~
        # Fake
        ~~~
        ## End
        """
        let r = MarkdownPreviewPane.extractHeadings(md)
        XCTAssertEqual(r.map(\.title), ["Real", "End"])
    }

    func test_extract_distinctFencesDontCloseEachOther() {
        // A backtick-opened fence shouldn't be closed by a tilde line
        // and vice versa. The "fake" hashes between the markers must
        // stay invisible.
        let md = """
        # A
        ```
        # fake
        ~~~ not closing
        # fake2
        ```
        # B
        """
        let r = MarkdownPreviewPane.extractHeadings(md)
        XCTAssertEqual(r.map(\.title), ["A", "B"])
    }

    func test_extract_requiresWhitespaceAfterHashes() {
        // `#foo` is a paragraph, not a heading.
        XCTAssertEqual(MarkdownPreviewPane.extractHeadings("#foo"), [])
    }

    func test_extract_stripsTrailingClosingHashes() {
        let r = MarkdownPreviewPane.extractHeadings("## Bar ##")
        XCTAssertEqual(r.first?.title, "Bar")
    }

    func test_extract_capsAtSixHashes() {
        let r = MarkdownPreviewPane.extractHeadings("####### Too Deep")
        // Seven hashes is not a heading.
        XCTAssertEqual(r, [])
    }

    func test_extract_dedupsSlugsLikeConverter() {
        let md = "# Foo\n# Foo\n# Foo"
        let r = MarkdownPreviewPane.extractHeadings(md)
        XCTAssertEqual(r.map(\.slug), ["foo", "foo-1", "foo-2"])
    }

    func test_extract_preservesCRLFLineNumbers() {
        // 1-based line numbers must agree with Document.cursorLine
        // even when the source uses CRLF endings.
        let md = "# A\r\n\r\nbody\r\n## B"
        let r = MarkdownPreviewPane.extractHeadings(md)
        XCTAssertEqual(r.map(\.line), [1, 4])
    }

    func test_extract_acceptsLeadingWhitespace() {
        // Permissive — converter accepts indented headings, so we
        // mirror its behaviour.
        let r = MarkdownPreviewPane.extractHeadings("  ## Indented")
        XCTAssertEqual(r.first?.title, "Indented")
    }

    func test_extract_dropsEmptyHeading() {
        // `# ` with nothing after is not a heading the converter
        // would emit an id for, so we don't either.
        XCTAssertEqual(MarkdownPreviewPane.extractHeadings("#  "), [])
        XCTAssertEqual(MarkdownPreviewPane.extractHeadings("#"), [])
    }

    // MARK: - renderTOC

    func test_renderTOC_emitsNothingBelowThreeHeadings() {
        let one = [MarkdownPreviewPane.PreviewHeading(line: 1, level: 1,
                                                      slug: "a", title: "A")]
        XCTAssertEqual(MarkdownPreviewPane.renderTOC(one), "")
        let two = one + [MarkdownPreviewPane.PreviewHeading(line: 2, level: 1,
                                                            slug: "b", title: "B")]
        XCTAssertEqual(MarkdownPreviewPane.renderTOC(two), "")
    }

    func test_renderTOC_emitsNavWithThreeOrMoreHeadings() {
        let h: [MarkdownPreviewPane.PreviewHeading] = [
            .init(line: 1, level: 1, slug: "a", title: "A"),
            .init(line: 2, level: 2, slug: "b", title: "B"),
            .init(line: 3, level: 3, slug: "c", title: "C"),
        ]
        let html = MarkdownPreviewPane.renderTOC(h)
        XCTAssertTrue(html.hasPrefix("<nav class=\"md-toc\">"),
                      "TOC must open with the md-toc nav tag — got: \(html.prefix(60))")
        XCTAssertTrue(html.contains("href=\"#a\""))
        XCTAssertTrue(html.contains("href=\"#b\""))
        XCTAssertTrue(html.contains("href=\"#c\""))
        XCTAssertTrue(html.contains("md-toc-l1"))
        XCTAssertTrue(html.contains("md-toc-l2"))
        XCTAssertTrue(html.contains("md-toc-l3"))
        XCTAssertTrue(html.hasSuffix("</nav>"))
    }

    func test_renderTOC_dropsHeadingsDeeperThanH3() {
        let h: [MarkdownPreviewPane.PreviewHeading] = [
            .init(line: 1, level: 1, slug: "a", title: "A"),
            .init(line: 2, level: 4, slug: "b", title: "B"),
            .init(line: 3, level: 5, slug: "c", title: "C"),
        ]
        // Only 1 visible heading remains → empty TOC.
        XCTAssertEqual(MarkdownPreviewPane.renderTOC(h), "")
    }

    func test_renderTOC_escapesTitleHTML() {
        let h: [MarkdownPreviewPane.PreviewHeading] = [
            .init(line: 1, level: 1, slug: "a", title: "<b> & \"x\""),
            .init(line: 2, level: 1, slug: "b", title: "B"),
            .init(line: 3, level: 1, slug: "c", title: "C"),
        ]
        let html = MarkdownPreviewPane.renderTOC(h)
        XCTAssertTrue(html.contains("&lt;b&gt;"), "must escape <")
        XCTAssertTrue(html.contains("&amp;"), "must escape &")
        XCTAssertTrue(html.contains("&quot;"), "must escape \"")
        XCTAssertFalse(html.contains("<b>"), "must not leak raw <b>")
    }

    // MARK: - revealLineScript

    func test_revealLineScript_emitsEmptyArrayWhenNoHeadings() {
        let s = MarkdownPreviewPane.revealLineScript(headings: [])
        XCTAssertTrue(s.contains("window.__scribeHeadings = [];"))
        XCTAssertTrue(s.contains("scribeRevealLine"))
    }

    func test_revealLineScript_emitsLineAndSlugPairs() {
        let h: [MarkdownPreviewPane.PreviewHeading] = [
            .init(line: 5,  level: 1, slug: "intro",   title: "Intro"),
            .init(line: 12, level: 2, slug: "details", title: "Details"),
        ]
        let s = MarkdownPreviewPane.revealLineScript(headings: h)
        XCTAssertTrue(s.contains("{l:5,i:\"intro\"}"),
                      "must serialise first heading: \(s)")
        XCTAssertTrue(s.contains("{l:12,i:\"details\"}"),
                      "must serialise second heading")
    }

    func test_revealLineScript_escapesQuotesInSlug() {
        // Slugs from the converter never contain quote characters, but
        // the helper has to be safe regardless.
        let h: [MarkdownPreviewPane.PreviewHeading] = [
            .init(line: 1, level: 1, slug: "weird\"name", title: "Weird"),
        ]
        let s = MarkdownPreviewPane.revealLineScript(headings: h)
        XCTAssertTrue(s.contains("\\\""),
                      "must escape embedded quotes in slug — got \(s)")
    }

    func test_revealLineScript_definesRevealFunction() {
        let s = MarkdownPreviewPane.revealLineScript(headings: [])
        XCTAssertTrue(s.contains("window.scribeRevealLine"),
                      "must declare the public reveal helper")
        XCTAssertTrue(s.contains("scrollIntoView"),
                      "must call scrollIntoView so the heading is brought into the viewport")
    }
}
