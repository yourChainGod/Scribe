//
//  MarkdownPreviewUserCSSTests.swift
//  Phase 53e-3 — `~/.scribe/preview.css` user override hook. Two
//  surfaces under test:
//
//    1. `loadUserPreviewCSS(homeDirectory:)` — the file reader.
//       Must succeed on a present file, swallow every flavour of
//       failure (missing file, unreadable dir, garbage path)
//       into an empty string so the preview can never fail to
//       render because of a user's optional theme tweak.
//    2. `wrap(...)` — must inline the user CSS *after* every
//       built-in stylesheet so the cascade lets user rules win
//       on a tie without `!important`.
//

import XCTest
@testable import Scribe

final class MarkdownPreviewUserCSSTests: XCTestCase {

    // MARK: - loadUserPreviewCSS

    /// Build a temporary "home directory" with the given
    /// preview.css content (or no `.scribe` folder at all if
    /// `content` is nil). Caller is responsible for cleanup.
    private func makeHome(withCSS content: String?) throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("scribe-css-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        if let content = content {
            let scribeDir = tmp.appendingPathComponent(".scribe",
                                                       isDirectory: true)
            try fm.createDirectory(at: scribeDir, withIntermediateDirectories: true)
            let cssPath = scribeDir.appendingPathComponent("preview.css")
            try content.write(to: cssPath, atomically: true, encoding: .utf8)
        }
        return tmp
    }

    func test_loadUserPreviewCSS_returnsContents_whenFileExists() throws {
        let css = "body { background: hotpink; }"
        let home = try makeHome(withCSS: css)
        defer { try? FileManager.default.removeItem(at: home) }

        let loaded = MarkdownPreviewPane.loadUserPreviewCSS(homeDirectory: home)
        XCTAssertEqual(loaded, css,
                       "loader must return the file contents verbatim")
    }

    func test_loadUserPreviewCSS_returnsEmpty_whenScribeDirAbsent() throws {
        // No `.scribe` folder at all — the most common case for
        // a user who hasn't customised anything.
        let home = try makeHome(withCSS: nil)
        defer { try? FileManager.default.removeItem(at: home) }

        let loaded = MarkdownPreviewPane.loadUserPreviewCSS(homeDirectory: home)
        XCTAssertEqual(loaded, "",
                       "missing file must yield empty string, not crash")
    }

    func test_loadUserPreviewCSS_returnsEmpty_whenCSSFileAbsent() throws {
        // `.scribe/` exists but `preview.css` doesn't (e.g.,
        // user has other config files there).
        let home = try makeHome(withCSS: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let scribeDir = home.appendingPathComponent(".scribe",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scribeDir,
                                                withIntermediateDirectories: true)

        let loaded = MarkdownPreviewPane.loadUserPreviewCSS(homeDirectory: home)
        XCTAssertEqual(loaded, "",
                       "missing preview.css must still yield empty string")
    }

    func test_loadUserPreviewCSS_handlesUnicode() throws {
        // CSS files routinely contain non-ASCII content in
        // `content:` rules and font-family names. UTF-8 decode
        // must round-trip cleanly.
        let css = "/* 主题 */\nh1::before { content: \"§ \"; }"
        let home = try makeHome(withCSS: css)
        defer { try? FileManager.default.removeItem(at: home) }

        let loaded = MarkdownPreviewPane.loadUserPreviewCSS(homeDirectory: home)
        XCTAssertEqual(loaded, css,
                       "UTF-8 contents must round-trip without mangling")
    }

    // MARK: - wrap injection

    func test_wrap_inlinesUserCSSWhenProvided() {
        let userCSS = "body { font-family: \"Inter\", sans-serif; }"
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>x</p>",
                                                    userCSS: userCSS)
        XCTAssertTrue(html.contains(userCSS),
                      "user CSS must appear verbatim inside the shell")
    }

    func test_wrap_userCSSAppearsAfterBuiltInStyles() {
        // The cascade lets the user's rules override built-ins
        // when specificity is equal *and* user comes later in the
        // document. So we need the user `<style>` block to come
        // after `body { font: ... }` (which lives in the
        // top-of-head `<style>`).
        let userCSS = "MARKER_USER_STYLES_HERE"
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>x</p>",
                                                    userCSS: userCSS)
        guard let userIdx = html.range(of: userCSS)?.lowerBound,
              let bodyFontIdx = html.range(of: "font: 14px/1.6")?.lowerBound
        else {
            XCTFail("expected markers not found in shell HTML")
            return
        }
        XCTAssertTrue(userIdx > bodyFontIdx,
                      "user CSS must come AFTER built-in body font rule")
    }

    func test_wrap_emptyUserCSSIsHarmless() {
        // The default case — user hasn't dropped a preview.css.
        // The shell must still produce valid HTML that loads and
        // renders the body.
        let html = MarkdownPreviewPane.wrapForTests(body: "<p>hello</p>")
        XCTAssertTrue(html.contains("<p>hello</p>"),
                      "body must still reach the shell when user CSS is empty")
        // The empty <style></style> tag is fine; just pin the
        // shape so a future refactor that drops the slot tripsa
        // a focused test instead of silently regressing the
        // injection point.
        XCTAssertTrue(html.contains("<style></style>")
                      || html.contains("<style>\n</style>")
                      || html.contains("<style> </style>"),
                      "empty user CSS slot must still render an inert <style> tag")
    }
}
