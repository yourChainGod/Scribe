//
//  MarkdownConverter.swift
//  Phase 30 — pure-function Markdown → HTML converter for the
//  preview pane.
//
//  Why a hand-rolled converter: README pins "zero external SwiftPM
//  deps" as a project rule. Foundation's `AttributedString(markdown:)`
//  is HTML-output blind and Apple's swift-cmark would add a dep we
//  don't otherwise need. Hand-rolling ~300 LOC of CommonMark is
//  cheaper than the dep audit + cmark FFI.
//
//  Scope (v1):
//    - ATX headings (# … ######), trimming trailing # and whitespace
//    - paragraphs (blank-line-separated runs of plain text)
//    - fenced code blocks (``` and ~~~), language hint preserved as
//      `class="language-X"` for downstream highlighters
//    - inline code (`text`)
//    - bold (**text** / __text__) and italic (*text* / _text_)
//    - blockquotes (> prefix; consecutive `>` lines fold into one)
//    - ordered + unordered lists (-, *, +, 1.) — flat; nested lists
//      not handled in v1
//    - links [txt](url) and images ![alt](src)
//    - thematic breaks ---  ***  ___
//    - hard line break: trailing two spaces before LF
//    - HTML escape of stray <, >, &, " in literal text
//
//  Out of scope: tables, task lists, footnotes, GFM autolinks,
//  inline HTML, setext headings, reference-style links. The
//  preview is for "see what your README looks like" — the editor
//  remains the source of truth.
//
//  Tests live in `Tests/ScribeTests/MarkdownConverterTests.swift`.
//

import Foundation

enum MarkdownConverter {

    /// Render `markdown` as an HTML fragment. The output is the
    /// inner HTML of `<body>` — no `<html>` / `<body>` wrapper, no
    /// trailing newline. The caller (the WKWebView pane) wraps it
    /// in a styled HTML document.
    static func render(_ markdown: String) -> String {
        var ctx = BlockContext()
        // Normalise line endings so our linewise scan doesn't
        // blow up on Windows-saved CRLF or classic-Mac CR docs.
        let normalised = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r",   with: "\n")
        for line in normalised.split(separator: "\n",
                                     omittingEmptySubsequences: false) {
            ctx.process(line: String(line))
        }
        ctx.flushAll()
        return ctx.output.joined()
    }

    // MARK: - Block-level state machine

    /// Carries the ongoing block while we scan line by line.
    /// A new BlockContext is created per `render(_:)` call so we
    /// never share state between renders.
    fileprivate struct BlockContext {
        var output: [String] = []
        /// nil = not in a fenced code block. Otherwise the fence
        /// marker (``` or ~~~) used to open it; only an identical
        /// marker closes it.
        var fence: String? = nil
        /// Lines accumulated for the currently-open paragraph.
        /// Flushed when a block-level boundary is hit.
        var paragraph: [String] = []
        /// nil = not in a list. otherwise the list type (`ul` /
        /// `ol`) that's currently open.
        var list: String? = nil
        /// True between the opening <blockquote> and its matching
        /// </blockquote>; consecutive `> ` lines stay inside.
        var inBlockquote: Bool = false

        mutating func process(line: String) {
            // Fenced-code mode short-circuits everything else: the
            // *only* recognised token inside a fence is its closing
            // marker. Backticks / asterisks / list markers in here
            // are literal source code.
            if let mark = fence {
                if line.trimmingCharacters(in: .whitespaces) == mark {
                    output.append("</code></pre>\n")
                    fence = nil
                } else {
                    output.append(htmlEscape(line))
                    output.append("\n")
                }
                return
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Open a fenced code block. The optional language hint
            // after the marker becomes a class attribute so any
            // downstream highlighter (we don't ship one in v1) has
            // something to hook on.
            if let info = detectFence(trimmed) {
                flushParagraph()
                flushList()
                flushBlockquote()
                fence = info.mark
                if info.lang.isEmpty {
                    output.append("<pre><code>")
                } else {
                    output.append("<pre><code class=\"language-\(htmlEscape(info.lang))\">")
                }
                return
            }

            // A blank line ends every open inline block. The
            // paragraph / list / quote that follows starts fresh.
            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                flushBlockquote()
                return
            }

            // Thematic break — three or more matching --- *** ___
            // optionally separated by spaces. Must be on its own
            // line (we already required non-empty above).
            if isThematicBreak(trimmed) {
                flushParagraph()
                flushList()
                flushBlockquote()
                output.append("<hr/>\n")
                return
            }

            // ATX heading: 1–6 leading #, then a space, then content.
            // Trailing # and whitespace are stripped per CommonMark.
            if let (level, content) = matchHeading(trimmed) {
                flushParagraph()
                flushList()
                flushBlockquote()
                output.append("<h\(level)>")
                output.append(renderInline(content))
                output.append("</h\(level)>\n")
                return
            }

            // Blockquote: one or more leading `>`, optionally
            // followed by a space, then content. Consecutive
            // blockquoted lines fold into one <blockquote>; the
            // inside is rendered as a paragraph for now (no nested
            // headings/lists inside quotes in v1).
            if let inner = stripBlockquote(line) {
                flushParagraph()
                flushList()
                if !inBlockquote {
                    output.append("<blockquote>\n")
                    inBlockquote = true
                }
                output.append("<p>")
                output.append(renderInline(inner))
                output.append("</p>\n")
                return
            }

            // Unordered list item: line starts with -, *, or +,
            // followed by whitespace. Flat lists only; we don't
            // track indentation depth in v1.
            if let item = matchUnorderedListItem(line) {
                flushParagraph()
                flushBlockquote()
                if list != "ul" {
                    flushList()
                    output.append("<ul>\n")
                    list = "ul"
                }
                output.append("<li>")
                output.append(renderInline(item))
                output.append("</li>\n")
                return
            }

            // Ordered list item: digits, then `.` or `)`, then ws.
            if let item = matchOrderedListItem(line) {
                flushParagraph()
                flushBlockquote()
                if list != "ol" {
                    flushList()
                    output.append("<ol>\n")
                    list = "ol"
                }
                output.append("<li>")
                output.append(renderInline(item))
                output.append("</li>\n")
                return
            }

            // Default: text → paragraph buffer. The buffer is
            // emitted as one <p>…</p> when the block ends, joining
            // its lines with a literal space (so a soft wrap in
            // markdown source becomes a soft wrap in HTML too,
            // not a forced <br>).
            flushList()
            flushBlockquote()
            paragraph.append(line)
        }

        mutating func flushAll() {
            // Hitting EOF mid-fence is a malformed doc; we still
            // close the tags so the preview renders something
            // useful instead of leaking the open <pre>.
            if fence != nil {
                output.append("</code></pre>\n")
                fence = nil
            }
            flushParagraph()
            flushList()
            flushBlockquote()
        }

        mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            // CommonMark: hard break = trailing two spaces. We
            // implement it by replacing each "<line>  \n" boundary
            // with "<line><br/>" before joining. The simpler "join
            // with space" rule applies to the rest.
            var pieces: [String] = []
            for (i, raw) in paragraph.enumerated() {
                let hardBreak = raw.hasSuffix("  ")
                let trimmed = hardBreak
                    ? String(raw.dropLast(2))
                    : raw
                pieces.append(renderInline(trimmed))
                if i < paragraph.count - 1 {
                    pieces.append(hardBreak ? "<br/>" : " ")
                }
            }
            output.append("<p>")
            output.append(pieces.joined())
            output.append("</p>\n")
            paragraph.removeAll(keepingCapacity: false)
        }

        mutating func flushList() {
            guard let kind = list else { return }
            output.append("</\(kind)>\n")
            list = nil
        }

        mutating func flushBlockquote() {
            if inBlockquote {
                output.append("</blockquote>\n")
                inBlockquote = false
            }
        }
    }
}

// MARK: - Block detectors

/// Detect a fenced code-block opener on `trimmed` (already
/// whitespace-trimmed). Returns the fence marker + language hint
/// to record so the closing line can be matched verbatim.
private func detectFence(_ trimmed: String) -> (mark: String, lang: String)? {
    let mark: String
    if trimmed.hasPrefix("```") {
        mark = "```"
    } else if trimmed.hasPrefix("~~~") {
        mark = "~~~"
    } else {
        return nil
    }
    // Anything up to the next backtick / tilde is part of the
    // fence; everything after is the (optional) language hint.
    let rest = trimmed.dropFirst(mark.count)
    // Disallow info strings that contain the fence char — that's
    // a malformed open and we treat it as plain text.
    if rest.contains("`") || rest.contains("~") { return nil }
    let lang = rest.trimmingCharacters(in: .whitespaces)
    return (mark, lang)
}

/// `<hr/>` test: three or more of the same marker (-, *, _) with
/// only whitespace between them. CommonMark spec.
private func isThematicBreak(_ trimmed: String) -> Bool {
    for char in ["-", "*", "_"] as [Character] {
        let stripped = trimmed.filter { !$0.isWhitespace }
        if stripped.count >= 3, stripped.allSatisfy({ $0 == char }) {
            return true
        }
    }
    return false
}

/// Match an ATX heading. Returns (level, content) or nil. Up to 6
/// leading `#` chars, then one or more spaces, then the title.
/// Trailing `#` runs are stripped (`### Foo ###` → "Foo").
private func matchHeading(_ trimmed: String) -> (Int, String)? {
    var level = 0
    var idx = trimmed.startIndex
    while idx < trimmed.endIndex, trimmed[idx] == "#", level < 6 {
        level += 1
        idx = trimmed.index(after: idx)
    }
    guard level > 0 else { return nil }
    // Must be followed by a space; `#foo` is not a heading.
    guard idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
    var content = String(trimmed[idx...]).trimmingCharacters(in: .whitespaces)
    // Strip optional closing # run, e.g. `## Heading ##`.
    while content.hasSuffix("#") {
        content.removeLast()
    }
    return (level, content.trimmingCharacters(in: .whitespaces))
}

/// `> something` or just `>`. Returns the line minus the marker
/// and one optional space, or nil if the line isn't quoted.
private func stripBlockquote(_ line: String) -> String? {
    // Allow up to three leading spaces, then `>`. CommonMark
    // forbids more — that becomes an indented code block.
    var idx = line.startIndex
    var spaces = 0
    while idx < line.endIndex, line[idx] == " ", spaces < 3 {
        idx = line.index(after: idx)
        spaces += 1
    }
    guard idx < line.endIndex, line[idx] == ">" else { return nil }
    idx = line.index(after: idx)
    if idx < line.endIndex, line[idx] == " " {
        idx = line.index(after: idx)
    }
    return String(line[idx...])
}

/// Unordered list item: line begins with optional indent (≤3 sp),
/// then -, *, or +, then required whitespace, then content.
private func matchUnorderedListItem(_ line: String) -> String? {
    var idx = line.startIndex
    var spaces = 0
    while idx < line.endIndex, line[idx] == " ", spaces < 3 {
        idx = line.index(after: idx)
        spaces += 1
    }
    guard idx < line.endIndex,
          ["-", "*", "+"].contains(String(line[idx]))
    else { return nil }
    idx = line.index(after: idx)
    guard idx < line.endIndex, line[idx] == " " else { return nil }
    idx = line.index(after: idx)
    return String(line[idx...])
}

/// Ordered list item: digits, then `.` or `)`, then ws.
private func matchOrderedListItem(_ line: String) -> String? {
    var idx = line.startIndex
    var spaces = 0
    while idx < line.endIndex, line[idx] == " ", spaces < 3 {
        idx = line.index(after: idx)
        spaces += 1
    }
    var digits = 0
    while idx < line.endIndex, line[idx].isASCII, line[idx].isNumber {
        idx = line.index(after: idx)
        digits += 1
    }
    guard digits >= 1, digits <= 9 else { return nil }
    guard idx < line.endIndex, line[idx] == "." || line[idx] == ")" else { return nil }
    idx = line.index(after: idx)
    guard idx < line.endIndex, line[idx] == " " else { return nil }
    idx = line.index(after: idx)
    return String(line[idx...])
}

// MARK: - Inline rendering

/// Run inline transforms on `text` and return the resulting HTML.
/// The order matters: code spans go first so backtick-protected
/// content isn't disturbed by emphasis or link parsers; emphasis
/// runs after links so URLs containing `_` aren't broken up.
func renderInline(_ text: String) -> String {
    // Stage A: protect inline code spans by replacing them with
    // unique placeholders. Same trick for images and links so
    // the regexes downstream can't touch attribute contents.
    var slot: [String] = []
    func park(_ html: String) -> String {
        slot.append(html)
        return "\u{0001}\(slot.count - 1)\u{0001}"
    }

    var s = text
    s = replace(s, regex: "`([^`\n]+)`") { m in
        let inner = m[1]
        return park("<code>\(htmlEscape(inner))</code>")
    }
    s = replace(s, regex: "!\\[([^\\]]*)\\]\\(([^)\\s]+)(?:\\s+\"[^\"]*\")?\\)") { m in
        let alt = htmlEscape(m[1])
        let src = htmlEscape(m[2])
        return park("<img src=\"\(src)\" alt=\"\(alt)\"/>")
    }
    s = replace(s, regex: "\\[([^\\]]+)\\]\\(([^)\\s]+)(?:\\s+\"[^\"]*\")?\\)") { m in
        let label = m[1]
        let url = htmlEscape(m[2])
        // Recurse on the label so nested **bold** inside link
        // text still renders correctly.
        return park("<a href=\"\(url)\">\(renderInline(label))</a>")
    }

    // Stage B: bold / italic / strikethrough on the remaining text.
    // Bold first because `***x***` should land as nested emphasis;
    // if we did italic first we'd swallow the inner pair.
    //
    // The opening + closing tags are individually parked so the
    // stage-C HTML escape pass doesn't smother them. The inner
    // text stays inline so subsequent passes can keep parsing it
    // (that's how `***both***` ends up nested correctly).
    s = replace(s, regex: "\\*\\*([^*\n]+)\\*\\*") { m in
        park("<strong>") + m[1] + park("</strong>")
    }
    s = replace(s, regex: "__([^_\n]+)__") { m in
        park("<strong>") + m[1] + park("</strong>")
    }
    s = replace(s, regex: "\\*([^*\n]+)\\*") { m in
        park("<em>") + m[1] + park("</em>")
    }
    s = replace(s, regex: "(?<![A-Za-z0-9])_([^_\n]+)_(?![A-Za-z0-9])") { m in
        park("<em>") + m[1] + park("</em>")
    }
    s = replace(s, regex: "~~([^~\n]+)~~") { m in
        park("<del>") + m[1] + park("</del>")
    }

    // Stage C: HTML-escape the residual literal text. Placeholders
    // were inserted *after* their content was escaped, so they
    // pass through this step unchanged because \u{0001} survives
    // every escaping rule.
    s = htmlEscapePreservingPlaceholders(s)

    // Stage D: substitute placeholders back. Reverse order is
    // safe because placeholders never nest (we replaced left-to-
    // right; their indices in `slot` are independent).
    for (idx, html) in slot.enumerated() {
        s = s.replacingOccurrences(of: "\u{0001}\(idx)\u{0001}",
                                   with: html)
    }
    return s
}

// MARK: - Regex helper

/// Apply `regex` over `s`, calling `transform` with the captured
/// groups (groups[0] is the whole match) for each match. Matches
/// are replaced left-to-right; non-overlapping by definition.
private func replace(_ s: String,
                     regex pattern: String,
                     transform: ([String]) -> String) -> String {
    // swiftlint:disable:next force_try
    let re = try! NSRegularExpression(pattern: pattern)
    let ns = s as NSString
    var out = ""
    var cursor = 0
    let full = NSRange(location: 0, length: ns.length)
    re.enumerateMatches(in: s, options: [], range: full) { m, _, _ in
        guard let m else { return }
        let r = m.range
        if r.location > cursor {
            out += ns.substring(with: NSRange(location: cursor,
                                              length: r.location - cursor))
        }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let gr = m.range(at: i)
            groups.append(gr.location == NSNotFound
                          ? ""
                          : ns.substring(with: gr))
        }
        out += transform(groups)
        cursor = r.location + r.length
    }
    if cursor < ns.length {
        out += ns.substring(with: NSRange(location: cursor,
                                          length: ns.length - cursor))
    }
    return out
}

// MARK: - HTML escape helpers

/// Replace `<`, `>`, `&`, `"`, `'` with their HTML entities so
/// raw content can sit safely inside an HTML document.
func htmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&":  out += "&amp;"
        case "<":  out += "&lt;"
        case ">":  out += "&gt;"
        case "\"": out += "&quot;"
        case "'":  out += "&#39;"
        default:   out.append(ch)
        }
    }
    return out
}

/// HTML-escape, but pass through `\u{0001}N\u{0001}` placeholders
/// untouched so the slot substitution at the end of renderInline
/// finds the same delimiters it inserted.
private func htmlEscapePreservingPlaceholders(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        let ch = s[i]
        if ch == "\u{0001}" {
            // Copy through the placeholder verbatim.
            out.append(ch)
            i = s.index(after: i)
            while i < s.endIndex, s[i] != "\u{0001}" {
                out.append(s[i])
                i = s.index(after: i)
            }
            if i < s.endIndex {
                out.append(s[i])      // closing \u{0001}
                i = s.index(after: i)
            }
            continue
        }
        switch ch {
        case "&":  out += "&amp;"
        case "<":  out += "&lt;"
        case ">":  out += "&gt;"
        case "\"": out += "&quot;"
        case "'":  out += "&#39;"
        default:   out.append(ch)
        }
        i = s.index(after: i)
    }
    return out
}
