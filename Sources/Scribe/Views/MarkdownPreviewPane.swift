//
//  MarkdownPreviewPane.swift
//  Phase 30 — live HTML preview of the active Markdown document.
//
//  We host a WKWebView (NSViewRepresentable) and feed it the output of
//  MarkdownConverter.render every time the document text changes.
//  The view side is intentionally tiny:
//    - WKWebView ships with selectable text + smooth scrolling for free
//    - prefers-color-scheme media queries cover light/dark switch
//    - link clicks are intercepted so they open in the user's default
//      browser instead of navigating the preview away from the doc
//
//  Phase 51b — incremental update path. Pre-fix every keystroke ran
//  `loadHTMLString` which fully reloads the WebKit document: the
//  whole page flashes white for ~2–3 frames and scrollY resets to 0
//  before an inline `<script>` restores it, producing a visible jolt
//  on every typed character. The converter itself is cheap (<10 ms
//  for a 30 KB README); the cost was WebKit's layout + paint tear-
//  down-and-rebuild.
//
//  We now keep the shell loaded exactly once and diff the body in
//  via `evaluateJavaScript(document.getElementById('md-root').innerHTML = …)`.
//  Scroll position is preserved as a side effect — WebKit doesn't
//  touch scrollY when only a subtree's innerHTML changes — so the
//  user's viewport stays put while they type. Theme flips still
//  trigger a full reload (CSS must be regenerated), and any JS
//  failure falls back to the full-reload path so we can never strand
//  a stale preview on-screen.
//

import SwiftUI
@preconcurrency import WebKit

// MARK: - Phase 51d · highlight.js asset loading
//
// Code-block syntax colouring lives entirely in the WKWebView. We
// ship highlight.js (v11.9.0, ~120 KB minified, ~30 common languages)
// + the GitHub light and dark themes inside `Bundle.module` and
// inline them into the preview shell at first-load time. The bundle
// is read once per process via `lazy static let` so every additional
// preview pane reuses the same string copies — the cost shows up as
// one ~120 KB UTF-8 string on the heap, not three.
//
// Languages we don't list explicitly (CommonMark fenced code with no
// hint, or a tag highlight.js doesn't recognise) fall back to the
// pre-existing CSS-only chrome (border, padding, codeBg fill) so the
// block still reads cleanly even without colour tokens.

/// Cached highlight.js minified bundle. Loaded once via Bundle.module
/// the first time anybody touches the property; the empty-string
/// fallback means a missing-asset build still renders preview text,
/// just without colour tokens.
private let highlightJSAsset: String = {
    guard let url = Bundle.module.url(forResource: "highlight.min",
                                      withExtension: "js"),
          let s = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return s
}()

/// Cached GitHub light theme CSS for highlight.js.
private let githubLightCSS: String = {
    guard let url = Bundle.module.url(forResource: "github-light.min",
                                      withExtension: "css"),
          let s = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return s
}()

/// Cached GitHub dark theme CSS for highlight.js.
private let githubDarkCSS: String = {
    guard let url = Bundle.module.url(forResource: "github-dark.min",
                                      withExtension: "css"),
          let s = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return s
}()

struct MarkdownPreviewPane: NSViewRepresentable {
    /// The raw markdown source. The pane re-renders when this changes;
    /// SymbolOutline-style debouncing happens upstream in WorkspaceView
    /// so we don't double-throttle.
    let markdown: String
    /// Light vs dark — comes from `@Environment(\.colorScheme)` on the
    /// SwiftUI side and gets folded into the inline CSS so the preview
    /// matches the editor theme even when `prefers-color-scheme` would
    /// disagree (e.g. user picked Solarized Light on a dark system).
    let isDark: Bool
    /// Phase 51a — on-disk parent of the markdown file. Threaded into
    /// `MarkdownConverter.render` so relative `![](rel/img.png)` and
    /// `[other](./other.md)` references resolve to absolute `file:///`
    /// URLs that WKWebView can actually load. Untitled / scratch
    /// markdown buffers pass `nil` and keep the legacy raw-src
    /// behaviour (broken-image icon if they reference a relative
    /// path — but those buffers don't live on disk anyway, so there's
    /// nothing to resolve).
    let baseDirectory: URL?
    /// Phase 51e — 1-based caret line, fed by `Document.cursorLine`.
    /// When this changes between updateNSView ticks we run a small JS
    /// helper inside the preview that picks the block whose source
    /// line is the largest one ≤ caret and scrolls it into view. Kept
    /// optional so non-document contexts (preview tests, scratch
    /// renders) can opt out by passing nil — the preview just won't
    /// follow caret moves in that case.
    var cursorLine: Int? = nil
    /// Phase 52b — 1-based top-of-viewport line, fed by
    /// `Document.viewportTopLine`. Written by ScintillaCodeEditor
    /// whenever the V_SCROLL bit fires on SCN_UPDATEUI. Takes
    /// precedence over `cursorLine` in the reveal helper because a
    /// scroll drag is a more direct user intent than an implicit
    /// caret move that happens during typing. Optional for the same
    /// reason as `cursorLine`.
    var viewportLine: Int? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Phase 51d · test seams
    //
    // The three cached asset constants live at file scope (outside
    // the type) so the lazy-load pattern stays cheap for production
    // code. XCTest needs to reach them to assert the resource bundle
    // shipped them correctly; rather than promoting the globals to
    // internal (which would leak two raw strings into code-complete
    // on every `MarkdownPreviewPane` callsite), we expose narrow,
    // explicitly-named computed accessors only the test target uses.
    // They return the same cached strings the production shell
    // inlines, so a test passing here means production sees the
    // same bytes.
    static var highlightJSAssetForTests: String { highlightJSAsset }
    static var githubLightCSSForTests: String { githubLightCSS }
    static var githubDarkCSSForTests: String { githubDarkCSS }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.navigationDelegate = context.coordinator
        // Translucent: lets the SwiftUI parent (which owns light/dark
        // theming) bleed through if our HTML is shorter than the pane.
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        loadHTML(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coord = context.coordinator
        // Phase 51e / 52b — caret- or scroll-only changes (markdown
        // unchanged, theme unchanged) take a third, even cheaper
        // path: just fire the reveal-line JS helper. No re-render,
        // no innerHTML swap. Guarded behind hasInitialLoad so we
        // don't try to call into a window that hasn't loaded the
        // helper yet — the next full reload will publish it and the
        // caret / scroll reveal will catch up on the subsequent tick.
        if coord.cachedMarkdown == markdown,
           coord.cachedIsDark == isDark {
            guard coord.hasInitialLoad else { return }
            let action = Self.decideReveal(cursorLine: cursorLine,
                                           viewportLine: viewportLine,
                                           lastCursor: coord.lastCursorLine,
                                           lastViewport: coord.lastViewportLine)
            switch action {
            case .none:
                break
            case .viewport(let vp):
                coord.lastViewportLine = vp
                // Stamp the caret mirror too so a later tick where
                // cursorLine changed *back* to the pre-scroll value
                // doesn't immediately yank the preview away from
                // where the user scrolled it.
                if let line = cursorLine { coord.lastCursorLine = line }
                view.evaluateJavaScript("window.scribeRevealLine && scribeRevealLine(\(vp));",
                                        completionHandler: nil)
            case .cursor(let line):
                coord.lastCursorLine = line
                view.evaluateJavaScript("window.scribeRevealLine && scribeRevealLine(\(line));",
                                        completionHandler: nil)
            }
            return
        }
        loadHTML(into: view, coordinator: coord)
    }

    /// Phase 52b — pure decision helper for the reveal fast path.
    ///
    /// Picks between three possible actions on every re-render where
    /// markdown + theme are unchanged:
    ///
    ///   - `.none`      – neither signal moved since last tick; the
    ///                    preview stays put.
    ///   - `.viewport(line)` – the editor's viewport-top line moved;
    ///                        explicit user scroll intent, wins over
    ///                        caret.
    ///   - `.cursor(line)`   – caret moved to a different line while
    ///                        the viewport stayed put; implicit
    ///                        follow.
    ///
    /// Lifted out of `updateNSView` so XCTest can pin the priority
    /// ordering and the "no-op when nothing changed" invariant
    /// without spinning up a WKWebView. The function is deliberately
    /// parameter-only (no Coordinator, no view) so every assertion
    /// reads like a plain state-transition test.
    enum RevealAction: Equatable {
        case none
        case viewport(Int)
        case cursor(Int)
    }

    static func decideReveal(cursorLine: Int?,
                             viewportLine: Int?,
                             lastCursor: Int,
                             lastViewport: Int) -> RevealAction {
        if let vp = viewportLine, lastViewport != vp {
            return .viewport(vp)
        }
        if let line = cursorLine, lastCursor != line {
            return .cursor(line)
        }
        return .none
    }

    private func loadHTML(into view: WKWebView, coordinator: Coordinator) {
        let body = MarkdownConverter.render(markdown,
                                            baseDirectory: baseDirectory)
        let headings = Self.extractHeadings(markdown)
        let tocHTML = Self.renderTOC(headings)
        // Phase 51b — three distinct paths:
        //   1. first render OR theme flipped → full loadHTMLString
        //      (we need a fresh CSS generation and a clean shell)
        //   2. markdown-only change, shell already up → JS inject
        //      into #md-root so WebKit doesn't blow scrollY away
        //   3. unchanged → callers are expected to short-circuit
        //      earlier, but if we get here we still skip the work
        if coordinator.hasInitialLoad,
           coordinator.cachedIsDark == isDark {
            injectBody(body,
                       tocHTML: tocHTML,
                       headings: headings,
                       into: view,
                       coordinator: coordinator)
            return
        }
        let html = Self.wrap(body: body, isDark: isDark,
                             scrollY: coordinator.lastScrollY,
                             tocHTML: tocHTML,
                             headings: headings)
        view.loadHTMLString(html, baseURL: nil)
        coordinator.cachedMarkdown = markdown
        coordinator.cachedIsDark = isDark
        if let line = cursorLine { coordinator.lastCursorLine = line }
        // Phase 52b — seed the viewport mirror so the very next
        // updateNSView tick (fired as Document re-publishes) doesn't
        // re-reveal a line we already landed on during the full
        // reload.
        if let vp = viewportLine { coordinator.lastViewportLine = vp }
    }

    /// Phase 51b — incremental body swap. Builds a JS statement that
    /// replaces `#md-root.innerHTML` with the freshly-converted body
    /// and dispatches it on the main-actor via WKWebView's bridge.
    /// On any JS failure (page not ready, malformed string — neither
    /// expected, both guarded against) we fall back to the full-
    /// reload path via `loadHTMLString` so the preview can never
    /// end up stranded on stale content.
    private func injectBody(_ body: String,
                            tocHTML: String,
                            headings: [PreviewHeading],
                            into view: WKWebView,
                            coordinator: Coordinator) {
        // Phase 52a — the heading map (`__scribeHeadings`) is gone;
        // the reveal helper now sources its block index from the
        // DOM, so the injection path's only job on that front is to
        // call `scribeBuildBlockIndex()` *after* the innerHTML swap
        // lands so a freshly-typed block is immediately reachable
        // on the next caret move.
        let jsBody = Self.jsStringLiteral(tocHTML + body)
        // Phase 51d — after the innerHTML swap, re-run hljs against
        // every `<pre><code>` in the freshly-injected tree so newly
        // added code blocks pick up colour tokens. `try/catch` keeps
        // a hljs grammar-not-found from aborting the rest of the JS
        // (it shouldn't, but fenced blocks with unknown hints are
        // common enough that we're defensive).
        let js = "var _r = document.getElementById('md-root'); "
            + "if (_r) { _r.innerHTML = \(jsBody); "
            + "if (window.hljs) { "
            + "_r.querySelectorAll('pre code').forEach(function (b) { "
            + "try { hljs.highlightElement(b); } catch (e) {} }); "
            + "} "
            + "if (window.scribeBuildBlockIndex) { scribeBuildBlockIndex(); } "
            + "true; } else { false; }"
        // Capture a pre-rendered fallback html NOW (not lazily) so the
        // retry branch below doesn't have to re-enter the converter
        // on the error path. The string cost is a one-off copy and
        // it's only materialised if we take the fallback.
        let fallbackHTML = Self.wrap(body: body, isDark: isDark,
                                     scrollY: coordinator.lastScrollY,
                                     tocHTML: tocHTML,
                                     headings: headings)
        // Optimistically cache the source *before* the JS round-trip:
        // the injection is synchronous on the WebKit side and we want
        // the next updateNSView tick (which may fire in the same run
        // loop iteration) to see the new cache. If the JS ends up
        // failing, the fallback branch rewrites the cache unchanged —
        // same value, no harm done.
        coordinator.cachedMarkdown = markdown
        view.evaluateJavaScript(js) { result, error in
            let succeeded = (error == nil) && ((result as? Bool) ?? false)
            if succeeded { return }
            // Fall back to a clean reload. Dispatch-async so we never
            // re-enter WebKit from inside its own callback — and so
            // a transient missing #md-root (e.g. the shell is still
            // loading) gives the main loop a chance to settle before
            // we take the heavier path.
            DispatchQueue.main.async {
                view.loadHTMLString(fallbackHTML, baseURL: nil)
                coordinator.cachedIsDark = self.isDark
            }
        }
    }

    /// Phase 51b — encode an HTML fragment as a JavaScript string
    /// literal suitable for `evaluateJavaScript`. We use
    /// `JSONSerialization` on a `[String]` so Foundation handles
    /// every backslash / quote / control-char edge case for us,
    /// then strip the surrounding `[` / `]` and the array wrapper
    /// quoting to leave the quoted-string form JS needs.
    ///
    /// `U+2028` / `U+2029` are valid inside JSON strings but not
    /// inside JS string literals; we rewrite them to `\u2028` /
    /// `\u2029` explicitly before encoding so the resulting JS
    /// parses cleanly.
    static func jsStringLiteral(_ s: String) -> String {
        // JS string literals can't carry a raw U+2028/U+2029 even
        // though JSON can; pre-escape them so the `evaluateJavaScript`
        // side accepts the output.
        let safe = s
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        // `JSONSerialization.data(withJSONObject: [safe])` gives us
        // `[\"…\"]`; slice off the array brackets to leave the
        // quoted-string form. `.fragmentsAllowed` would be nicer
        // here but it's iOS 13+ / macOS 10.15+ only for scalar
        // strings — the array trick is portable.
        guard let data = try? JSONSerialization.data(
            withJSONObject: [safe], options: []),
              let array = String(data: data, encoding: .utf8),
              array.hasPrefix("[") && array.hasSuffix("]"),
              array.count >= 2
        else {
            // Pathological input (embedded NUL bytes could upset
            // JSONSerialization). Fall back to a minimal hand-rolled
            // escape that at least can't produce malformed JS.
            var out = "\""
            for ch in safe.unicodeScalars {
                switch ch {
                case "\\": out += "\\\\"
                case "\"": out += "\\\""
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if ch.value < 0x20 {
                        out += String(format: "\\u%04x", ch.value)
                    } else {
                        out += String(ch)
                    }
                }
            }
            out += "\""
            return out
        }
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Phase 51e · heading scan / TOC / scroll sync

    /// One ATX heading discovered in the markdown source. The
    /// converter generates the body HTML; we generate the heading
    /// list independently so we don't have to widen the converter's
    /// return type. Both walks agree on the same slug rules
    /// (`MarkdownConverter.headingSlug` + the dedup pass) so the
    /// `id` we point at always exists in the rendered DOM.
    struct PreviewHeading: Equatable {
        /// 1-based source line — matches `Document.cursorLine`.
        let line: Int
        /// 1…6, mirrors the H1–H6 level the converter emits.
        let level: Int
        /// GitHub-style slug; first occurrence has no suffix, then
        /// `-1`, `-2`… per Phase 51c rules.
        let slug: String
        /// Plain-text heading title (with markup stripped) — the
        /// label we show inside the inline TOC.
        let title: String
    }

    /// Walk the markdown source and surface every ATX heading
    /// (`#…######` prefix, leading-space tolerant) outside fenced
    /// code blocks. Setext headings (`==== / ----`) are out of scope —
    /// the converter doesn't recognise them either, so we'd be
    /// pointing at slugs that don't exist in the DOM if we did.
    ///
    /// Fence handling matches what `MarkdownConverter` does: a line
    /// whose trimmed prefix is ```` ``` ```` or `~~~` toggles us in/out
    /// of a code block, and inside a code block any leading `#` is
    /// data, not a heading.
    static func extractHeadings(_ markdown: String) -> [PreviewHeading] {
        var out: [PreviewHeading] = []
        var seen: [String: Int] = [:]
        var inFence = false
        var fenceMarker: Character = "`"
        // Walk by line index so we don't lose blank lines (which
        // Substring.split(omittingEmptySubsequences: false) preserves).
        // Normalise CRLF / CR to LF first so a Windows-line-ended file
        // doesn't produce ghost empty lines that throw off our 1-based
        // source-line numbering vs `Document.cursorLine`.
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n",
                                     omittingEmptySubsequences: false)
        for (idx, raw) in lines.enumerated() {
            let line = String(raw)
            // Trim leading whitespace for fence + heading detection.
            // CommonMark allows up to 3 leading spaces before either
            // construct; we accept any leading whitespace because
            // the converter is permissive there too.
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            // Fence toggle: any run of 3+ backticks or tildes opens
            // or closes a code block. We track the marker so a `~~~`
            // open isn't accidentally closed by a later ```` ``` ````.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = trimmed.first!
                if inFence {
                    if marker == fenceMarker { inFence = false }
                } else {
                    inFence = true
                    fenceMarker = marker
                }
                continue
            }
            if inFence { continue }
            // ATX heading: 1–6 hashes, then required whitespace,
            // then content. Optional trailing `###` is stripped.
            guard trimmed.hasPrefix("#") else { continue }
            var hashCount = 0
            for ch in trimmed {
                if ch == "#" {
                    hashCount += 1
                    if hashCount > 6 { break }
                } else { break }
            }
            guard hashCount >= 1, hashCount <= 6 else { continue }
            let afterHashes = trimmed.dropFirst(hashCount)
            // Need at least one whitespace separator. `# foo` is a
            // heading; `#foo` is just a paragraph that starts with
            // a hash sign (per CommonMark).
            guard let first = afterHashes.first,
                  first == " " || first == "\t" else { continue }
            // Strip leading/trailing whitespace + trailing closing
            // hashes (`# foo #` form).
            var title = String(afterHashes.drop(while: { $0 == " " || $0 == "\t" }))
            while let last = title.last,
                  last == " " || last == "\t" || last == "#" {
                title.removeLast()
            }
            title = title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            // Slug + dedup mirrors MarkdownConverter.uniqueSlug.
            let baseSlug = MarkdownConverter.headingSlug(title)
            let n = seen[baseSlug, default: 0]
            seen[baseSlug] = n + 1
            let slug = n == 0 ? baseSlug : "\(baseSlug)-\(n)"
            out.append(PreviewHeading(line: idx + 1,
                                      level: hashCount,
                                      slug: slug,
                                      title: title))
        }
        return out
    }

    /// Build the inline `<nav class="md-toc">` block. Only emitted
    /// when there are at least 3 headings (a doc with one or two
    /// headings doesn't benefit from a TOC and the chrome would be
    /// noise). H4–H6 are dropped from the TOC even if they appear
    /// in the body — past three indent levels it gets unreadable.
    /// Returns an empty string when no TOC should ship; `wrap`
    /// then prepends nothing.
    static func renderTOC(_ headings: [PreviewHeading]) -> String {
        let visible = headings.filter { $0.level <= 3 }
        guard visible.count >= 3 else { return "" }
        var out = #"<nav class="md-toc"><div class="md-toc-title">"#
        out += L10n.t("preview.toc.title")
        out += "</div><ul>"
        for h in visible {
            // Bump the raw-string delimiter to `##"…"##` because the
            // anchor `href="#…"` contains a literal `"#` sequence that
            // would otherwise close a single-`#` raw string early.
            out += ##"<li class="md-toc-l\##(h.level)"><a href="#\##(h.slug)">"##
            out += htmlEscape(h.title)
            out += "</a></li>"
        }
        out += "</ul></nav>"
        return out
    }

    /// Inline `<script>` that defines the `scribeRevealLine` /
    /// `scribeBuildBlockIndex` helpers the caret- + scroll-sync
    /// paths fire on every cursor / viewport move.
    ///
    /// Phase 52a — the block index is now sourced from the DOM by
    /// scanning every element carrying a `data-source-line`
    /// attribute, not from a Swift-built heading map. The converter
    /// stamps every block (heading / paragraph / list / list item
    /// / blockquote / code / table / hr) with its source line, so
    /// the JS reveal helper can land on whichever block contains
    /// the caret — much finer than the 51e heading-only pass.
    ///
    /// `scribeRevealLine(line)` picks the block whose
    /// `data-source-line` is the largest value ≤ `line` and calls
    /// `scrollIntoView({block:'start', behavior:'auto'})` on it.
    /// The index is rebuilt on DOMContentLoaded and on every
    /// `#md-root` innerHTML swap via the injection path.
    ///
    /// No per-render Swift data is needed anymore: the DOM *is* the
    /// source of truth. The function accepts zero arguments beyond
    /// the line number, so the injection path can call it directly
    /// without serialising headings into the JS statement.
    static func revealLineScript(headings: [PreviewHeading] = []) -> String {
        // `headings` parameter retained for API compatibility with the
        // 51e test suite; unused in the body. The block index is
        // rebuilt from the DOM, so a stale `__scribeHeadings` would
        // only waste bytes.
        _ = headings
        return """
        <script>
          // Binary-searchable [{line, el}] array, sorted by source
          // line. Re-materialised from the DOM on every rebuild call
          // so mid-edit innerHTML swaps stay in sync without any
          // Swift-side plumbing.
          window.__scribeBlockIndex = [];
          window.scribeBuildBlockIndex = function () {
            var els = document.querySelectorAll('[data-source-line]');
            var idx = [];
            for (var i = 0; i < els.length; i++) {
              var v = parseInt(els[i].getAttribute('data-source-line'), 10);
              if (!isNaN(v) && v > 0) {
                idx.push({line: v, el: els[i]});
              }
            }
            // Stable enough: DOM order already approximates line
            // order, and identical lines (e.g. two `<li>`s on the
            // same source line, which shouldn't happen but the
            // converter can produce with a pathological table) stay
            // in document order.
            idx.sort(function (a, b) { return a.line - b.line; });
            window.__scribeBlockIndex = idx;
          };
          window.scribeRevealLine = function (line) {
            var idx = window.__scribeBlockIndex || [];
            if (!idx.length) {
              scribeBuildBlockIndex();
              idx = window.__scribeBlockIndex;
            }
            if (!idx.length) return false;
            // Binary search for the largest idx[k].line ≤ line.
            var lo = 0, hi = idx.length - 1, best = -1;
            while (lo <= hi) {
              var mid = (lo + hi) >> 1;
              if (idx[mid].line <= line) { best = mid; lo = mid + 1; }
              else { hi = mid - 1; }
            }
            // Before the first source-mapped block (e.g. caret on
            // a lead-in blank line), snap to the very first block
            // rather than doing nothing — the user expects *some*
            // visual response to a caret move.
            if (best < 0) { best = 0; }
            idx[best].el.scrollIntoView({block: 'start', behavior: 'auto'});
            return true;
          };
          // Initial build once the shell's DOM is ready. Subsequent
          // `#md-root.innerHTML = …` swaps have to call
          // `scribeBuildBlockIndex()` themselves (the injection
          // statement in Swift does exactly that).
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded',
                                      scribeBuildBlockIndex);
          } else {
            scribeBuildBlockIndex();
          }
        </script>
        """
    }

    /// Same input/output contract as `jsStringLiteral` but without
    /// the surrounding quotes — for embedding inside a JS object
    /// literal we emit ourselves. Limited to the characters that
    /// appear inside slugs (ASCII alnum, dashes, occasional CJK)
    /// so the simple replacement table is sufficient.
    private static func jsStringEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:   out.append(ch)
            }
        }
        return out
    }

    /// Minimal HTML escape for TOC link text. The converter has its
    /// own (richer) escaper; we don't want to pull a private helper
    /// across the module boundary, and TOC titles only need the
    /// big four substitutions.
    private static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:  out.append(ch)
            }
        }
        return out
    }

    /// Build a complete `<html>` document around the converter's body
    /// fragment. CSS pulled in-line so the preview is fully self-
    /// contained — no network, no resource bundle, no FOUC.
    private static func wrap(body: String,
                             isDark: Bool,
                             scrollY: CGFloat,
                             tocHTML: String = "",
                             headings: [PreviewHeading] = []) -> String {
        // We hard-code the colour palette per scheme rather than
        // relying on prefers-color-scheme alone so the editor's theme
        // toggle controls the preview too.
        let bg     = isDark ? "#1e1e1e" : "#ffffff"
        let fg     = isDark ? "#e6e6e6" : "#1f2328"
        let muted  = isDark ? "#9da5b1" : "#656d76"
        let border = isDark ? "#30363d" : "#d0d7de"
        let codeBg = isDark ? "#262c33" : "#f6f8fa"
        let link   = isDark ? "#58a6ff" : "#0969da"

        // Phase 51d — pick the theme CSS that matches the current
        // colour scheme. Empty strings on a missing-asset build keep
        // the page rendering (just without colour tokens).
        let hlThemeCSS = isDark ? githubDarkCSS : githubLightCSS

        // The trailing <script> reads back the persisted scroll
        // position. window.scrollTo runs after layout, so the user
        // sees the page settle at the same offset the previous
        // render left it at — no jolt back to top on every keystroke.
        //
        // Phase 51d — the same load handler also fires highlight.js
        // against every `<pre><code>` so the first paint already
        // shows colour tokens. Subsequent JS-injection updates run
        // their own highlightAll inside `injectBody`.
        let restore = """
        <script>
          window.addEventListener('load', function () {
            window.scrollTo(0, \(Int(scrollY)));
            if (window.hljs) {
              document.querySelectorAll('pre code').forEach(function (b) {
                try { hljs.highlightElement(b); } catch (e) {}
              });
            }
          });
        </script>
        """

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body {
            margin: 0;
            padding: 0;
            background: \(bg);
            color: \(fg);
          }
          body {
            font: 14px/1.6 -apple-system, "SF Pro Text", system-ui, sans-serif;
            padding: 28px 36px 64px 36px;
            max-width: 760px;
            margin: 0 auto;
            -webkit-text-size-adjust: 100%;
          }
          h1, h2, h3, h4, h5, h6 {
            margin: 28px 0 12px 0;
            line-height: 1.25;
            font-weight: 600;
          }
          h1 { font-size: 1.85em; border-bottom: 1px solid \(border); padding-bottom: 6px; }
          h2 { font-size: 1.45em; border-bottom: 1px solid \(border); padding-bottom: 5px; }
          h3 { font-size: 1.20em; }
          h4 { font-size: 1.05em; }
          h5 { font-size: 0.95em; color: \(muted); }
          h6 { font-size: 0.85em; color: \(muted); }
          p { margin: 10px 0; }
          a { color: \(link); text-decoration: none; }
          a:hover { text-decoration: underline; }
          ul, ol { padding-left: 1.6em; margin: 10px 0; }
          li { margin: 3px 0; }
          blockquote {
            border-left: 4px solid \(border);
            margin: 14px 0;
            padding: 0 14px;
            color: \(muted);
          }
          code {
            font: 12.5px/1.5 "SF Mono", ui-monospace, "Monaco", monospace;
            background: \(codeBg);
            padding: 2px 5px;
            border-radius: 4px;
          }
          pre {
            background: \(codeBg);
            border: 1px solid \(border);
            border-radius: 6px;
            padding: 12px 14px;
            overflow-x: auto;
            margin: 14px 0;
          }
          pre code {
            background: transparent;
            padding: 0;
            font-size: 12.5px;
            white-space: pre;
          }
          /* Phase 51d — highlight.js's GitHub theme paints its own
             background + padding via `pre code.hljs`. Strip both so
             our outer `<pre>` chrome (border, codeBg fill) stays the
             single source of truth. The hljs theme keeps the colour
             tokens, which is the only piece we actually want from it. */
          pre code.hljs {
            background: transparent;
            padding: 0;
          }
          hr {
            border: none;
            border-top: 1px solid \(border);
            margin: 22px 0;
          }
          img { max-width: 100%; border-radius: 4px; }
          /* Phase 32 — GFM tables. The converter emits inline
             text-align styles per cell when the alignment row asks
             for them, so all we have to ship here is the chrome. */
          table {
            border-collapse: collapse;
            margin: 14px 0;
            display: block;
            overflow-x: auto;
          }
          th, td {
            border: 1px solid \(border);
            padding: 6px 12px;
          }
          th {
            background: \(codeBg);
            font-weight: 600;
          }
          tbody tr:nth-child(2n) { background: \(isDark ? "#22272d" : "#f6f8fa"); }
          /* Phase 32 — task lists. Indent the list visually so the
             checkbox sits inline with the text and the bullet
             disappears (the checkbox replaces it). */
          li.task-list-item {
            list-style: none;
            margin-left: -1.4em;
          }
          li.task-list-item input[type="checkbox"] {
            margin-right: 6px;
            vertical-align: middle;
          }
          /* Phase 32 — footnotes. Visually distinct trailing block
             with a back-reference glyph that matches GitHub's. */
          section.footnotes {
            font-size: 0.9em;
            color: \(muted);
            margin-top: 28px;
          }
          section.footnotes hr {
            margin: 14px 0;
          }
          sup.footnote-ref a {
            text-decoration: none;
            padding: 0 2px;
          }
          a.footnote-back {
            text-decoration: none;
            margin-left: 4px;
            color: \(link);
          }
          ::selection {
            background: \(isDark ? "#264f78" : "#cce5ff");
          }
          /* Phase 51e — inline TOC. Sits at the top of #md-root,
             so JS injection (which replaces #md-root.innerHTML)
             rebuilds it together with the body. The list is
             indent-styled per heading level rather than nested
             so the slug→`<li>` lookup stays trivial. */
          nav.md-toc {
            border: 1px solid \(border);
            border-radius: 6px;
            padding: 12px 16px;
            margin: 0 0 24px 0;
            background: \(codeBg);
            font-size: 0.9em;
          }
          nav.md-toc .md-toc-title {
            font-weight: 600;
            margin-bottom: 6px;
            color: \(muted);
            letter-spacing: 0.04em;
            text-transform: uppercase;
            font-size: 0.85em;
          }
          nav.md-toc ul {
            list-style: none;
            padding: 0;
            margin: 0;
          }
          nav.md-toc li { margin: 2px 0; }
          nav.md-toc a {
            text-decoration: none;
            color: \(fg);
          }
          nav.md-toc a:hover {
            text-decoration: underline;
            color: \(link);
          }
          nav.md-toc li.md-toc-l2 { padding-left: 16px; }
          nav.md-toc li.md-toc-l3 { padding-left: 32px; font-size: 0.95em; }
        </style>
        <style>\(hlThemeCSS)</style>
        <script>\(highlightJSAsset)</script>
        \(Self.revealLineScript(headings: headings))
        </head>
        <body>
        <div id="md-root">\(tocHTML)\(body)</div>
        \(restore)
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Last fed source markdown — used by updateNSView to skip
        /// the reload when nothing actually changed. Written by both
        /// the full-reload path and the JS-injection path so the
        /// short-circuit stays consistent regardless of which branch
        /// the previous tick took.
        var cachedMarkdown: String = "\u{0}"   // sentinel; doc text can't equal this
        var cachedIsDark: Bool = false
        /// scrollY restored after each reload so the preview stays put
        /// while the user types.
        var lastScrollY: CGFloat = 0
        /// Phase 51b — flipped to true the first time WKWebView finishes
        /// a navigation (i.e. the HTML shell is up and `#md-root` exists).
        /// Gate for the JS-injection fast path: before the first
        /// `didFinish` we MUST take the full-reload branch because
        /// `document.getElementById('md-root')` is null.
        var hasInitialLoad: Bool = false
        /// Phase 51e — last 1-based source line we asked the preview to
        /// reveal. Updated by `updateNSView` whenever the caret moves so
        /// we don't fire a JS round-trip per re-render when the line is
        /// the same as last tick.
        var lastCursorLine: Int = -1
        /// Phase 52b — last viewport-top line we received from the
        /// editor's V_SCROLL handler. The scroll-sync fast path
        /// short-circuits when the value matches so a steady-state
        /// re-render doesn't fire a redundant scribeRevealLine call.
        var lastViewportLine: Int = -1

        // The user clicked an `<a href="…">`. We never want WKWebView
        // to actually navigate (then the preview would go blank); we
        // pop them out into the system default browser instead.
        //
        // The `@MainActor` annotation on the closure parameter is what
        // the WKNavigationDelegate protocol declares in the macOS 14
        // SDK; the Swift 6 strict-concurrency build emits "nearly
        // matches" warnings if we drop it.
        @MainActor
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                // Phase 51c — an intra-doc anchor (`href="#section"`)
                // should scroll the preview, not spawn a browser tab.
                // WKWebView handles the scroll natively if we return
                // `.allow`; the full-reload path would otherwise blow
                // scrollY away.
                //
                // Bug fix (post-51e) — the earlier heuristic
                // ("fragment != nil" / "hasPrefix('#')") relied on
                // Foundation parsing `about:blank#<slug>` into scheme
                // + fragment. It doesn't: `about:` is treated as an
                // opaque URI so `URL.fragment` stays nil and `#` shows
                // up percent-encoded (`%23`) in `absoluteString`. The
                // result was every TOC / heading-anchor click falling
                // through to `NSWorkspace.open`, which promptly popped
                // a dialog complaining there's no app registered for
                // `about:blank#…`.
                //
                // The actual invariant we want is "same-document
                // navigation": if the clicked URL differs from the
                // live document only by its fragment, it's an intra-
                // page anchor and WebKit can scroll it natively.
                // `isSameDocumentAnchor` peels off both URLs'
                // fragments and compares the remainders. This works
                // for the `about:blank` shell we're using today and
                // stays correct if we ever give the preview a real
                // baseURL (e.g. `file:///…/readme.md`).
                if Self.isSameDocumentAnchor(target: url,
                                             current: webView.url) {
                    decisionHandler(.allow)
                    return
                }
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// Returns true when `target` differs from `current` only by
        /// fragment — i.e. clicking this link is just a scroll-to-
        /// anchor inside the currently-rendered document.
        ///
        /// Works in two layers because `about:blank` is an opaque
        /// URI that Foundation refuses to split into scheme + path
        /// + fragment:
        ///
        ///   1. Fast path — canonicalise both URLs as strings,
        ///      drop everything at the first `#` / `%23`, and
        ///      compare the heads byte-for-byte.
        ///   2. Reject early if the scheme differs (`mailto:`,
        ///      `http:`, `https:` clicks need to go to NSWorkspace).
        ///
        /// Pulled out as a `static` so unit tests can exercise the
        /// predicate without touching WKWebView.
        static func isSameDocumentAnchor(target: URL,
                                         current: URL?) -> Bool {
            guard let current else { return false }
            // Scheme mismatch ⇒ definitely different document.
            // We compare case-insensitively because URL schemes are
            // defined that way in RFC 3986 and Foundation normalises
            // input inconsistently on the round-trip.
            let ts = target.scheme?.lowercased()
            let cs = current.scheme?.lowercased()
            guard ts == cs else { return false }
            // Strip the fragment from each absoluteString. The
            // fragment marker is `#` in the RFC form and `%23` in
            // the opaque/about-form Foundation emits, so scan for
            // whichever lands first.
            func stripFragment(_ s: String) -> String {
                let hash = s.firstIndex(of: "#")
                let pct = s.range(of: "%23")?.lowerBound
                switch (hash, pct) {
                case let (h?, p?): return String(s[..<min(h, p)])
                case let (h?, nil): return String(s[..<h])
                case let (nil, p?): return String(s[..<p])
                case (nil, nil): return s
                }
            }
            return stripFragment(target.absoluteString)
                == stripFragment(current.absoluteString)
        }

        // After each full reload, flip `hasInitialLoad` so the next
        // update can take the JS-injection fast path, and capture
        // scrollY so the *next* full reload (theme flip) can restore
        // the user's viewport.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasInitialLoad = true
            webView.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
                if let n = result as? NSNumber {
                    self?.lastScrollY = CGFloat(truncating: n)
                }
            }
        }
    }
}
