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
//  Why no JS / no incremental DOM updates: a full reload of a typical
//  README (~30 KB rendered HTML) takes 5–10 ms on an M-class Mac;
//  cheaper than wiring up a JS bridge and tracking which subtree
//  changed. The trade-off is scroll resets on every render — we
//  bandage that by remembering scrollY across reloads and restoring
//  it via a small inline `<script>` once the body lays out.
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
        let body = MarkdownConverter.render(markdown)
        let html = Self.wrap(body: body, isDark: isDark,
                             scrollY: coordinator.lastScrollY)
        view.loadHTMLString(html, baseURL: nil)
        coordinator.cachedMarkdown = markdown
        coordinator.cachedIsDark = isDark
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
        \(body)
        \(restore)
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Last fed markdown — used by updateNSView to skip the reload
        /// when nothing actually changed.
        var cachedMarkdown: String = "\u{0}"   // sentinel; doc text can't equal this
        var cachedIsDark: Bool = false
        /// scrollY restored after each reload so the preview stays put
        /// while the user types.
        var lastScrollY: CGFloat = 0

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
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // After each reload, ask the page for its current scrollY and
        // remember it so the next reload (caused by another keystroke)
        // restores the same offset. Fires after layout so the value is
        // post-restore — i.e. equal to what we just told it.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
                if let n = result as? NSNumber {
                    self?.lastScrollY = CGFloat(truncating: n)
                }
            }
        }
    }
}
