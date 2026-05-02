//
//  MarkdownPreviewHighlightTests.swift
//  Phase 51d — the preview ships highlight.js + GitHub light/dark
//  CSS inline in the shell so fenced code blocks render with colour
//  tokens. These tests pin the resource-loading contract so a
//  packaging regression (someone renames the files, SwiftPM stops
//  bundling them, etc.) surfaces as a red test before it reaches
//  the user.
//
//  We intentionally avoid spinning up a real WKWebView — that's
//  flaky inside XCTest and the interesting thing to verify is that
//  the strings we *hand* WebKit are sensible. If highlight.js's
//  source can be loaded through Bundle.module and the GitHub theme
//  CSS carries the tokens we'd expect, WebKit rendering the rest
//  is a given.
//

import XCTest
@testable import Scribe

final class MarkdownPreviewHighlightTests: XCTestCase {

    // MARK: - Resource presence

    func test_highlightJS_isBundled() {
        let asset = MarkdownPreviewPane.highlightJSAssetForTests
        XCTAssertFalse(asset.isEmpty,
                       "highlight.min.js must be inside the Scribe resources bundle; check Package.swift")
        // 11.9.0 minified is ~120 KB; anything under 10 KB means the
        // file is stub / placeholder / truncated.
        XCTAssertGreaterThan(asset.count, 10_000,
                             "highlight.min.js looks truncated — got \(asset.count) bytes")
    }

    func test_githubLightCSS_isBundled() {
        let css = MarkdownPreviewPane.githubLightCSSForTests
        XCTAssertFalse(css.isEmpty,
                       "github-light.min.css must be inside the Scribe resources bundle")
        XCTAssertTrue(css.contains(".hljs"),
                      "light theme must define .hljs selectors — got \(css.prefix(200))")
    }

    func test_githubDarkCSS_isBundled() {
        let css = MarkdownPreviewPane.githubDarkCSSForTests
        XCTAssertFalse(css.isEmpty,
                       "github-dark.min.css must be inside the Scribe resources bundle")
        XCTAssertTrue(css.contains(".hljs"),
                      "dark theme must define .hljs selectors — got \(css.prefix(200))")
    }

    // MARK: - Content sanity

    func test_highlightJS_exposesHljsGlobal() {
        // highlight.js's minified bundle references `hljs` throughout
        // its public surface. Its absence would mean we downloaded
        // a broken file (server error page, etc.).
        let asset = MarkdownPreviewPane.highlightJSAssetForTests
        XCTAssertTrue(asset.contains("hljs"),
                      "bundle must expose the hljs identifier — this looks like a broken / wrong bundle")
    }

    func test_githubLightCSS_carriesKeywordColour() {
        // Defensive check that the GitHub *light* theme was downloaded
        // (and not the dark one by accident). Light keywords are #d73a49
        // per github.com's public CSS; dark theme has #ff7b72.
        let css = MarkdownPreviewPane.githubLightCSSForTests
        XCTAssertTrue(css.contains("#d73a49"),
                      "light theme keyword colour missing — downloaded the wrong file?")
    }

    func test_githubDarkCSS_carriesKeywordColour() {
        let css = MarkdownPreviewPane.githubDarkCSSForTests
        XCTAssertTrue(css.contains("#ff7b72"),
                      "dark theme keyword colour missing — downloaded the wrong file?")
    }
}
