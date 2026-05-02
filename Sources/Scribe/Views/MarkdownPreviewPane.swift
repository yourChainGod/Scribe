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

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        // Skip the reload when nothing changed — mostly a no-op since
        // updateNSView already fires only on @State / @Environment
        // changes, but cheap insurance against a future re-arrange.
        if context.coordinator.cachedMarkdown == markdown,
           context.coordinator.cachedIsDark == isDark {
            return
        }
        loadHTML(into: view, coordinator: context.coordinator)
    }

    private func loadHTML(into view: WKWebView, coordinator: Coordinator) {
        let body = MarkdownConverter.render(markdown,
                                            baseDirectory: baseDirectory)
        // Phase 51b — three distinct paths:
        //   1. first render OR theme flipped → full loadHTMLString
        //      (we need a fresh CSS generation and a clean shell)
        //   2. markdown-only change, shell already up → JS inject
        //      into #md-root so WebKit doesn't blow scrollY away
        //   3. unchanged → callers are expected to short-circuit
        //      earlier, but if we get here we still skip the work
        if coordinator.hasInitialLoad,
           coordinator.cachedIsDark == isDark {
            injectBody(body, into: view, coordinator: coordinator)
            return
        }
        let html = Self.wrap(body: body, isDark: isDark,
                             scrollY: coordinator.lastScrollY)
        view.loadHTMLString(html, baseURL: nil)
        coordinator.cachedMarkdown = markdown
        coordinator.cachedIsDark = isDark
    }

    /// Phase 51b — incremental body swap. Builds a JS statement that
    /// replaces `#md-root.innerHTML` with the freshly-converted body
    /// and dispatches it on the main-actor via WKWebView's bridge.
    /// On any JS failure (page not ready, malformed string — neither
    /// expected, both guarded against) we fall back to the full-
    /// reload path via `loadHTMLString` so the preview can never
    /// end up stranded on stale content.
    private func injectBody(_ body: String,
                            into view: WKWebView,
                            coordinator: Coordinator) {
        let jsBody = Self.jsStringLiteral(body)
        let js = "var _r = document.getElementById('md-root'); "
            + "if (_r) { _r.innerHTML = \(jsBody); true; } else { false; }"
        // Capture a pre-rendered fallback html NOW (not lazily) so the
        // retry branch below doesn't have to re-enter the converter
        // on the error path. The string cost is a one-off copy and
        // it's only materialised if we take the fallback.
        let fallbackHTML = Self.wrap(body: body, isDark: isDark,
                                     scrollY: coordinator.lastScrollY)
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

    /// Build a complete `<html>` document around the converter's body
    /// fragment. CSS pulled in-line so the preview is fully self-
    /// contained — no network, no resource bundle, no FOUC.
    private static func wrap(body: String,
                             isDark: Bool,
                             scrollY: CGFloat) -> String {
        // We hard-code the colour palette per scheme rather than
        // relying on prefers-color-scheme alone so the editor's theme
        // toggle controls the preview too.
        let bg     = isDark ? "#1e1e1e" : "#ffffff"
        let fg     = isDark ? "#e6e6e6" : "#1f2328"
        let muted  = isDark ? "#9da5b1" : "#656d76"
        let border = isDark ? "#30363d" : "#d0d7de"
        let codeBg = isDark ? "#262c33" : "#f6f8fa"
        let link   = isDark ? "#58a6ff" : "#0969da"

        // The trailing <script> reads back the persisted scroll
        // position. window.scrollTo runs after layout, so the user
        // sees the page settle at the same offset the previous
        // render left it at — no jolt back to top on every keystroke.
        let restore = """
        <script>
          window.addEventListener('load', function () {
            window.scrollTo(0, \(Int(scrollY)));
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
        </style>
        </head>
        <body>
        <div id="md-root">\(body)</div>
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
                if url.absoluteString.hasPrefix("#") || url.fragment != nil,
                   url.scheme == nil || url.host == nil {
                    decisionHandler(.allow)
                    return
                }
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
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
