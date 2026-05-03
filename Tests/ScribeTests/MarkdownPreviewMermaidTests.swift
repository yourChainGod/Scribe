//
//  MarkdownPreviewMermaidTests.swift
//  Phase 53d — preview-side Mermaid wiring. Structural invariants:
//
//    1. `wrap(...)` injects Mermaid's CDN script.
//    2. `mermaid.initialize` runs with `startOnLoad: false`
//       (otherwise the auto-scan fights with our manual
//       `scribeRenderMermaid` calls during incremental swaps).
//    3. Theme passed to Mermaid tracks the preview's isDark.
//    4. `scribeRenderMermaid` exists, targets
//       `.mermaid:not([data-mermaid-rendered])` so it stays
//       idempotent, and uses the Promise-based v10 API.
//    5. Both the load handler and the JS-injection fast path
//       call `scribeRenderMermaid` so a typed-in diagram renders
//       without waiting for a full reload.
//

import XCTest
@testable import Scribe

final class MarkdownPreviewMermaidTests: XCTestCase {

    // MARK: - Wrapped shell injection

    func test_wrapInjectsMermaidScript() {
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>hi</p>")
        XCTAssertTrue(html.contains("mermaid@10.9.3/dist/mermaid.min.js"),
                      "shell must include pinned Mermaid runtime")
    }

    func test_wrapCallsMermaidInitializeWithoutAutoStart() {
        // `startOnLoad: false` is load-bearing: our
        // `scribeRenderMermaid` drives rendering, so letting the
        // library auto-scan would produce two concurrent renders
        // on the same `<div>` — which races and breaks the SVG.
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>hi</p>")
        XCTAssertTrue(html.contains("mermaid.initialize"),
                      "mermaid.initialize must be called in the shell")
        XCTAssertTrue(html.contains("startOnLoad: false"),
                      "auto-start must be disabled")
    }

    func test_wrapMermaidThemeFollowsIsDark() {
        // Dark preview → Mermaid 'dark' theme; light preview →
        // 'default'. The theme affects node fill colours that
        // would otherwise clash with the surrounding dark bg.
        let dark = MarkdownPreviewPane.wrapForTests(body: "<p>x</p>", isDark: true)
        XCTAssertTrue(dark.contains("theme: 'dark'"),
                      "dark preview must pass theme: 'dark' to mermaid")

        let light = MarkdownPreviewPane.wrapForTests(body: "<p>x</p>", isDark: false)
        XCTAssertTrue(light.contains("theme: 'default'"),
                      "light preview must pass theme: 'default'")
    }

    func test_wrapMermaidUsesStrictSecurityLevel() {
        // `securityLevel: 'strict'` blocks raw HTML / script
        // injection from user diagrams. We control the input
        // (markdown fenced block), but the WKWebView renders
        // untrusted content (arbitrary user docs), so defence
        // in depth matters.
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>x</p>")
        XCTAssertTrue(html.contains("securityLevel: 'strict'"),
                      "mermaid must run at securityLevel: 'strict'")
    }

    // MARK: - scribeRenderMermaid shape

    func test_revealLineScriptExportsScribeRenderMermaid() {
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("window.scribeRenderMermaid"),
                      "scribeRenderMermaid must be exported on window")
    }

    func test_scribeRenderMermaidTargetsUnrenderedDivs() {
        // Idempotency hinges on the `:not([data-mermaid-rendered])`
        // selector. Without it, every keystroke that triggers an
        // innerHTML swap would re-render every diagram, which is
        // slow and resets SVG zoom / pan state.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains(".mermaid:not([data-mermaid-rendered])"),
                      "rendered blocks must be skipped on subsequent calls")
        XCTAssertTrue(js.contains("data-mermaid-rendered"),
                      "render success must stamp the done marker")
    }

    func test_scribeRenderMermaidUsesV10PromiseAPI() {
        // Mermaid v10's `render` returns `{svg, bindFunctions}`.
        // We bind `.then` to unpack the svg and `.catch` for the
        // failure fallback.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("mermaid.render"),
                      "must use mermaid.render API")
        XCTAssertTrue(js.contains(".then(function"),
                      "must handle the Promise with .then")
        XCTAssertTrue(js.contains(".catch(function"),
                      "must handle rejection with .catch (fail-soft)")
        XCTAssertTrue(js.contains("result.svg"),
                      "must unpack the SVG from the render result")
    }

    func test_scribeRenderMermaidGuardsMissingRuntime() {
        // Offline / first-paint scenarios must no-op instead of
        // throwing, otherwise the rest of the inject path
        // (scribeBuildBlockIndex, scribeRenderMath) stops running.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("!window.mermaid"),
                      "renderer must guard on window.mermaid")
    }

    // MARK: - Load + inject hooks

    func test_loadHandlerCallsScribeRenderMermaid() {
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>x</p>")
        XCTAssertTrue(html.contains("scribeRenderMermaid()"),
                      "load handler must call scribeRenderMermaid")
    }
}
