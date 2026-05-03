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

/// Phase 53e-4 — cached KaTeX minified JS shipped inside
/// `Bundle.module`. Empty string on a missing-asset build so the
/// shell silently falls back to the CDN `<script>` below.
/// ~270 KB minified; base64-inlined fonts live in the sibling
/// CSS asset so the JS file is the official upstream distro.
private let katexJSAsset: String = {
    guard let url = Bundle.module.url(forResource: "katex.min",
                                      withExtension: "js"),
          let s = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return s
}()

/// Phase 53e-4 — cached KaTeX CSS with all twenty woff2 fonts
/// base64-inlined so the preview renders full-fidelity typeset
/// math with zero network dependency. ~370 KB after inlining
/// (23 KB upstream CSS + 268 KB of woff2 fonts encoded). Empty
/// on a missing-asset build → CDN fallback.
private let katexCSSAsset: String = {
    guard let url = Bundle.module.url(forResource: "katex.min",
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
    /// Phase 52c — callback fired every time the preview's JS
    /// scroll listener reports a new top-block line. The pane
    /// plumbs this straight through to the Coordinator on every
    /// updateNSView so a late-arriving Document reference is still
    /// seen. Passing nil disables the reverse-sync leg entirely
    /// (e.g. when rendered outside of a document context).
    var onPreviewScroll: ((Int) -> Void)? = nil
    /// Phase 53b — callback fired when the user clicks a task-list
    /// checkbox in the preview. Receives the 1-based source line
    /// of the containing `<li>`. Callers typically forward this
    /// to FindState.commands.send(.toggleMarkdownTaskCheckboxAt).
    var onToggleTask: ((Int) -> Void)? = nil

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
    static var katexJSAssetForTests: String { katexJSAsset }
    static var katexCSSAssetForTests: String { katexCSSAsset }

    /// Phase 53c — exposes the private `wrap(...)` shell builder
    /// so XCTest can pin structural invariants (KaTeX CDN
    /// injection, the `scribeRenderMath` load-time hook, etc.)
    /// without spinning up a WKWebView. Returns the *exact* string
    /// production injects, so any drift between this seam and the
    /// real shell is impossible.
    static func wrapForTests(body: String,
                             isDark: Bool = false,
                             userCSS: String = "") -> String {
        // Phase 53e-3 — explicit empty default so existing tests
        // don't accidentally pick up a developer's local
        // ~/.scribe/preview.css and tip into a flaky failure on
        // a different machine.
        return wrap(body: body, isDark: isDark, scrollY: 0,
                    userCSS: userCSS)
    }

    /// Phase 53e-3 — read `~/.scribe/preview.css` if the user has
    /// dropped one in. Returns the file contents on success, or
    /// the empty string on missing file / read failure / decode
    /// error. The preview must never fail to render because a
    /// user's optional theme tweak couldn't be loaded; an empty
    /// string lands in the `<style>` block harmlessly.
    ///
    /// `homeDirectory` is injectable for tests; production
    /// callers pass nil and we use `FileManager.default.
    /// homeDirectoryForCurrentUser`.
    static func loadUserPreviewCSS(homeDirectory: URL? = nil) -> String {
        let home = homeDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        let path = home
            .appendingPathComponent(".scribe", isDirectory: true)
            .appendingPathComponent("preview.css")
        // `try?` collapses the four ways this could fail (no
        // file, no permission, IO error, encoding) into a single
        // empty-string return. The user can debug via the file
        // system; we don't surface read errors to the UI.
        guard let data = try? Data(contentsOf: path) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Phase 52c — JS calls `webkit.messageHandlers.scribeScroll
        // .postMessage(line)` inside its rAF-throttled scroll
        // handler. Register the Coordinator as the receiver so
        // those messages flow into Document.previewViewportTopLine
        // via onPreviewScroll. The handler name is scoped to this
        // one pane's userContentController so there's no collision
        // with any other WKWebView in the app.
        cfg.userContentController.add(context.coordinator, name: "scribeScroll")
        // Phase 53b — second handler for task-checkbox clicks in
        // the preview. Kept on a distinct name so the dispatcher
        // can tell scroll reports and toggle clicks apart without
        // inspecting payload shape.
        cfg.userContentController.add(context.coordinator, name: "scribeToggleTask")
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.navigationDelegate = context.coordinator
        // Translucent: lets the SwiftUI parent (which owns light/dark
        // theming) bleed through if our HTML is shorter than the pane.
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        // Pick up the initial callbacks; updateNSView keeps them
        // fresh on every subsequent tick so a reconnect (new
        // Document, same pane) doesn't leave the handlers pointing
        // at the old Document's state.
        context.coordinator.onPreviewScroll = onPreviewScroll
        context.coordinator.onToggleTask = onToggleTask
        loadHTML(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coord = context.coordinator
        // Phase 52c / 53b — pane is a value type; every tick
        // rebuilds it with freshly-closed-over callbacks. Refresh
        // the Coordinator's copies so a stale Document reference
        // can't leak across document switches.
        coord.onPreviewScroll = onPreviewScroll
        coord.onToggleTask = onToggleTask
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
            // Phase 53c — the incremental innerHTML swap wipes any
            // previously-typeset KaTeX output inside `#md-root`,
            // so we re-run the renderer against the fresh subtree.
            // Guarded because offline sessions / missing-bundle
            // builds won't have `scribeRenderMath` defined.
            + "if (window.scribeRenderMath) { scribeRenderMath(); } "
            // Phase 53d — same for Mermaid. The `.mermaid:not(
            // [data-mermaid-rendered])` selector inside the
            // function already prevents re-rendering blocks that
            // survived the swap untouched, so the cost on a
            // diagram-free paragraph edit is one querySelectorAll
            // that returns an empty list.
            + "if (window.scribeRenderMermaid) { scribeRenderMermaid(); } "
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
    /// paths fire on every cursor / viewport move, plus the
    /// preview→editor scroll reporter that backs Phase 52c.
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
    /// Phase 52c — the inverse path: a window-level `scroll`
    /// listener computes the top-most block currently intersecting
    /// the viewport (`getBoundingClientRect().top >= 0`) and
    /// forwards its `data-source-line` to the Swift side via
    /// `webkit.messageHandlers.scribeScroll.postMessage(line)`. A
    /// programmatic-scroll guard (`__scribeProgrammaticScroll`
    /// timestamp) prevents an editor→preview reveal from looping
    /// back through this handler. The listener is rAF-coalesced so
    /// a flick-scroll can't fire dozens of messages per tick.
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
          // Phase 52c — epoch (ms) of the most recent programmatic
          // scroll. The preview→editor reporter ignores scroll
          // events within ~250 ms of this stamp so a reveal driven
          // by the editor's V_SCROLL can't bounce back.
          window.__scribeProgrammaticScroll = 0;
          // rAF-coalescing flag for the scroll reporter. Flipped
          // when a scroll event is queued, cleared inside the rAF.
          window.__scribeScrollRAF = 0;
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
            // Phase 52c — stamp the programmatic-scroll epoch
            // *before* the scroll happens so the handler that
            // fires on the next tick can recognise it as ours.
            window.__scribeProgrammaticScroll = Date.now();
            idx[best].el.scrollIntoView({block: 'start', behavior: 'auto'});
            return true;
          };
          // Phase 52c — preview→editor reporter. Finds the first
          // block whose top edge is at or below the viewport's top
          // (i.e. the block currently "at the top of the preview")
          // and ships its source line to Swift.
          window.scribeTopBlockLine = function () {
            var idx = window.__scribeBlockIndex || [];
            if (!idx.length) return 0;
            // Linear scan is fine: a typical README has <500 blocks
            // and the scroll handler runs at rAF (~60 Hz), so the
            // worst case is a few thousand op/s. A binary search on
            // getBoundingClientRect is possible but the constant
            // factor dwarfs the algorithmic win.
            for (var i = 0; i < idx.length; i++) {
              var r = idx[i].el.getBoundingClientRect();
              // Tiny slack (2 px) so a block flush against the top
              // counts, protecting against sub-pixel rounding that
              // would otherwise bump us one block early.
              if (r.top >= -2) { return idx[i].line; }
            }
            // Scrolled past the last block — report the final line
            // so the editor lands on the tail of the doc.
            return idx[idx.length - 1].line;
          };
          window.scribePostScroll = function () {
            window.__scribeScrollRAF = 0;
            if (!window.webkit || !window.webkit.messageHandlers
                || !window.webkit.messageHandlers.scribeScroll) {
              return;
            }
            // 250 ms matches macOS Cocoa's "is this a new gesture"
            // threshold well enough for our purposes. Any genuine
            // user-initiated scroll that happens within 250 ms of a
            // programmatic reveal would be indistinguishable from a
            // rebound and is (deliberately) swallowed.
            if (Date.now() - window.__scribeProgrammaticScroll < 250) {
              return;
            }
            var line = window.scribeTopBlockLine();
            if (line > 0) {
              window.webkit.messageHandlers.scribeScroll.postMessage(line);
            }
          };
          window.addEventListener('scroll', function () {
            if (window.__scribeScrollRAF) { return; }
            window.__scribeScrollRAF =
              window.requestAnimationFrame(window.scribePostScroll);
          }, { passive: true });
          // Phase 53e-1 — broken-image marker. The `error` event
          // doesn't bubble, so we listen in capture phase. We
          // tag the failing `<img>` with a class instead of
          // mutating src/innerHTML so a) the alt text the
          // browser draws stays visible, b) a future repaint
          // (theme flip → full reload, network reconnect → user
          // re-types url) starts clean. Idempotent: re-running
          // on the same broken img just re-adds a class it
          // already has.
          document.addEventListener('error', function (ev) {
            var t = ev.target;
            if (!t || !t.tagName) { return; }
            if (t.tagName !== 'IMG') { return; }
            t.classList.add('scribe-img-broken');
          }, true);
          // Phase 53b — click handler for task-list checkboxes.
          // Uses event delegation on document so checkboxes added
          // by the incremental innerHTML swap (Phase 51b) are
          // covered without re-binding. `.scribe-task` is the
          // class MarkdownConverter stamps on our rendered
          // checkboxes; third-party checkboxes inside raw HTML
          // blocks (if any) go through the default browser
          // behaviour.
          document.addEventListener('click', function (ev) {
            var t = ev.target;
            if (!t || !t.matches || !t.matches('input.scribe-task')) {
              return;
            }
            // Prevent the browser from flipping the DOM state;
            // markdown text is the single source of truth and
            // Swift will re-render the preview with the new
            // `checked` attribute after the edit lands.
            ev.preventDefault();
            var li = t.closest('li[data-source-line]');
            if (!li) { return; }
            var line = parseInt(li.getAttribute('data-source-line'), 10);
            if (!(line > 0)) { return; }
            if (!window.webkit || !window.webkit.messageHandlers
                || !window.webkit.messageHandlers.scribeToggleTask) {
              return;
            }
            window.webkit.messageHandlers.scribeToggleTask.postMessage(line);
          }, true);
          // Phase 53c — render every KaTeX placeholder
          // MarkdownConverter emitted. `.math-inline` and
          // `.math-display` carry the raw LaTeX as textContent;
          // katex.render rewrites the span/div with typeset HTML.
          // Failures (malformed LaTeX, KaTeX not loaded yet)
          // leave the raw text in place so the preview doesn't
          // collapse to an empty block — users see the original
          // `$x$` source instead of a blank spot.
          window.scribeRenderMath = function () {
            if (!window.katex) { return; }
            var inlines = document.querySelectorAll('.math-inline');
            for (var i = 0; i < inlines.length; i++) {
              var el = inlines[i];
              var src = el.textContent || '';
              if (!src) { continue; }
              try {
                katex.render(src, el, {
                  displayMode: false,
                  throwOnError: false,
                  errorColor: '#cc3333'
                });
              } catch (e) { /* leave raw text on failure */ }
            }
            var displays = document.querySelectorAll('.math-display');
            for (var j = 0; j < displays.length; j++) {
              var dl = displays[j];
              var dsrc = dl.textContent || '';
              if (!dsrc) { continue; }
              try {
                katex.render(dsrc, dl, {
                  displayMode: true,
                  throwOnError: false,
                  errorColor: '#cc3333'
                });
              } catch (e) { /* leave raw text on failure */ }
            }
          };
          // Phase 53d — render every `<div class="mermaid">`
          // MarkdownConverter emitted, using a unique render id
          // per call so mermaid's SVG `<defs>` don't collide
          // across blocks. `data-mermaid-rendered` marks each
          // block as done so repeated calls (keystroke updates
          // above a diagram) don't re-render it pointlessly.
          //
          // Mermaid's render API became async in v10. We use
          // `.then/.catch` instead of async/await for browsers
          // that don't ship top-level await; the .catch leaves
          // the raw source visible so a broken diagram still
          // shows the user what they typed.
          window.scribeRenderMermaid = function () {
            if (!window.mermaid || !mermaid.render) { return; }
            var els = document.querySelectorAll(
              '.mermaid:not([data-mermaid-rendered])');
            var now = Date.now();
            for (var i = 0; i < els.length; i++) {
              (function (el, idx) {
                var src = el.textContent || '';
                if (!src.trim()) { return; }
                var id = 'mermaid-svg-' + now + '-' + idx;
                try {
                  mermaid.render(id, src).then(function (result) {
                    el.innerHTML = result.svg;
                    el.setAttribute('data-mermaid-rendered', 'true');
                    if (typeof result.bindFunctions === 'function') {
                      try { result.bindFunctions(el); } catch (e) {}
                    }
                  }).catch(function (e) {
                    // Keep the raw source visible; future calls
                    // will re-try because we never stamped
                    // `data-mermaid-rendered`.
                  });
                } catch (e) { /* sync mermaid throw: same recovery */ }
              })(els[i], i);
            }
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
                             headings: [PreviewHeading] = [],
                             userCSS: String? = nil) -> String {
        // Phase 53e-3 — production callers pass nil and we resolve
        // `~/.scribe/preview.css` at render time; XCTest passes a
        // pre-built string via `wrapForTests` so it can pin
        // injection without writing to the real home directory.
        let userOverrideCSS = userCSS ?? Self.loadUserPreviewCSS()
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
            // Phase 53c — run KaTeX against every math span/div
            // MarkdownConverter emitted. Guarded on
            // `scribeRenderMath` because the JS injection path
            // (incremental innerHTML swap, Phase 51b) calls the
            // same function on its own; the function is a no-op
            // if `window.katex` hasn't loaded yet (offline) or if
            // the document has no math.
            if (window.scribeRenderMath) { scribeRenderMath(); }
            // Phase 53d — same pattern for Mermaid. The renderer
            // is async; we don't await it here because the load
            // handler shouldn't block other side-effects (scroll
            // restore / hljs).
            if (window.scribeRenderMermaid) { scribeRenderMermaid(); }
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
          /* Phase 53e-1 — visible fallback for broken image refs.
             A 404 image normally collapses to a 0×0 placeholder
             with the alt text invisible; here we draw a dashed
             warning box so the user sees *exactly* which image
             failed and what its alt was. The browser still
             renders the alt text inside the box because the
             <img> element retains its alt attribute. */
          img.scribe-img-broken {
            min-width: 80px;
            min-height: 32px;
            padding: 8px 12px;
            border: 1px dashed #cc3333;
            background: rgba(204, 51, 51, 0.08);
            color: #cc3333;
            font-size: 12px;
            border-radius: 4px;
          }
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
        <!-- Phase 53e-4 — KaTeX math rendering shipped inside
             the app bundle. The CSS carries 20 woff2 fonts as
             base64 data: URLs so offline sessions still get
             full-fidelity typeset math. The `<script>` is the
             stock upstream dist; running it inline (no defer)
             means `window.katex` is ready before the load
             handler calls `scribeRenderMath`. If the bundle
             assets are missing (a misconfigured build, empty
             strings), we fall back to the CDN so development
             builds with an incomplete Resources/ tree still
             render math. -->
        \(katexCSSAsset.isEmpty
          ? "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@0.16.21/dist/katex.min.css\" crossorigin=\"anonymous\">"
          : "<style>\(katexCSSAsset)</style>")
        \(katexJSAsset.isEmpty
          ? "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.21/dist/katex.min.js\" crossorigin=\"anonymous\"></script>"
          : "<script>\(katexJSAsset)</script>")
        <!-- Phase 53d — Mermaid runtime. Loaded as a classic
             (non-module) script because the module build uses ESM
             imports that WKWebView's `file://` + `about:blank`
             shells mis-parse. Auto-init is disabled: we drive
             rendering manually via `scribeRenderMermaid` so
             incremental DOM swaps (Phase 51b) get re-rendered
             without waiting for a full DOMContentLoaded. -->
        <script
            src="https://cdn.jsdelivr.net/npm/mermaid@10.9.3/dist/mermaid.min.js"
            crossorigin="anonymous"></script>
        <script>
          // Mermaid reads the current theme immediately on
          // initialize; re-running initialize with a different
          // theme on dark/light flip is the cleanest recovery
          // path (we already take a full reload on theme flip
          // in MarkdownPreviewPane.updateNSView).
          if (window.mermaid && mermaid.initialize) {
            mermaid.initialize({
              startOnLoad: false,
              theme: \(isDark ? "'dark'" : "'default'"),
              securityLevel: 'strict'
            });
          }
        </script>
        \(Self.revealLineScript(headings: headings))
        <!-- Phase 53e-3 — user override styles. Inlined LAST so
             the CSS cascade lets the user's rules win on a tie
             without `!important`. Empty when ~/.scribe/
             preview.css is absent (the default), so the <style>
             tag stays inert in that case. -->
        <style>\(userOverrideCSS)</style>
        </head>
        <body>
        <div id="md-root">\(tocHTML)\(body)</div>
        \(restore)
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
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
        /// Phase 52c — callback the pane refreshes every tick so JS
        /// scroll messages reach the current Document. Optional so
        /// previews rendered outside a document context silently
        /// drop the reverse-sync side.
        var onPreviewScroll: ((Int) -> Void)?
        /// Phase 53b — callback for task-checkbox clicks in the
        /// preview. Same lifecycle as `onPreviewScroll`.
        var onToggleTask: ((Int) -> Void)?
        /// Phase 52c — last line we heard from the JS scroll
        /// reporter. Used purely for test introspection; the
        /// ping-pong guard is the JS-side timestamp
        /// (`__scribeProgrammaticScroll`), not this field.
        var lastReportedPreviewLine: Int = 0
        /// Phase 53b — last source line we heard from the task-
        /// checkbox click reporter. Test-only introspection.
        var lastToggledTaskLine: Int = 0

        /// Phase 52c / 53b — WKScriptMessageHandler entry point.
        /// Both the rAF-throttled scroll reporter and the task-
        /// checkbox click handler post into here; the dispatch
        /// happens by name in `handleScrollMessage`.
        @MainActor
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            handleScrollMessage(name: message.name, body: message.body)
        }

        /// Phase 52c / 53b — decoupled body of
        /// `userContentController`. Extracted so XCTest can drive
        /// every handler without synthesising a `WKScriptMessage`
        /// (sealed, uninstantiable).
        ///
        /// Filtering rules — unknown name, non-NSNumber body,
        /// non-positive line — reject silently so a misbehaving JS
        /// patch can't crash the preview.
        @MainActor
        func handleScrollMessage(name: String, body: Any) {
            guard let n = body as? NSNumber else { return }
            let line = n.intValue
            guard line > 0 else { return }
            switch name {
            case "scribeScroll":
                lastReportedPreviewLine = line
                onPreviewScroll?(line)
            case "scribeToggleTask":
                lastToggledTaskLine = line
                onToggleTask?(line)
            default:
                return
            }
        }

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
