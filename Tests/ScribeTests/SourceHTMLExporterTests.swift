//
//  SourceHTMLExporterTests.swift
//  Phase 60 — pure-function tests for SourceHTMLExporter. We assert
//  the rendered HTML shape, the Lexilla-to-highlight.js slug map,
//  and the HTML-escape rules; the actual `NSSavePanel` round-trip
//  is a manual-QA path.
//

import XCTest
@testable import Scribe

@MainActor
final class SourceHTMLExporterTests: XCTestCase {

    // MARK: - Language slug map

    func test_highlightSlug_usesExactMatchForCpp() {
        XCTAssertEqual(SourceHTMLExporter.highlightSlug(forLexillaName: "cpp"), "cpp")
    }

    func test_highlightSlug_mapsShellAliasesToBash() {
        // Lexilla carries both "bash" and "shell"; highlight.js
        // registers one lexer under "bash" and aliases "shell" to
        // it. We collapse the pair at the boundary so the exported
        // `class="language-bash"` stays consistent.
        XCTAssertEqual(SourceHTMLExporter.highlightSlug(forLexillaName: "shell"), "bash")
        XCTAssertEqual(SourceHTMLExporter.highlightSlug(forLexillaName: "bash"), "bash")
    }

    func test_highlightSlug_collapsesHtmlFamilyToXml() {
        // highlight.js bundles "xml" and aliases html / plist
        // variants to it. Returning "xml" directly avoids any
        // chance of a dangling alias being resolved differently
        // across highlight.js versions.
        for alias in ["xml", "html", "hypertext"] {
            XCTAssertEqual(SourceHTMLExporter.highlightSlug(forLexillaName: alias),
                           "xml",
                           "alias \(alias) should collapse to xml")
        }
    }

    func test_highlightSlug_emptyAndNull_mapToPlaintext() {
        XCTAssertEqual(SourceHTMLExporter.highlightSlug(forLexillaName: ""), "plaintext")
        XCTAssertEqual(SourceHTMLExporter.highlightSlug(forLexillaName: "null"), "plaintext")
    }

    func test_highlightSlug_unknownPassThrough() {
        // Not in the map → forward verbatim. highlight.js quietly
        // renders unknown languages without colours, so users who
        // add a Lexilla override we don't map here still get a
        // usable (just uncoloured) export.
        XCTAssertEqual(SourceHTMLExporter.highlightSlug(forLexillaName: "some-future-lang"),
                       "some-future-lang")
    }

    // MARK: - HTML escape

    func test_htmlEscape_replacesAmpersandFirst() {
        // &  →  &amp;   (never &lt;amp;)
        XCTAssertEqual(SourceHTMLExporter.htmlEscape("&"), "&amp;")
        XCTAssertEqual(SourceHTMLExporter.htmlEscape("&&"), "&amp;&amp;")
        // Escape the entity a user pasted verbatim — we're not
        // trying to detect "already escaped" content because
        // source files legitimately contain literal entities.
        XCTAssertEqual(SourceHTMLExporter.htmlEscape("&amp;"), "&amp;amp;")
    }

    func test_htmlEscape_replacesAngleBracketsAndQuotes() {
        XCTAssertEqual(SourceHTMLExporter.htmlEscape("<div>"), "&lt;div&gt;")
        XCTAssertEqual(SourceHTMLExporter.htmlEscape("\"quoted\""), "&quot;quoted&quot;")
    }

    func test_htmlEscape_passesThroughOtherCharactersIncludingUnicode() {
        XCTAssertEqual(SourceHTMLExporter.htmlEscape("α → β"),
                       "α → β",
                       "non-special chars stay as-is; UTF-8 body is safe inside the meta charset")
        XCTAssertEqual(SourceHTMLExporter.htmlEscape("abc123"),
                       "abc123")
    }

    // MARK: - Rendered shape

    func test_renderHTML_producesDoctypeAndTitle() {
        let html = SourceHTMLExporter.renderHTML(
            text: "print(\"hi\")",
            title: "demo.swift",
            lexillaName: "swift",
            isDark: false
        )
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"),
                      "missing HTML5 doctype")
        XCTAssertTrue(html.contains("<title>demo.swift</title>"),
                      "title element should carry the filename")
    }

    func test_renderHTML_emitsLanguageClassOnCodeBlock() {
        let html = SourceHTMLExporter.renderHTML(
            text: "int main() { return 0; }",
            title: "hello.cpp",
            lexillaName: "cpp",
            isDark: false
        )
        XCTAssertTrue(html.contains("<code class=\"language-cpp hljs\">"),
                      "highlighted <code> missing or wrong language class")
    }

    func test_renderHTML_escapesAngleBracketsInBody() {
        // Critical — otherwise a source file containing `<html>` is
        // parsed as live markup and the user sees a rendered tag
        // instead of a colored string.
        let html = SourceHTMLExporter.renderHTML(
            text: "<html>",
            title: "t.html",
            lexillaName: "html",
            isDark: false
        )
        XCTAssertTrue(html.contains("&lt;html&gt;"),
                      "body must escape < and >; got:\n\(html)")
        XCTAssertFalse(html.contains("<html>\n</code>"),
                       "raw tag would have been interpreted by the outer HTML parser")
    }

    func test_renderHTML_darkThemeUsesDarkBackground() {
        // We pick GitHub dark vs light via the `isDark` flag. The
        // body background colour is the easiest stable tell — both
        // themes ship a distinctive hex.
        let dark = SourceHTMLExporter.renderHTML(text: "x",
                                                 title: "d",
                                                 lexillaName: "plain",
                                                 isDark: true)
        XCTAssertTrue(dark.contains("#0d1117"),
                      "dark export should paint GitHub-dark background")
        let light = SourceHTMLExporter.renderHTML(text: "x",
                                                  title: "l",
                                                  lexillaName: "plain",
                                                  isDark: false)
        XCTAssertTrue(light.contains("#ffffff"),
                      "light export should paint white background")
    }

    func test_renderHTML_emptyTitleFallsBackToLocalizedDefault() {
        // The window-bar H1 should never read as blank; an empty
        // title (Untitled buffer with no url) slots in the
        // localized "Source export" placeholder.
        let html = SourceHTMLExporter.renderHTML(text: "x",
                                                 title: "",
                                                 lexillaName: "plain",
                                                 isDark: false)
        let expected = L10n.t("export.html.defaultTitle")
        XCTAssertTrue(html.contains("<title>\(expected)</title>"),
                      "empty title should fall back to the localized placeholder")
    }

    func test_renderHTML_inlinesHighlightJS() {
        // The exported file must be offline-usable; the hljs bundle
        // is inlined in the trailing <script>. We don't want to pin
        // the full contents (that'd be a 120 KB literal in the test),
        // but the boot call downstream is a stable signature.
        let html = SourceHTMLExporter.renderHTML(text: "x",
                                                 title: "t",
                                                 lexillaName: "plain",
                                                 isDark: false)
        XCTAssertTrue(html.contains("hljs.highlightElement"),
                      "exported HTML should invoke hljs.highlightElement to colour the block")
    }

    // MARK: - Palette registration

    func test_palette_registersExportHTMLCommand() {
        let suite = "scribe-export-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "scratch.txt", text: "")
        workspace.documents = [doc]
        workspace.selectedID = doc.id

        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)
        let cmd = registry.commands.first { $0.id == "file.exportHTML" }
        XCTAssertNotNil(cmd, "file.exportHTML must be registered")
    }
}
