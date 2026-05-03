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

    // MARK: - KaTeX assets in the wrapped shell
    //
    // Phase 53e-4 — the shell now ships KaTeX inline from
    // `Bundle.module`. The CDN `<link>` / `<script defer>` are
    // a fallback when the bundle assets are missing (a build
    // misconfiguration); we test both branches by inspecting the
    // cached asset state.

    func test_wrapInjectsKatexCSS() {
        // Bundle assets present (the normal build) → inline
        // <style>; missing → CDN <link>. Either way the page
        // sources KaTeX CSS one way or another.
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>hi</p>")
        let bundled = !MarkdownPreviewPane.katexCSSAssetForTests.isEmpty
        if bundled {
            // Inline marker — `@font-face{font-family:KaTeX_AMS`
            // is a stable upstream prefix in katex.min.css that
            // we are unlikely to ever rewrite.
            XCTAssertTrue(html.contains("font-family:KaTeX_AMS"),
                          "bundled KaTeX CSS must be inlined into the shell")
        } else {
            XCTAssertTrue(html.contains("katex@0.16.21/dist/katex.min.css"),
                          "missing-bundle path must fall back to the CDN <link>")
        }
    }

    func test_wrapInjectsKatexJS() {
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>hi</p>")
        let bundled = !MarkdownPreviewPane.katexJSAssetForTests.isEmpty
        if bundled {
            // Stable upstream marker: KaTeX exposes `module.exports.
            // ParseError` from the IIFE bootstrap.
            XCTAssertTrue(html.contains("katex")
                          && html.contains("ParseError"),
                          "bundled KaTeX JS must be inlined into the shell")
        } else {
            XCTAssertTrue(html.contains("katex@0.16.21/dist/katex.min.js"),
                          "missing-bundle path must fall back to the CDN <script>")
            XCTAssertTrue(html.contains("<script defer"),
                          "CDN script must be deferred to avoid blocking first paint")
        }
    }

    func test_wrapBundlesKatexAssetsByDefault() {
        // Production builds with a complete Resources/ tree must
        // ship KaTeX inline — that's the whole point of 53e-4.
        // A failure here means SwiftPM didn't pick up the
        // Resources/MarkdownPreview/katex/ subtree.
        XCTAssertFalse(MarkdownPreviewPane.katexJSAssetForTests.isEmpty,
                       "katex.min.js must be bundled into the app")
        XCTAssertFalse(MarkdownPreviewPane.katexCSSAssetForTests.isEmpty,
                       "katex.min.css (with inlined fonts) must be bundled")
    }

    func test_wrapBundledKatexCSSCarriesInlinedFonts() {
        // The bundled CSS carries 20 woff2 fonts as base64
        // data: URLs so offline shells render full-fidelity
        // typeset math. Pinning the data: URL count here
        // catches a regression where the inlining script
        // stopped running pre-build.
        let css = MarkdownPreviewPane.katexCSSAssetForTests
        let count = css.components(separatedBy: "data:font/woff2;base64,").count - 1
        XCTAssertGreaterThanOrEqual(count, 20,
                                    "bundle CSS must inline ≥20 woff2 fonts; got \(count)")
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
