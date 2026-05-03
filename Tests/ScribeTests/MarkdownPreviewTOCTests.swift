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

    // Phase 52a — the reveal helper no longer depends on a Swift-built
    // `__scribeHeadings` literal. The DOM (every `[data-source-line]`
    // element stamped by the converter) is the source of truth, so
    // these tests pin the new contract: helper *names*, the build
    // path that scans the DOM, and the binary-search reveal logic.

    func test_revealLineScript_definesBlockIndexBuilder() {
        // The page-side helper that enumerates `[data-source-line]`
        // and stuffs the result into `window.__scribeBlockIndex`.
        let s = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(s.contains("window.scribeBuildBlockIndex"),
                      "must declare the index builder — got \(s)")
        XCTAssertTrue(s.contains("data-source-line"),
                      "builder must scan the data-source-line attribute")
        XCTAssertTrue(s.contains("__scribeBlockIndex"),
                      "must publish the index on window so injectBody can rebuild")
    }

    func test_revealLineScript_definesRevealFunction() {
        let s = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(s.contains("window.scribeRevealLine"),
                      "must declare the public reveal helper")
        XCTAssertTrue(s.contains("scrollIntoView"),
                      "must call scrollIntoView so the block is brought into the viewport")
    }

    func test_revealLineScript_usesBinarySearchForReveal() {
        // The reveal helper does a "largest entry ≤ line" lookup; the
        // pre-52a linear scan worked for ≤100 headings but blows out
        // when every paragraph is in the index. Lock the binary search
        // by checking for the canonical loop tokens.
        let s = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(s.contains("lo = 0"),
                      "must initialise lo for binary search")
        XCTAssertTrue(s.contains("hi ="),
                      "must initialise hi for binary search")
        XCTAssertTrue(s.contains(">> 1"),
                      "must use bit-shift midpoint — got \(s)")
    }

    func test_revealLineScript_doesNotEmbedSwiftHeadingData() {
        // Backstop: the old path serialised the heading map into the
        // emitted JS. The new path reads the DOM, so the script must
        // *not* contain a hard-coded array of source-line / slug
        // pairs from Swift — that would risk drift between the
        // injected body and the index, exactly the bug 52a removes.
        let h: [MarkdownPreviewPane.PreviewHeading] = [
            .init(line: 5, level: 1, slug: "intro", title: "Intro"),
        ]
        let s = MarkdownPreviewPane.revealLineScript(headings: h)
        XCTAssertFalse(s.contains("\"intro\""),
                       "must not inline heading slugs — got \(s)")
        XCTAssertFalse(s.contains("__scribeHeadings"),
                       "the legacy heading map global should be gone")
    }

    func test_revealLineScript_buildsIndexOnDOMReady() {
        // The shell ships with the script in `<head>`, so DOMContent-
        // Loaded fires *after* the script parses and the helper
        // wouldn't run unless we wire it up explicitly.
        let s = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(s.contains("DOMContentLoaded")
                       || s.contains("readyState"),
                      "must auto-build the index once the DOM is ready — got \(s)")
    }
}
