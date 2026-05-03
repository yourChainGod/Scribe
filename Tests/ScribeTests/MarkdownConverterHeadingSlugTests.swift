//
//  MarkdownConverterHeadingSlugTests.swift
//  Phase 51c — every heading carries a GitHub-flavoured slug as its
//  `id` so anchor links (`[link](#section)`) and the in-app TOC
//  work without a JS pass. The slug helper is exposed as a `static`
//  on `MarkdownConverter` so the contract can be locked in
//  isolation; the per-render uniqueness rule is tested through
//  `render(_:)`.
//

import XCTest
@testable import Scribe

final class MarkdownConverterHeadingSlugTests: XCTestCase {

    // MARK: - headingSlug helper

    func test_slug_lowercasesAndDashesSpaces() {
        XCTAssertEqual(MarkdownConverter.headingSlug("Hello World"),
                       "hello-world")
    }

    func test_slug_collapsesMultipleSpaces() {
        XCTAssertEqual(MarkdownConverter.headingSlug("foo    bar"),
                       "foo-bar")
    }

    func test_slug_dropsPunctuation() {
        XCTAssertEqual(MarkdownConverter.headingSlug("What is `code`?"),
                       "what-is-code")
    }

    func test_slug_keepsDashAndUnderscore() {
        XCTAssertEqual(MarkdownConverter.headingSlug("api_v2-style"),
                       "api_v2-style")
    }

    func test_slug_stripsEmphasisMarkup() {
        // **bold**, *em*, `code`, [a](b) — none of these chars
        // should leak into the slug.
        XCTAssertEqual(MarkdownConverter.headingSlug("**Setup** notes"),
                       "setup-notes")
        XCTAssertEqual(MarkdownConverter.headingSlug("*one* and `two`"),
                       "one-and-two")
    }

    func test_slug_preservesCJK() {
        // Safari resolves UTF-8 fragment ids fine; we keep the
        // characters so the link text stays meaningful.
        XCTAssertEqual(MarkdownConverter.headingSlug("安装步骤"),
                       "安装步骤")
        XCTAssertEqual(MarkdownConverter.headingSlug("安装 步骤"),
                       "安装-步骤")
    }

    func test_slug_preservesAccentedLatin() {
        XCTAssertEqual(MarkdownConverter.headingSlug("Café Résumé"),
                       "café-résumé")
    }

    func test_slug_stripsLeadingAndTrailingDashes() {
        XCTAssertEqual(MarkdownConverter.headingSlug("---only---"),
                       "only")
        XCTAssertEqual(MarkdownConverter.headingSlug("?Hello!"),
                       "hello")
    }

    func test_slug_emptyInputReturnsEmpty() {
        XCTAssertEqual(MarkdownConverter.headingSlug(""), "")
        // All-punct input collapses to "" too — the caller
        // (`uniqueSlug(for:)`) substitutes "section" so the emitted
        // id is never empty.
        XCTAssertEqual(MarkdownConverter.headingSlug("???"), "")
    }

    // MARK: - render() integration

    func test_render_headingHasIdAttribute() {
        let html = MarkdownConverter.render("## Hello World")
        XCTAssertEqual(html, "<h2 id=\"hello-world\" data-source-line=\"1\">Hello World</h2>\n")
    }

    func test_render_emphasisInsideHeadingDoesNotPolluteSlug() {
        // Inline markdown still renders inside the heading text;
        // the slug ignores it so the id is the prose form.
        let html = MarkdownConverter.render("# **Setup** notes")
        XCTAssertTrue(html.contains("id=\"setup-notes\""),
                      "slug must ignore emphasis markers — got \(html)")
        XCTAssertTrue(html.contains("<strong>Setup</strong>"),
                      "heading inner text still renders emphasis — got \(html)")
    }

    func test_render_duplicateHeadingsGetSuffixedIds() {
        let md = """
        ## Setup
        ## Setup
        ## Setup
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<h2 id=\"setup\" data-source-line=\"1\">Setup</h2>"),
                      "first occurrence keeps the bare slug — got \(html)")
        XCTAssertTrue(html.contains("<h2 id=\"setup-1\" data-source-line=\"2\">Setup</h2>"),
                      "second occurrence gets -1 suffix — got \(html)")
        XCTAssertTrue(html.contains("<h2 id=\"setup-2\" data-source-line=\"3\">Setup</h2>"),
                      "third occurrence gets -2 suffix — got \(html)")
    }

    func test_render_distinctHeadingsKeepCleanSlugs() {
        // Sanity: the dedupe machinery doesn't accidentally suffix
        // headings that are actually different.
        let md = """
        ## Alpha
        ## Beta
        ## Gamma
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("id=\"alpha\""))
        XCTAssertTrue(html.contains("id=\"beta\""))
        XCTAssertTrue(html.contains("id=\"gamma\""))
        XCTAssertFalse(html.contains("-1"),
                       "no suffix needed when titles are unique")
    }

    func test_render_punctuationOnlyHeadingFallsBackToSection() {
        // headingSlug returns "" for punctuation-only titles, but
        // the id attribute must never be empty (browsers + screen
        // readers are unhappy with `id=""`).
        let html = MarkdownConverter.render("## ???")
        XCTAssertTrue(html.contains("id=\"section\""),
                      "punctuation-only title must fall back to id=\"section\" — got \(html)")
    }

    func test_render_anchorLinkToHeadingProducesValidPair() {
        // End-to-end: anchor link + heading with the same slug
        // should render so that clicking the link in the preview
        // jumps to the heading. Both halves visible in HTML.
        let md = """
        [jump](#installation-steps)

        ## Installation Steps
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("href=\"#installation-steps\""),
                      "anchor link must keep the literal `#slug` — got \(html)")
        XCTAssertTrue(html.contains("<h2 id=\"installation-steps\" data-source-line=\"3\">"),
                      "heading must carry matching id — got \(html)")
    }

    func test_render_cjkHeadingProducesCJKSlug() {
        let html = MarkdownConverter.render("## 安装步骤")
        XCTAssertTrue(html.contains("id=\"安装步骤\""),
                      "CJK heading should keep CJK slug — got \(html)")
    }
}
