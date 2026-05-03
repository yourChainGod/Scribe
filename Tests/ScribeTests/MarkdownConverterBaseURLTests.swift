//
//  MarkdownConverterBaseURLTests.swift
//  Phase 51a — relative image / link sources resolve against the
//  markdown file's on-disk parent so WKWebView (which loads the
//  generated HTML with a nil baseURL) can actually find them. The
//  pre-fix preview shipped a permanent broken-image icon for any
//  README that referenced `./assets/x.png`.
//
//  These tests pin the resolver contract so the rewrite never
//  damages something that already worked (https / data URIs /
//  in-page anchors / absolute paths) and so the relative-path
//  rewrite is byte-faithful (no double-encoding, no path traversal
//  surprises through `..`).
//

import XCTest
@testable import Scribe

final class MarkdownConverterBaseURLTests: XCTestCase {

    private let docDir = URL(fileURLWithPath: "/tmp/scribe-md-fixture/docs/")

    // MARK: - Resolver helper, in isolation

    func test_resolver_keepsHTTPSAbsolute() {
        XCTAssertEqual(
            resolveResourceURL("https://example.test/x.png", baseDirectory: docDir),
            "https://example.test/x.png"
        )
    }

    func test_resolver_keepsDataURI() {
        let raw = "data:image/png;base64,iVBORw0KG"
        XCTAssertEqual(resolveResourceURL(raw, baseDirectory: docDir), raw)
    }

    func test_resolver_keepsMailtoAndTel() {
        XCTAssertEqual(resolveResourceURL("mailto:a@b.test", baseDirectory: docDir),
                       "mailto:a@b.test")
        XCTAssertEqual(resolveResourceURL("tel:+15551234", baseDirectory: docDir),
                       "tel:+15551234")
    }

    func test_resolver_keepsExistingFileURL() {
        XCTAssertEqual(
            resolveResourceURL("file:///opt/img.png", baseDirectory: docDir),
            "file:///opt/img.png"
        )
    }

    func test_resolver_keepsInPageAnchor() {
        XCTAssertEqual(resolveResourceURL("#section-one", baseDirectory: docDir),
                       "#section-one")
    }

    func test_resolver_keepsRawWhenNoBaseDirectory() {
        // Untitled buffers have no on-disk home; we must keep the
        // legacy raw behaviour rather than guess.
        XCTAssertEqual(resolveResourceURL("./assets/x.png", baseDirectory: nil),
                       "./assets/x.png")
    }

    func test_resolver_rewritesAbsolutePOSIXPath() {
        let out = resolveResourceURL("/var/img.png", baseDirectory: docDir)
        XCTAssertTrue(out.hasPrefix("file:///var/"),
                      "absolute POSIX path must wrap as file:// URL — got \(out)")
        XCTAssertTrue(out.hasSuffix("img.png"))
    }

    func test_resolver_rewritesDotSlashRelative() {
        let out = resolveResourceURL("./assets/logo.png", baseDirectory: docDir)
        XCTAssertEqual(out, "file:///tmp/scribe-md-fixture/docs/assets/logo.png")
    }

    func test_resolver_rewritesParentSlashRelative() {
        // `../shared/x.png` from /tmp/.../docs/ should resolve to
        // /tmp/.../shared/x.png — Foundation's standardizedFileURL
        // collapses the `..` component for us.
        let out = resolveResourceURL("../shared/x.png", baseDirectory: docDir)
        XCTAssertEqual(out, "file:///tmp/scribe-md-fixture/shared/x.png")
    }

    func test_resolver_rewritesBareRelative() {
        let out = resolveResourceURL("logo.png", baseDirectory: docDir)
        XCTAssertEqual(out, "file:///tmp/scribe-md-fixture/docs/logo.png")
    }

    // MARK: - End-to-end via render(_:baseDirectory:)

    func test_render_imageSrcRewrittenWhenBaseDirectorySet() {
        let html = MarkdownConverter.render("![logo](./logo.png)",
                                            baseDirectory: docDir)
        XCTAssertTrue(html.contains("src=\"file:///tmp/scribe-md-fixture/docs/logo.png\""),
                      "expected absolute file:// src — got \(html)")
        XCTAssertTrue(html.contains("alt=\"logo\""))
    }

    func test_render_linkHrefRewrittenWhenBaseDirectorySet() {
        // GitHub-style cross-doc link in a wiki / repo README.
        let html = MarkdownConverter.render("see [neighbour](./other.md)",
                                            baseDirectory: docDir)
        XCTAssertTrue(html.contains("href=\"file:///tmp/scribe-md-fixture/docs/other.md\""),
                      "relative link href must rewrite — got \(html)")
    }

    func test_render_anchorLinkLeftAlone() {
        let html = MarkdownConverter.render("[jump](#section)",
                                            baseDirectory: docDir)
        XCTAssertTrue(html.contains("href=\"#section\""),
                      "anchor links must NOT be rewritten — got \(html)")
    }

    func test_render_absoluteHTTPSImageLeftAlone() {
        let html = MarkdownConverter.render(
            "![cdn](https://cdn.example.test/i.png)",
            baseDirectory: docDir
        )
        XCTAssertTrue(html.contains("src=\"https://cdn.example.test/i.png\""),
                      "https image src must NOT be rewritten — got \(html)")
    }

    func test_render_nilBaseDirectoryPreservesLegacyOutput() {
        // Backward-compat: callers that don't supply a base directory
        // (existing tests, scratch buffers) get the exact pre-fix
        // string they used to.
        let html = MarkdownConverter.render("![logo](./logo.png)")
        XCTAssertEqual(html, "<p data-source-line=\"1\"><img src=\"./logo.png\" alt=\"logo\" loading=\"lazy\" decoding=\"async\"/></p>\n")
    }
}
