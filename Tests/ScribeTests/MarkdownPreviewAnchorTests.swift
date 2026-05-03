//
//  MarkdownPreviewAnchorTests.swift
//  Post-51e bug fix — pin the predicate that decides whether a
//  `linkActivated` navigation is an intra-document anchor jump
//  (stay in the preview, let WebKit scroll) or a real external
//  URL (pop out to NSWorkspace).
//
//  The bug: Foundation treats `about:` as an opaque URI, so
//  `URL(string: "about:blank#slug").fragment` is nil and the `#`
//  round-trips as `%23`. The previous heuristic relied on
//  `fragment != nil`, which meant every TOC click fell through to
//  `NSWorkspace.open`, firing "no app to open about:blank#…".
//
//  These tests lock the replacement predicate down on the actual
//  URL shapes WebKit hands us — including the opaque `about:blank`
//  form we see today.
//

import XCTest
@testable import Scribe

final class MarkdownPreviewAnchorTests: XCTestCase {

    // The predicate lives on the navigation-delegate coordinator;
    // reaching it through a fresh WKNavigationDelegate instance
    // keeps the tests independent of the outer SwiftUI view.
    private let sut = MarkdownPreviewPane.Coordinator.self

    // MARK: - the fix: about:blank#<fragment>

    func test_aboutBlankWithPercentEncodedFragment_isSameDocument() {
        // Exactly the URL the user reported: Chinese slug, `#`
        // percent-encoded because Foundation won't split `about:`
        // into scheme + fragment.
        let href = "about:blank%23%E6%97%A0%E8%AF%AD%E8%A8%80%E6%8F%90%E7%A4%BA"
        let target = URL(string: href)!
        let current = URL(string: "about:blank")!
        XCTAssertTrue(sut.isSameDocumentAnchor(target: target,
                                               current: current))
    }

    func test_aboutBlankWithAsciiFragment_isSameDocument() {
        // ASCII slug round-trips through Foundation as a literal `#`.
        let target = URL(string: "about:blank#intro")!
        let current = URL(string: "about:blank")!
        XCTAssertTrue(sut.isSameDocumentAnchor(target: target,
                                               current: current))
    }

    func test_aboutBlankToSelf_isSameDocument() {
        // Identical URL (no fragment on either side) still counts —
        // WebKit will treat it as a no-op scroll, which is fine.
        let url = URL(string: "about:blank")!
        XCTAssertTrue(sut.isSameDocumentAnchor(target: url, current: url))
    }

    // MARK: - external links still fall through to NSWorkspace

    func test_httpsLink_isNotSameDocument() {
        let target = URL(string: "https://example.com/path")!
        let current = URL(string: "about:blank")!
        XCTAssertFalse(sut.isSameDocumentAnchor(target: target,
                                                current: current))
    }

    func test_mailtoLink_isNotSameDocument() {
        let target = URL(string: "mailto:someone@example.com")!
        let current = URL(string: "about:blank")!
        XCTAssertFalse(sut.isSameDocumentAnchor(target: target,
                                                current: current))
    }

    func test_fileSchemeLink_isNotSameDocument() {
        // A `[other](./other.md)` link under a real baseURL resolves
        // to `file:///…/other.md` — different file, must escape.
        let target = URL(string: "file:///tmp/other.md")!
        let current = URL(string: "about:blank")!
        XCTAssertFalse(sut.isSameDocumentAnchor(target: target,
                                                current: current))
    }

    // MARK: - future-proofing: real baseURL support

    func test_fileBaseURL_sameFileDifferentFragment_isSameDocument() {
        // If we ever give the preview a real file:// baseURL,
        // in-doc anchors should still count as same-document.
        let target = URL(string: "file:///tmp/readme.md#heading")!
        let current = URL(string: "file:///tmp/readme.md")!
        XCTAssertTrue(sut.isSameDocumentAnchor(target: target,
                                               current: current))
    }

    func test_fileBaseURL_differentFile_isNotSameDocument() {
        let target = URL(string: "file:///tmp/other.md")!
        let current = URL(string: "file:///tmp/readme.md")!
        XCTAssertFalse(sut.isSameDocumentAnchor(target: target,
                                                current: current))
    }

    // MARK: - degenerate inputs

    func test_nilCurrentURL_isNotSameDocument() {
        // Before the first didFinish, webView.url can be nil. In
        // that window a link activation can only be external.
        let target = URL(string: "about:blank#anything")!
        XCTAssertFalse(sut.isSameDocumentAnchor(target: target,
                                                current: nil))
    }
}
