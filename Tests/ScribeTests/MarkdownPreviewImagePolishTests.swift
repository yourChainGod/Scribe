//
//  MarkdownPreviewImagePolishTests.swift
//  Phase 53e-1 — image pipeline polish. Three fronts:
//
//    1. Converter emits `loading="lazy"` + `decoding="async"` on
//       every `<img>` so off-screen thumbnails don't block first
//       paint and decoding stays off the main thread.
//    2. Preview shell ships a `img.scribe-img-broken` CSS rule
//       that draws a dashed red box around failed images so the
//       user sees exactly which image broke (without collapsing
//       to the default 0×0 placeholder).
//    3. `revealLineScript` attaches a capture-phase `error`
//       listener that stamps the class on any failing `<img>`.
//       `error` doesn't bubble, so the capture phase is load-
//       bearing — a non-capture listener would never fire.
//
//  The converter output checks are thin (existing baseline tests
//  already pin the exact string); this file focuses on the
//  preview-side CSS / JS wiring that would otherwise have no
//  coverage.
//

import XCTest
@testable import Scribe

final class MarkdownPreviewImagePolishTests: XCTestCase {

    // MARK: - Converter invariants (thin)

    func test_converter_imageHasLazyAndAsyncAttrs() {
        // The exact-string baseline is in MarkdownConverterTests;
        // here we just pin the two attrs so a deeper refactor
        // that keeps the `src`/`alt` order but drops lazy/async
        // still trips a focused failure.
        let html = MarkdownConverter.render("![pic](a.png)")
        XCTAssertTrue(html.contains("loading=\"lazy\""),
                      "images must lazy-load")
        XCTAssertTrue(html.contains("decoding=\"async\""),
                      "images must decode async")
    }

    // MARK: - Preview shell CSS

    func test_wrapCSSIncludesBrokenImageRule() {
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>x</p>")
        XCTAssertTrue(html.contains("img.scribe-img-broken"),
                      "shell CSS must carry the broken-image rule")
        XCTAssertTrue(html.contains("border: 1px dashed #cc3333"),
                      "broken-image rule must use a warning-red dashed border")
    }

    // MARK: - JS error listener

    func test_revealLineScript_hasCapturePhaseErrorListener() {
        // `error` events don't bubble; listening without capture
        // means a broken `<img>` deep in the DOM never reaches
        // our listener. Pin the `true` third arg.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("addEventListener('error'"),
                      "error delegation must exist")
        // The `true` third arg is the capture flag. Be tolerant
        // of surrounding whitespace / formatting changes but
        // pin the load-bearing literal.
        XCTAssertTrue(js.contains("}, true);"),
                      "listener must use capture phase (third arg true)")
    }

    func test_revealLineScript_errorListenerTargetsImagesOnly() {
        // Every WKWebView fires `error` for script / stylesheet
        // load failures too; we only want to stamp the broken-
        // image class on `<img>` elements.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("tagName !== 'IMG'")
                      || js.contains("tagName != 'IMG'"),
                      "listener must filter to IMG elements only")
    }

    func test_revealLineScript_errorListenerStampsScribeImgBroken() {
        // The class name is a contract between the JS listener
        // and the CSS rule. Keep them in lockstep.
        let js = MarkdownPreviewPane.revealLineScript()
        XCTAssertTrue(js.contains("scribe-img-broken"),
                      "listener must add the class that matches the CSS rule")
    }
}
