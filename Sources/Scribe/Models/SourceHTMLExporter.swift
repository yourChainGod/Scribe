//
//  SourceHTMLExporter.swift
//  Phase 60 — render the current document as a self-contained HTML
//  file with syntax-highlighted source. Mirrors what Notepad++'s
//  NPP_ExportPlugin produces on the Windows / Mac side: a single
//  `.html` you can email / Slack / paste into a static-site article
//  with code colours intact.
//
//  Design
//
//  We piggyback on the highlight.js + GitHub light/dark theme
//  assets we already bundle for the Markdown preview shell
//  (Phase 53). Inlining them into the exported HTML keeps the
//  output offline-readable; no CDN dependency, no bundling
//  mismatch between dev and CI.
//
//  Lang slug mapping
//
//    `LexerCatalog.descriptor(for:).lexillaName` is the Lexilla
//    identifier (e.g. "cpp", "python", "swift"). highlight.js's
//    language registry is mostly compatible — same string, same
//    intent — but a few names differ. The map below covers the
//    deltas; everything else falls through verbatim. Unknown slugs
//    end up as `class="language-plain"` and highlight.js displays
//    them with default styles.
//

import Foundation

enum SourceHTMLExporter {

    /// Render `text` to a complete HTML document. The returned
    /// string is ready to write to disk via `Data(...).write(to:)`.
    ///
    /// - Parameters:
    ///   - text: the source bytes (already decoded to a Swift String).
    ///   - title: window-title-style header for the page; we usually
    ///            pass the document's filename. Empty string falls
    ///            back to "Source export".
    ///   - lexillaName: Scintilla / Lexilla lexer name. Translated
    ///                  to a highlight.js language slug.
    ///   - isDark: pick the github-dark theme over github-light.
    static func renderHTML(text: String,
                           title: String,
                           lexillaName: String,
                           isDark: Bool) -> String {
        let pageTitle = title.isEmpty
            ? L10n.t("export.html.defaultTitle")
            : title
        let langSlug = highlightSlug(forLexillaName: lexillaName)
        let highlightCSS = bundledCSS(forDark: isDark)
        let highlightJS = bundledJS()
        // Escape HTML special chars in the source body. This must
        // happen *before* embedding into <code> — otherwise an
        // angle-bracket in the source would be parsed as a tag and
        // lose its colouring (or worse, swallow content).
        let escaped = htmlEscape(text)

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <title>\(htmlEscape(pageTitle))</title>
        <style>
        body {
          font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
          font-size: 13px;
          background: \(isDark ? "#0d1117" : "#ffffff");
          color: \(isDark ? "#c9d1d9" : "#1f2328");
          padding: 24px 28px;
          margin: 0;
        }
        pre {
          margin: 0;
          line-height: 1.5;
          white-space: pre-wrap;
          word-break: break-word;
        }
        code.hljs { padding: 0; background: transparent; }
        h1 {
          font-size: 14px;
          font-weight: 600;
          margin: 0 0 18px 0;
          color: \(isDark ? "#7d8590" : "#656d76");
        }
        \(highlightCSS)
        </style>
        </head>
        <body>
        <h1>\(htmlEscape(pageTitle))</h1>
        <pre><code class="language-\(langSlug) hljs">\(escaped)</code></pre>
        <script>\(highlightJS)</script>
        <script>
          // Re-run highlightAll on a single block; calling
          // highlightAll() with a deferred script tag is fine but
          // we already know which element to colour, so target
          // it directly to skip the auto-discovery scan.
          (function () {
            var el = document.querySelector('pre code');
            if (el && window.hljs) { hljs.highlightElement(el); }
          })();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Lang map

    /// Lexilla → highlight.js slug. Everything not in the map
    /// passes through unchanged; unknowns at render time degrade
    /// to highlight.js's "no auto-detect" path which renders
    /// without colours.
    static func highlightSlug(forLexillaName name: String) -> String {
        switch name {
        case "":             return "plaintext"
        case "null":         return "plaintext"
        case "cpp":          return "cpp"
        case "swift":        return "swift"
        case "python":       return "python"
        case "json":         return "json"
        case "markdown":     return "markdown"
        case "bash", "shell": return "bash"
        // highlight.js bundles `xml` and aliases `html`/`plist` to it.
        // Returning "xml" lines up with the actual registered language.
        case "xml", "html", "hypertext": return "xml"
        case "javascript":   return "javascript"
        case "typescript":   return "typescript"
        case "yaml":         return "yaml"
        case "go":           return "go"
        case "rust":         return "rust"
        case "ruby":         return "ruby"
        case "java":         return "java"
        case "kotlin":       return "kotlin"
        case "csharp", "cs": return "csharp"
        case "sql":          return "sql"
        case "lua":          return "lua"
        case "css":          return "css"
        case "ini":          return "ini"
        case "diff":         return "diff"
        case "dockerfile":   return "dockerfile"
        default:             return name
        }
    }

    // MARK: - HTML escape

    /// Map the four special chars to their entity equivalents. We
    /// don't escape every non-ASCII character — UTF-8 in the body
    /// renders fine inside a `<meta charset>`-tagged document, and
    /// numeric entities would balloon the output for documents
    /// with CJK / emoji content.
    static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            default:  out.append(ch)
            }
        }
        return out
    }

    // MARK: - Bundled assets

    /// Read the bundled `highlight.min.js` body (~120 KB). Returns
    /// an empty string on a missing-asset build — the resulting
    /// HTML still renders, just without colours, so the export
    /// stays useful even if SwiftPM ever drops the resource.
    private static func bundledJS() -> String {
        guard let url = Bundle.module.url(forResource: "highlight.min",
                                          withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return s
    }

    /// Pick the GitHub light / dark theme to match the user's
    /// preview chrome (Phase 53). Both files are bundled and
    /// already sized for the embedded `<style>` block.
    private static func bundledCSS(forDark dark: Bool) -> String {
        let name = dark ? "github-dark.min" : "github-light.min"
        guard let url = Bundle.module.url(forResource: name,
                                          withExtension: "css"),
              let s = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return s
    }
}
