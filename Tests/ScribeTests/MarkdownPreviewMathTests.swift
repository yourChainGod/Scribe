//
//  MarkdownPreviewMathTests.swift
//  Phase 53c — preview-side KaTeX wiring. Three structural fronts:
//
//    1. The shell injects KaTeX from CDN with a stable, pinned
//       version + crossorigin attribute (so multiple WKWebViews
//       share the cache).
//    2. `revealLineScript` exports `scribeRenderMath` with the
//       right katex.render options (displayMode handling per
//       span type, throwOnError off, errorColor amber-red so
//       broken LaTeX is visible without crashing the page).
//    3. The load handler + the JS-injection fast path both call
//       `scribeRenderMath` so a fresh full reload *and* a typed-
//       in math span both render.
//
//  Live `katex.render` exercise needs a WKWebView; we leave that
//  to manual demo. The structural invariants pinned here lock the
//  Swift-side wiring against silent drift.
//

import XCTest
@testable import Scribe

final class MarkdownPreviewMathTests: XCTestCase {

    // MARK: - CDN injection in the wrapped shell

    func test_wrapInjectsKatexCSSLink() {
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>hi</p>")
        XCTAssertTrue(html.contains("rel=\"stylesheet\""),
                      "shell must include a stylesheet link tag")
        XCTAssertTrue(html.contains("katex@0.16.21/dist/katex.min.css"),
                      "stylesheet must point at the pinned KaTeX CSS")
    }

    func test_wrapInjectsKatexJSScript() {
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>hi</p>")
        XCTAssertTrue(html.contains("katex@0.16.21/dist/katex.min.js"),
                      "shell must include the pinned KaTeX JS")
        XCTAssertTrue(html.contains("crossorigin=\"anonymous\""),
                      "crossorigin attr lets the browser cache the CDN copy")
    }

    func test_wrapDeferKatexJSToAvoidBlockingFirstPaint() {
        // `defer` keeps katex.min.js out of the critical render
        // path; the load handler waits for `window.load` so by
        // the time `scribeRenderMath` runs, the script has
        // executed. Pinning the attribute means a future refactor
        // that drops it will trip a test, not silently regress
        // first-paint times.
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>hi</p>")
        XCTAssertTrue(html.contains("<script defer"),
                      "KaTeX script must be deferred so it doesn't block rendering")
    }

    func test_wrapLoadHandlerCallsScribeRenderMath() {
        // The page-load `<script>` block has to call
        // `scribeRenderMath()` after hljs runs, otherwise math
        // spans on the very first paint render as raw `$x$` until
        // the user types something to trigger the injection path.
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>hi</p>")
        XCTAssertTrue(html.contains("scribeRenderMath()"),
                      "load handler must invoke scribeRenderMath")
    }

    // MARK: - revealLineScript: scribeRenderMath function shape

    func test_revealLineScript_exportsScribeRenderMath() {
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("window.scribeRenderMath"),
                      "scribeRenderMath must be exported on window")
    }

    func test_scribeRenderMath_handlesInlineSpans() {
        // The function has to query both `.math-inline` and
        // `.math-display` — missing either shape would silently
        // leave half the document's math un-rendered.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains(".math-inline"),
                      "must process .math-inline spans")
        XCTAssertTrue(js.contains(".math-display"),
                      "must process .math-display elements")
    }

    func test_scribeRenderMath_usesDisplayModeFlagPerShape() {
        // `displayMode: false` for inline, `displayMode: true` for
        // display — the rendered output is visually different
        // (display math is centered, larger, with vertical
        // padding). Pin both literals.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("displayMode: false"),
                      "inline path must pass displayMode: false")
        XCTAssertTrue(js.contains("displayMode: true"),
                      "display path must pass displayMode: true")
    }

    func test_scribeRenderMath_disablesThrowOnError() {
        // KaTeX throws `ParseError` on invalid LaTeX by default.
        // We want the renderer to fall back to red-tinted source
        // so the user sees what's wrong instead of a blank gap.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("throwOnError: false"),
                      "renderer must not throw on bad LaTeX")
        XCTAssertTrue(js.contains("errorColor"),
                      "errorColor styles the fallback so users notice broken math")
    }

    func test_scribeRenderMath_guardsMissingKatex() {
        // Offline / first-paint-before-script-loaded scenarios
        // must not throw — `if (!window.katex) return;` is the
        // load-bearing guard.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("!window.katex"),
                      "scribeRenderMath must guard against missing katex global")
    }
}
