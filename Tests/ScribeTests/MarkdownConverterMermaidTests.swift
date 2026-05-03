//
//  MarkdownConverterMermaidTests.swift
//  Phase 53d — Mermaid fence output. The converter has to swap
//  the usual `<pre><code class="language-mermaid">` emission for
//  a `<div class="mermaid">` so the preview's JS Mermaid runtime
//  picks it up, while keeping every other language fence intact.
//
//  Regression surface:
//    - ```mermaid fence produces the correct div shape.
//    - Regular ```swift / ```python / untagged ``` fences are
//      unaffected.
//    - Fence body survives verbatim (LaTeX-style `->`, `|`, `*`
//      in sequence diagrams must not hit the markdown regex
//      chain).
//    - Dangling mermaid fence at EOF still closes with </div>.
//    - Source-line stamp lands on the opening fence line.
//    - Language hint is case-insensitive (GitHub also accepts
//      `Mermaid` / `MERMAID`).
//

import XCTest
@testable import Scribe

final class MarkdownConverterMermaidTests: XCTestCase {

    // MARK: - Happy path

    func testMermaidFenceEmitsDiv() {
        let md = """
        ```mermaid
        graph TD
        A-->B
        ```
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<div class=\"mermaid\" data-source-line=\"1\">"),
                      "mermaid fence must open a <div class=\"mermaid\">")
        XCTAssertTrue(html.contains("graph TD"),
                      "fence body must survive to the div")
        XCTAssertTrue(html.contains("A--&gt;B") || html.contains("A-->B"),
                      "arrows inside fence must reach the div")
        XCTAssertTrue(html.contains("</div>"),
                      "fence must close with </div>")
        XCTAssertFalse(html.contains("<pre><code class=\"language-mermaid\">"),
                       "must not fall through to the generic fenced-code path")
    }

    func testMermaidLanguageIsCaseInsensitive() {
        // GitHub renders ```Mermaid the same as ```mermaid; so do
        // we. Pinning both so a future refactor that normalises
        // one way can't silently drop the other.
        let variants = ["Mermaid", "MERMAID", "MerMaid"]
        for v in variants {
            let md = "```\(v)\ngraph TD\nA-->B\n```"
            let html = MarkdownConverter.render(md)
            XCTAssertTrue(html.contains("<div class=\"mermaid\""),
                          "\(v) must open a mermaid div (case-insensitive)")
        }
    }

    // MARK: - Regular fences unaffected

    func testRegularLanguageFenceStaysPreCode() {
        // The mermaid branch must not leak into ```swift / ```py
        // / ```js / etc. Pin the existing hljs-friendly path.
        let md = "```swift\nlet x = 1\n```"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<pre data-source-line=\"1\"><code class=\"language-swift\">"),
                      "non-mermaid language fences must still emit <pre><code>")
        XCTAssertFalse(html.contains("<div class=\"mermaid\""),
                       "swift fence must not get the mermaid div")
    }

    func testUntaggedFenceStaysPreCode() {
        let md = "```\nbare code\n```"
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<pre data-source-line=\"1\"><code>"),
                      "untagged fence must still be <pre><code>")
    }

    // MARK: - Body preservation

    func testMermaidFenceBodyNotParsedAsMarkdown() {
        // Sequence diagrams lean on `*`, `|`, `>` heavily. If the
        // fence leaks into the markdown pipeline, all three get
        // reinterpreted and the diagram breaks.
        let md = """
        ```mermaid
        sequenceDiagram
        Alice->>Bob: *Hi*
        Bob-->>Alice: Hi!
        ```
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("Alice-&gt;&gt;Bob: *Hi*")
                      || html.contains("Alice->>Bob: *Hi*"),
                      "asterisks inside fence must not become <em>")
        XCTAssertFalse(html.contains("<em>Hi</em>"),
                       "emphasis must not reach inside the mermaid fence")
    }

    // MARK: - Source-line stamp

    func testMermaidDivSourceLineIsOpeningFenceLine() {
        // Same contract as every other block-level element: the
        // data-source-line attr points at the opening marker so
        // the scroll-sync reveal helper can land on it.
        let md = """
        Intro text.

        ```mermaid
        graph TD
        A-->B
        ```

        Outro text.
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<div class=\"mermaid\" data-source-line=\"3\">"),
                      "data-source-line must stamp the opening ```mermaid line")
    }

    // MARK: - Unclosed fence

    func testUnclosedMermaidFenceStillEmitsDiv() {
        // Mirror of the display-math fence behaviour: an
        // unterminated fence at EOF still closes the wrapper so
        // the user's source is visible (Mermaid .catch will leave
        // the raw text on failed parse).
        let md = """
        ```mermaid
        graph TD
        A-->B
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<div class=\"mermaid\""),
                      "unclosed fence must still emit a div")
        XCTAssertTrue(html.contains("</div>"),
                      "flushAll must close the dangling </div>")
        XCTAssertFalse(html.contains("</code></pre>"),
                       "unclosed mermaid fence must not close as code")
    }

    // MARK: - Interaction with adjacent fences

    func testMermaidAndCodeFencesCoexist() {
        // A doc with both a mermaid diagram and a regular code
        // block must render both correctly — no state leaking
        // from one fence into the next.
        let md = """
        ```mermaid
        graph TD
        A-->B
        ```

        ```swift
        let x = 1
        ```
        """
        let html = MarkdownConverter.render(md)
        XCTAssertTrue(html.contains("<div class=\"mermaid\""))
        XCTAssertTrue(html.contains("<pre data-source-line=\"6\"><code class=\"language-swift\">"))
    }
}
