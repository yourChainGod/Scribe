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
//  Phase 32 additions (v2):
//    - GFM tables: `| h1 | h2 |` header + `| --- | :-: |` alignment
//      row, body rows until a blank line. 1-line lookahead via a
//      `pendingTableHeader` state so we don't have to switch the
//      whole engine to a buffered scan.
//    - Task lists: `- [ ]` / `- [x]` inside an unordered list emit
//      a disabled <input type="checkbox"> with the appropriate
//      `checked` attribute. Mixed task / non-task `<li>` in the
//      same list is fine — the marker is per-item.
//    - Footnotes: `[^id]: text` definitions are extracted in a
//      pre-pass; inline `[^id]` references become numbered <sup>
//      links to a `<section class="footnotes">` rendered at end-
//      of-doc. Definitions without references are dropped silently;
//      references without definitions stay literal.
//
//  Out of scope: code-block syntax highlighting, mermaid diagrams,
//  GFM autolinks, inline HTML, setext headings, reference-style
//  links. v3 material if the demand emerges.
//
//  Tests live in `Tests/ScribeTests/MarkdownConverterTests.swift`.
//

import Foundation

enum MarkdownConverter {

    /// Render `markdown` as an HTML fragment. The output is the
    /// inner HTML of `<body>` — no `<html>` / `<body>` wrapper, no
    /// trailing newline. The caller (the WKWebView pane) wraps it
    /// in a styled HTML document.
    ///
    /// Phase 51a — `baseDirectory` is the on-disk parent of the
    /// markdown file; relative `![](rel/img.png)` sources are
    /// rewritten to `file:///abs/rel/img.png` so WKWebView can
    /// actually load them. nil ⇒ legacy behaviour (raw src kept
    /// verbatim, broken-image icon if it's relative).
    ///
    /// Phase 51c — heading anchors. Each rendered `<hN>` gets a
    /// GitHub-flavoured slug as its `id` so `[link](#title)` works.
    /// Slug uniqueness is per-render: a doc with two identical
    /// headings emits `id="title"` and `id="title-1"`.
    static func render(_ markdown: String,
                       baseDirectory: URL? = nil) -> String {
        // Normalise line endings so our linewise scan doesn't
        // blow up on Windows-saved CRLF or classic-Mac CR docs.
        let normalised = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r",   with: "\n")
        // Phase 32 — footnote pre-pass: pulls `[^id]: text` definition
        // lines out of the source so the main walk doesn't see them as
        // paragraphs, then numbers each *referenced* id in encounter
        // order so the inline pass can emit `<sup>[N]</sup>` without
        // mutating BlockContext from inside `renderInline`.
        let prep = extractFootnotes(from: normalised)
        var ctx = BlockContext()
        ctx.footnoteRefs = prep.refs
        ctx.baseDirectory = baseDirectory
        // Phase 52a — scroll-sync plumbing. Every emitted block
        // carries a `data-source-line="<N>"` attribute pointing back
        // at the 1-based source line where the block started, so the
        // preview's JS reveal helper can map editor caret / scroll
        // position to the corresponding rendered element. We capture
        // the source line before dispatching each line; paragraph
        // start lines get tracked separately (see `paragraphStartLine`)
        // because a paragraph is emitted only when the *next* block
        // closes it, not at its opening line.
        for (idx, line) in prep.body.split(separator: "\n",
                                           omittingEmptySubsequences: false).enumerated() {
            ctx.currentSourceLine = idx + 1
            ctx.process(line: String(line))
        }
        ctx.flushAll()
        // The end-of-document `<section class="footnotes">` is only
        // emitted if at least one ref pointed at a real def. Defs
        // without refs are silently dropped; refs without defs stay
        // as literal text (the inline pass treats them as such).
        if !prep.orderedRefs.isEmpty {
            ctx.output.append(renderFootnoteSection(refs: prep.orderedRefs,
                                                    defs: prep.defs,
                                                    baseDirectory: baseDirectory))
        }
        return ctx.output.joined()
    }

    /// Phase 51c — GitHub-flavoured heading slug. Lowercases the
    /// title, replaces every run of "non slug-friendly" characters
    /// with a single `-`, trims leading / trailing dashes, and
    /// preserves Unicode letters / digits so a heading like
    /// "## 安装步骤" still gets a meaningful id (Safari's URL
    /// fragment resolver handles UTF-8 ids fine; the inline link
    /// `[跳转](#安装步骤)` works without further encoding).
    ///
    /// Inline markdown markup inside the title (`**bold**`, `*em*`,
    /// `` `code` ``) is stripped before slugging so a heading
    /// `## **Setup** notes` and `## Setup notes` produce the same
    /// `setup-notes` slug.
    ///
    /// Empty input returns the empty string; the per-render call
    /// site `uniqueSlug(for:)` swaps that for `"section"` so the
    /// emitted `id` attribute is always non-empty. Exposed as a
    /// `static` so the test suite can pin the slug shape without
    /// driving a full render.
    static func headingSlug(_ title: String) -> String {
        // Strip the most common inline markup so the slug isn't
        // contaminated by the asterisks / backticks / link brackets
        // the user wrote for emphasis. Underscores are NOT stripped
        // here because they're legal slug characters (GitHub keeps
        // them; `api_v2` should slug to `api_v2`, not `apiv2`).
        var stripped = ""
        stripped.reserveCapacity(title.count)
        for ch in title where ch != "*" && ch != "`"
            && ch != "[" && ch != "]" && ch != "(" && ch != ")" {
            stripped.append(ch)
        }
        let lower = stripped.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lower {
            // Keep ASCII alnum, `-`, `_`, and any non-ASCII letter
            // / digit (covers CJK, Cyrillic, Greek, accented
            // Latin). Whitespace and ASCII punctuation collapse
            // into a single dash separator.
            let keep: Bool = {
                if ch.isASCII {
                    return ch.isLetter || ch.isNumber
                        || ch == "-" || ch == "_"
                }
                return ch.isLetter || ch.isNumber
            }()
            if keep {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        // Trim dashes at both ends. Leading dashes come from inputs
        // like `---only---` where every leading character was a
        // literal dash the user typed; trailing dashes come from
        // the collapse above running off the end.
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out
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

        // Phase 32 — GFM tables. We need exactly one line of look-
        // ahead: a `| h1 | h2 |` row only becomes a table header
        // *if* the next line is `| --- | :-: |` shaped. We keep the
        // candidate header (verbatim, before pipe-splitting) here
        // and decide on the next call to `process(line:)`.
        var pendingTableHeader: String? = nil
        /// Per-column alignments of the open table, populated when
        /// the alignment row is consumed. nil ⇒ no table currently
        /// open; non-nil + empty array would be malformed.
        var tableAlignments: [TableAlign]? = nil

        // Phase 32 — footnotes. The pre-pass populates `footnoteRefs`
        // with `[id: number]` for *referenced + defined* ids only.
        // The inline pass reads it; it never writes back, so the
        // BlockContext doesn't need to mutate state from inside
        // `renderInline`.
        var footnoteRefs: [String: Int] = [:]

        /// Phase 51a — on-disk parent of the markdown file. Threaded
        /// through to `renderInline` so relative image sources can be
        /// rewritten to absolute `file:///` URLs (WKWebView can't
        /// load `rel/path.png` with a nil baseURL). nil = legacy
        /// behaviour, src kept verbatim.
        var baseDirectory: URL? = nil

        /// Phase 51c — slugs used so far in this render. A repeat
        /// heading title gets `-1`, `-2`, … appended to the slug so
        /// every `id` in the document is unique and `[link](#title)`
        /// always lands on the *first* occurrence (mirroring how
        /// GitHub renders READMEs).
        var usedSlugs: Set<String> = []

        /// Phase 52a — 1-based source line of the line being processed
        /// right now. Written by `render(_:baseDirectory:)` before
        /// each `process(line:)` call. Read by every emitter that
        /// opens a block-level element so the `data-source-line`
        /// attribute points back at the right spot in the editor.
        var currentSourceLine: Int = 0
        /// Phase 52a — source line of the first line accumulated for
        /// the currently-open `<p>`. Captured on paragraph open so
        /// `flushParagraph` can stamp the block with the start line
        /// rather than the (much later) closing line.
        var paragraphStartLine: Int = 0
        /// Phase 52a — source line the currently-open `<blockquote>`
        /// started on.
        var blockquoteStartLine: Int = 0
        /// Phase 52a — source line the currently-open `<ul>` / `<ol>`
        /// started on. Individual `<li>` elements carry their own
        /// source line independently so the preview can scroll to a
        /// specific item, not just the list's top.
        var listStartLine: Int = 0
        /// Phase 52a — source line the currently-open `<pre><code>`
        /// started on. Only meaningful while `fence != nil`.
        var fenceStartLine: Int = 0
        /// Phase 52a — source line the currently-open `<table>`
        /// started on (the header row, not the alignment row).
        var tableStartLine: Int = 0

        /// Build a `data-source-line="<N>"` attribute for the given
        /// 1-based line number, including the leading space so the
        /// caller can drop the return value directly into a tag.
        /// Accepts 0 as a "don't know / skip" sentinel — an element
        /// without a source line is better than one pointing at
        /// line 0, which would cause off-by-one weirdness in the
        /// JS reveal helper.
        func dsl(_ line: Int) -> String {
            guard line > 0 else { return "" }
            return " data-source-line=\"\(line)\""
        }

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

            // Phase 32 — table lookahead resolution. If the previous
            // call stashed a pipe row as a *candidate* header, this
            // call decides what to do with it:
            //   * current line is an alignment row    → open a table
            //   * current line is something else      → pending was
            //                                            never a table;
            //                                            re-emit it as
            //                                            a normal line
            //                                            and fall through
            //                                            to handle the
            //                                            current line.
            if let pending = pendingTableHeader {
                if let aligns = parseTableAlignmentRow(trimmed) {
                    pendingTableHeader = nil
                    flushParagraph()
                    flushList()
                    flushBlockquote()
                    openTable(header: pending, alignments: aligns)
                    return
                } else {
                    pendingTableHeader = nil
                    // The pending line gets re-processed as if the
                    // lookahead never happened — paragraphs / lists /
                    // blockquotes all get a fair shot.
                    processNonTable(line: pending,
                                    trimmed: pending.trimmingCharacters(in: .whitespaces))
                    // …then fall through to handle the current line.
                }
            }

            // While inside an open table, every pipe row is a body
            // row; any non-pipe line closes the table and is then
            // re-processed normally.
            if tableAlignments != nil {
                if isPipeRow(trimmed), !lineLooksLikeOtherBlock(line, trimmed: trimmed) {
                    appendTableRow(trimmed)
                    return
                } else {
                    closeTable()
                    // fall through to re-process this line.
                }
            }

            // GFM pipe-row stash gate — only top-level lines that
            // *aren't* already claimed by a more specific pattern
            // (heading / blockquote / list / fence / hr) get a shot
            // at being the head of a table. Otherwise `> | a |`
            // would silently lose its blockquote and `- | a |` would
            // lose its list item.
            if isPipeRow(trimmed),
               !lineLooksLikeOtherBlock(line, trimmed: trimmed) {
                pendingTableHeader = trimmed
                return
            }

            processNonTable(line: line, trimmed: trimmed)
        }

        /// Anything with its own block-level meaning. Used to keep
        /// the GFM table stash from greedily eating lines that
        /// belong to other blocks but happen to contain a `|`.
        private func lineLooksLikeOtherBlock(_ line: String,
                                             trimmed: String) -> Bool {
            if trimmed.isEmpty { return true }
            if detectFence(trimmed) != nil { return true }
            if isThematicBreak(trimmed) { return true }
            if matchHeading(trimmed) != nil { return true }
            if stripBlockquote(line) != nil { return true }
            if matchUnorderedListItem(line) != nil { return true }
            if matchOrderedListItem(line) != nil { return true }
            return false
        }

        /// Block dispatch for everything *except* the table-detection
        /// gate. Split out so the `pendingTableHeader` fallback path
        /// can re-feed a stashed line through it without re-entering
        /// the table check (which would just re-stash forever).
        mutating func processNonTable(line: String, trimmed: String) {
            // Open a fenced code block. The optional language hint
            // after the marker becomes a class attribute so any
            // downstream highlighter (we don't ship one in v1) has
            // something to hook on.
            if let info = detectFence(trimmed) {
                flushParagraph()
                flushList()
                flushBlockquote()
                fence = info.mark
                fenceStartLine = currentSourceLine
                // Phase 52a — stamp the `<pre>` (not `<code>`) with
                // the source line. The JS reveal helper queries
                // `[data-source-line]` at any DOM depth, and a
                // highlight-js run later will mutate the `<code>`
                // contents — putting the attribute on `<pre>` keeps
                // it out of hljs' way.
                if info.lang.isEmpty {
                    output.append("<pre\(dsl(fenceStartLine))><code>")
                } else {
                    output.append("<pre\(dsl(fenceStartLine))><code class=\"language-\(htmlEscape(info.lang))\">")
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
                output.append("<hr\(dsl(currentSourceLine))/>\n")
                return
            }

            // ATX heading: 1–6 leading #, then a space, then content.
            // Trailing # and whitespace are stripped per CommonMark.
            // Phase 51c — also emit a unique `id` so anchor links
            // (`[link](#title)`) and the in-app TOC work without
            // a JS pass.
            if let (level, content) = matchHeading(trimmed) {
                flushParagraph()
                flushList()
                flushBlockquote()
                let slug = uniqueSlug(for: content)
                output.append("<h\(level) id=\"\(htmlEscape(slug))\"\(dsl(currentSourceLine))>")
                output.append(renderInline(content,
                                           footnoteRefs: footnoteRefs,
                                           baseDirectory: baseDirectory))
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
                    // Phase 52a — stamp the `<blockquote>` with the
                    // line it opened on; every inner `<p>` is also
                    // stamped with its own line so a multi-line quote
                    // can be scrolled to a specific paragraph inside.
                    blockquoteStartLine = currentSourceLine
                    output.append("<blockquote\(dsl(blockquoteStartLine))>\n")
                    inBlockquote = true
                }
                output.append("<p\(dsl(currentSourceLine))>")
                output.append(renderInline(inner,
                                           footnoteRefs: footnoteRefs,
                                           baseDirectory: baseDirectory))
                output.append("</p>\n")
                return
            }

            // Unordered list item: line starts with -, *, or +,
            // followed by whitespace. Flat lists only; we don't
            // track indentation depth in v1. Phase 32 — task-list
            // marker `[ ]` / `[x]` immediately after the bullet
            // upgrades the <li> to a checkbox.
            if let item = matchUnorderedListItem(line) {
                flushParagraph()
                flushBlockquote()
                if list != "ul" {
                    flushList()
                    // Phase 52a — `<ul>` gets the source line of its
                    // first item; each `<li>` is also stamped
                    // individually below so a scroll can land on a
                    // specific row rather than the list's top.
                    listStartLine = currentSourceLine
                    output.append("<ul\(dsl(listStartLine))>\n")
                    list = "ul"
                }
                if let task = matchTaskMarker(item) {
                    let checkedAttr = task.checked ? " checked" : ""
                    // Phase 53b — checkbox is *not* disabled: the
                    // preview's click handler (see
                    // `revealLineScript`) calls `preventDefault()`
                    // so the browser never actually flips the DOM
                    // state, then posts the source line to Swift.
                    // The editor performs the markdown edit; the
                    // preview re-renders with the new `checked`
                    // attribute, which keeps markdown text as the
                    // single source of truth. The `scribe-task`
                    // class lets the click handler match just our
                    // checkboxes without snagging stray
                    // `<input type="checkbox">` elements a
                    // document might contain inside a raw HTML
                    // block.
                    output.append(
                        "<li class=\"task-list-item\"\(dsl(currentSourceLine))>"
                        + "<input type=\"checkbox\" class=\"scribe-task\"\(checkedAttr)/> "
                    )
                    output.append(renderInline(task.content,
                                               footnoteRefs: footnoteRefs,
                                               baseDirectory: baseDirectory))
                    output.append("</li>\n")
                } else {
                    output.append("<li\(dsl(currentSourceLine))>")
                    output.append(renderInline(item,
                                               footnoteRefs: footnoteRefs,
                                               baseDirectory: baseDirectory))
                    output.append("</li>\n")
                }
                return
            }

            // Ordered list item: digits, then `.` or `)`, then ws.
            if let item = matchOrderedListItem(line) {
                flushParagraph()
                flushBlockquote()
                if list != "ol" {
                    flushList()
                    listStartLine = currentSourceLine
                    output.append("<ol\(dsl(listStartLine))>\n")
                    list = "ol"
                }
                output.append("<li\(dsl(currentSourceLine))>")
                output.append(renderInline(item,
                                           footnoteRefs: footnoteRefs,
                                           baseDirectory: baseDirectory))
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
            // Phase 52a — capture the paragraph's opening source
            // line on first accumulation. `flushParagraph` stamps
            // `<p>` with this, not the closing line.
            if paragraph.isEmpty {
                paragraphStartLine = currentSourceLine
            }
            paragraph.append(line)
        }

        /// Phase 51c — turn a heading title into a unique slug for
        /// the `id` attribute. Delegates the slug shape to the
        /// static helper (so tests can lock that contract in
        /// isolation) and adds `-1`, `-2`, … if a doc has duplicate
        /// titles. Empty / punctuation-only titles fall back to
        /// "section" so the id attribute is always non-empty.
        mutating func uniqueSlug(for title: String) -> String {
            let base = MarkdownConverter.headingSlug(title)
            let root = base.isEmpty ? "section" : base
            if usedSlugs.insert(root).inserted {
                return root
            }
            var n = 1
            while !usedSlugs.insert("\(root)-\(n)").inserted {
                n += 1
            }
            return "\(root)-\(n)"
        }

        mutating func flushAll() {
            // Hitting EOF mid-fence is a malformed doc; we still
            // close the tags so the preview renders something
            // useful instead of leaking the open <pre>.
            if fence != nil {
                output.append("</code></pre>\n")
                fence = nil
            }
            // Phase 32 — a `pendingTableHeader` at EOF was a false
            // alarm: the file ended before its alignment row would
            // have arrived. Re-emit it as a normal paragraph line
            // so we don't silently swallow the user's content.
            if let pending = pendingTableHeader {
                pendingTableHeader = nil
                processNonTable(line: pending,
                                trimmed: pending.trimmingCharacters(in: .whitespaces))
            }
            flushParagraph()
            flushList()
            flushBlockquote()
            // tableAlignments may still be set if the table ran up
            // to EOF without a separator blank line — close it now.
            if tableAlignments != nil { closeTable() }
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
                pieces.append(renderInline(trimmed,
                                           footnoteRefs: footnoteRefs,
                                           baseDirectory: baseDirectory))
                if i < paragraph.count - 1 {
                    pieces.append(hardBreak ? "<br/>" : " ")
                }
            }
            output.append("<p\(dsl(paragraphStartLine))>")
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

        // MARK: - Phase 32 · Table helpers

        /// Open `<table><thead><tr>…</tr></thead><tbody>` for a
        /// freshly-confirmed GFM table. The pipe-split + alignment
        /// translation is done here so the per-row logic only has
        /// to call `appendTableRow`.
        mutating func openTable(header: String, alignments: [TableAlign]) {
            tableAlignments = alignments
            let cells = splitTableCells(header)
            // Phase 52a — stamp `<table>` with the header row's
            // source line. The alignment row is consumed implicitly
            // (no `<tr>` emitted for it), and body `<tr>` rows
            // already carry their own source line via
            // `appendTableRow`. A line that scrolls to the table
            // lands on the header, which is the expected UX.
            tableStartLine = currentSourceLine - 1
            output.append("<table\(dsl(tableStartLine))>\n<thead>\n<tr\(dsl(tableStartLine))>")
            for (i, raw) in cells.enumerated() {
                let align = i < alignments.count ? alignments[i] : .none
                output.append("<th\(align.styleAttr)>")
                output.append(renderInline(raw,
                                           footnoteRefs: footnoteRefs,
                                           baseDirectory: baseDirectory))
                output.append("</th>")
            }
            output.append("</tr>\n</thead>\n<tbody>\n")
        }

        /// Emit one body `<tr>…</tr>` for an already-confirmed pipe
        /// row. Cells past `tableAlignments.count` are dropped (GFM
        /// behaviour); rows with fewer cells are right-padded with
        /// empty `<td>`s so the column count stays uniform.
        mutating func appendTableRow(_ row: String) {
            guard let aligns = tableAlignments else { return }
            let cells = splitTableCells(row)
            output.append("<tr\(dsl(currentSourceLine))>")
            for col in 0..<aligns.count {
                let raw = col < cells.count ? cells[col] : ""
                output.append("<td\(aligns[col].styleAttr)>")
                output.append(renderInline(raw,
                                           footnoteRefs: footnoteRefs,
                                           baseDirectory: baseDirectory))
                output.append("</td>")
            }
            output.append("</tr>\n")
        }

        /// Close the open table.
        mutating func closeTable() {
            output.append("</tbody>\n</table>\n")
            tableAlignments = nil
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
///
/// Phase 45-B-5 — single-pass scan replaces `trimmed.filter {...}`
/// run three times. The lorem-prose hot path now bails on the
/// first non-whitespace character (typically 'L'), avoiding three
/// per-row 80-byte String copies × 65 k rows.
private func isThematicBreak(_ trimmed: String) -> Bool {
    var marker: Character? = nil
    var count = 0
    for ch in trimmed {
        if ch.isWhitespace { continue }
        if ch == "-" || ch == "*" || ch == "_" {
            if let m = marker {
                if m != ch { return false }
            } else {
                marker = ch
            }
            count += 1
        } else {
            return false
        }
    }
    return marker != nil && count >= 3
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

// MARK: - Inline regex cache

// Phase 45-B perf — pre-compile every inline regex exactly once at
// load time. Before this, `replace(...)` re-compiled the same nine
// patterns for every line of every paragraph, which dominated the
// 5 MB MarkdownConverter.render baseline (~4.5 s, perf_audit.md
// § 1.2). NSRegularExpression is documented thread-safe, so a
// shared instance is fine across calls.
private let mdInlineCodeRegex = try! NSRegularExpression(
    pattern: "`([^`\n]+)`")
private let mdInlineImageRegex = try! NSRegularExpression(
    pattern: "!\\[([^\\]]*)\\]\\(([^)\\s]+)(?:\\s+\"[^\"]*\")?\\)")

/// Phase 51a — image and link source resolver. WKWebView with a
/// nil baseURL can't load relative paths, so the converter rewrites
/// `./img.png` / `assets/x.png` / `../shared/y.png` into absolute
/// `file:///abs/path` URLs the moment we know the markdown file's
/// on-disk parent. Already-absolute references (`https://`, `data:`,
/// `mailto:`, `file://`, `/abs/`, `#anchor`) pass through untouched
/// so we don't damage anything that already works.
///
/// Static so the unit test can pin the contract without spinning
/// up a full render.
func resolveResourceURL(_ raw: String, baseDirectory: URL?) -> String {
    // Empty or anchor-only — let the browser deal with it.
    guard !raw.isEmpty else { return raw }
    if raw.hasPrefix("#") { return raw }
    // No baseDirectory ⇒ legacy behaviour: keep raw as-is. Test
    // suites that don't care about path resolution still get the
    // exact string they used to.
    guard let base = baseDirectory else { return raw }
    // Anything with a scheme (https:, http:, mailto:, file:, data:,
    // tel:, etc.) is already absolute by definition. We detect a
    // scheme as `[A-Za-z][A-Za-z0-9+.\-]*:` so the heuristic
    // doesn't get fooled by a Windows-style `C:` either — but that
    // pattern is rare enough we accept the false-positive cost
    // (`C:/foo.png` would stay raw, which is what the user wrote).
    if let colon = raw.firstIndex(of: ":") {
        let scheme = raw[..<colon]
        if !scheme.isEmpty, scheme.allSatisfy({ ch in
            ch.isLetter || ch.isNumber || ch == "+" || ch == "-" || ch == "."
        }) {
            return raw
        }
    }
    // Already an absolute POSIX path — wrap as file://.
    if raw.hasPrefix("/") {
        return URL(fileURLWithPath: raw).absoluteString
    }
    // Relative — resolve against base. URL(string:relativeTo:) is
    // the wrong tool here (it percent-decodes / re-encodes); we
    // want byte-faithful path appending so the user's filename
    // ends up at the same on-disk path they typed.
    let resolved = base.appendingPathComponent(raw)
        .standardizedFileURL
    return resolved.absoluteString
}
private let mdInlineFootnoteRefRegex = try! NSRegularExpression(
    pattern: "\\[\\^([^\\]\\s]+)\\]")
private let mdInlineLinkRegex = try! NSRegularExpression(
    pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)(?:\\s+\"[^\"]*\")?\\)")
private let mdInlineBoldStarRegex = try! NSRegularExpression(
    pattern: "\\*\\*([^*\n]+)\\*\\*")
private let mdInlineBoldUnderscoreRegex = try! NSRegularExpression(
    pattern: "__([^_\n]+)__")
private let mdInlineEmStarRegex = try! NSRegularExpression(
    pattern: "\\*([^*\n]+)\\*")
private let mdInlineEmUnderscoreRegex = try! NSRegularExpression(
    pattern: "(?<![A-Za-z0-9])_([^_\n]+)_(?![A-Za-z0-9])")
private let mdInlineStrikeRegex = try! NSRegularExpression(
    pattern: "~~([^~\n]+)~~")

/// Phase 45-B-4 — single-pass byte sweep that decides whether a
/// line could possibly hit any inline-pattern regex. The trigger
/// set is the union of opener bytes for all nine patterns:
/// backtick (code), `!` (image), `[` (footnote ref + link),
/// `*` `_` (bold + emphasis), `~` (strikethrough). Lines with
/// none of these can never match and are routed straight to the
/// HTML escaper.
private func inlineNeedsRewrite(_ s: String) -> Bool {
    for byte in s.utf8 {
        switch byte {
        case 0x60,  // `
             0x21,  // !
             0x5B,  // [
             0x2A,  // *
             0x5F,  // _
             0x7E:  // ~
            return true
        default:
            continue
        }
    }
    return false
}

// MARK: - Inline rendering
/// The order matters: code spans go first so backtick-protected
/// content isn't disturbed by emphasis or link parsers; emphasis
/// runs after links so URLs containing `_` aren't broken up.
///
/// Phase 32 — `footnoteRefs` is a `[id: number]` map populated by
/// the pre-pass for ids that have both a definition *and* at least
/// one inline reference. Defaults to empty so v1 callers (and the
/// recursive call inside link labels) keep working unchanged.
///
/// Phase 45-B-4 — fast-path: a single UTF-8 byte sweep checks
/// whether the line contains *any* character that could trigger
/// the inline regex chain. If not (the lorem-prose hot path), we
/// skip the nine `enumerateMatches` calls entirely and feed the
/// line straight to the HTML escaper. This is the difference
/// between scanning 80 ASCII bytes once vs. nine times per
/// paragraph row.
func renderInline(_ text: String,
                  footnoteRefs: [String: Int] = [:],
                  baseDirectory: URL? = nil) -> String {
    if !inlineNeedsRewrite(text) {
        return htmlEscape(text)
    }
    // Stage A: protect inline code spans by replacing them with
    // unique placeholders. Same trick for images and links so
    // the regexes downstream can't touch attribute contents.
    var slot: [String] = []
    func park(_ html: String) -> String {
        slot.append(html)
        return "\u{0001}\(slot.count - 1)\u{0001}"
    }

    var s = text
    s = replace(s, regex: mdInlineCodeRegex) { m in
        let inner = m[1]
        return park("<code>\(htmlEscape(inner))</code>")
    }
    s = replace(s, regex: mdInlineImageRegex) { m in
        let alt = htmlEscape(m[1])
        let resolved = resolveResourceURL(m[2], baseDirectory: baseDirectory)
        let src = htmlEscape(resolved)
        return park("<img src=\"\(src)\" alt=\"\(alt)\"/>")
    }
    // Phase 32 — footnote reference pass *before* the link parser:
    // the `[^id]` syntax would otherwise be greedily parsed as a
    // label-only `[txt]` literal. We only convert ids that the
    // pre-pass tagged with a number (i.e. both referenced + defined);
    // unknown ids fall through to literal text via the link / escape
    // chain below.
    if !footnoteRefs.isEmpty {
        s = replace(s, regex: mdInlineFootnoteRefRegex) { m in
            let id = m[1]
            guard let num = footnoteRefs[id] else { return m[0] }
            let safeId = htmlEscape(id)
            return park(
                "<sup class=\"footnote-ref\"><a href=\"#fn-\(safeId)\" "
                + "id=\"fnref-\(safeId)\">[\(num)]</a></sup>"
            )
        }
    }
    s = replace(s, regex: mdInlineLinkRegex) { m in
        let label = m[1]
        // Phase 51a — same resolver as image src. Anchor links
        // (`#section`) and absolute URLs (`https://`, `mailto:`)
        // pass through untouched; relative `./other.md` becomes
        // `file:///abs/other.md` so a click in the preview opens
        // the right file in the user's default app.
        let resolved = resolveResourceURL(m[2], baseDirectory: baseDirectory)
        let url = htmlEscape(resolved)
        // Recurse on the label so nested **bold** inside link
        // text still renders correctly. Forward the footnote map so
        // a `[link with ^[ref]](url)` inside a label still works.
        return park("<a href=\"\(url)\">\(renderInline(label, footnoteRefs: footnoteRefs, baseDirectory: baseDirectory))</a>")
    }

    // Stage B: bold / italic / strikethrough on the remaining text.
    // Bold first because `***x***` should land as nested emphasis;
    // if we did italic first we'd swallow the inner pair.
    //
    // The opening + closing tags are individually parked so the
    // stage-C HTML escape pass doesn't smother them. The inner
    // text stays inline so subsequent passes can keep parsing it
    // (that's how `***both***` ends up nested correctly).
    s = replace(s, regex: mdInlineBoldStarRegex) { m in
        park("<strong>") + m[1] + park("</strong>")
    }
    s = replace(s, regex: mdInlineBoldUnderscoreRegex) { m in
        park("<strong>") + m[1] + park("</strong>")
    }
    s = replace(s, regex: mdInlineEmStarRegex) { m in
        park("<em>") + m[1] + park("</em>")
    }
    s = replace(s, regex: mdInlineEmUnderscoreRegex) { m in
        park("<em>") + m[1] + park("</em>")
    }
    s = replace(s, regex: mdInlineStrikeRegex) { m in
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
///
/// Phase 45-B — takes a pre-compiled `NSRegularExpression` so the
/// hot inline pass can amortise pattern compilation across all
/// calls. The shared instances live at file scope above the
/// inline pass.
///
/// Phase 45-B-2 — fast-path zero-match lines. If `enumerateMatches`
/// never fires the callback we return the original `s` untouched —
/// no `out` String allocation, no NSString.substring copy of the
/// whole line. Lorem-prose paragraphs exercise this on every one
/// of the nine inline patterns × every paragraph row, which is
/// the hot loop revealed by the 5 MB MarkdownConverter baseline.
private func replace(_ s: String,
                     regex re: NSRegularExpression,
                     transform: ([String]) -> String) -> String {
    let ns = s as NSString
    var out = ""
    var cursor = 0
    var hasMatch = false
    let full = NSRange(location: 0, length: ns.length)
    re.enumerateMatches(in: s, options: [], range: full) { m, _, _ in
        guard let m else { return }
        hasMatch = true
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
    guard hasMatch else { return s }
    if cursor < ns.length {
        out += ns.substring(with: NSRange(location: cursor,
                                          length: ns.length - cursor))
    }
    return out
}

// MARK: - HTML escape helpers

/// Replace `<`, `>`, `&`, `"`, `'` with their HTML entities so
/// raw content can sit safely inside an HTML document.
///
/// Phase 45-B-3 — fast-path: if the input contains zero of the
/// five entity-trigger characters, return it as-is. Lorem-prose
/// paragraphs hit this path on every one of their 65 k flush
/// rows, eliminating one full char-level rebuild per row.
func htmlEscape(_ s: String) -> String {
    if !htmlEscapeNeedsRewrite(s) {
        return s
    }
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

/// Cheap prefix check shared by both escape paths. UTF-8 byte scan
/// avoids the per-Character overhead of `for ch in s` when the
/// answer is "nothing to do" — the lorem-prose flush hot path.
private func htmlEscapeNeedsRewrite(_ s: String) -> Bool {
    for byte in s.utf8 {
        switch byte {
        case 0x26, 0x3C, 0x3E, 0x22, 0x27, 0x01:
            // & < > " '   — entity triggers
            // \u{0001}    — placeholder marker (only meaningful for
            //               htmlEscapePreservingPlaceholders, but
            //               adding it here costs nothing and lets
            //               both paths share one scan)
            return true
        default:
            continue
        }
    }
    return false
}

// MARK: - Phase 32 · GFM tables

/// Per-column alignment for a GFM table. `none` = whatever the
/// browser's default is for that cell type (left for `<td>`,
/// center for `<th>`); the others emit `text-align:` inline so
/// the preview doesn't depend on a stylesheet shipping the rule.
enum TableAlign: Sendable, Equatable {
    case none, left, right, center

    var styleAttr: String {
        switch self {
        case .none:   return ""
        case .left:   return " style=\"text-align:left\""
        case .right:  return " style=\"text-align:right\""
        case .center: return " style=\"text-align:center\""
        }
    }
}

/// True when the trimmed line contains at least one pipe — the
/// minimal GFM signal that this *might* be a table row. The
/// real "is this a table?" decision is gated by the next-line
/// alignment row in BlockContext.process.
fileprivate func isPipeRow(_ trimmed: String) -> Bool {
    trimmed.contains("|")
}

/// Split a `| a | b | c |` row into `["a", "b", "c"]`. Optional
/// leading / trailing pipes are tolerated (GFM allows both styled
/// and bare pipe rows). Cells are trimmed of surrounding spaces;
/// inline emphasis / code remains for the inline pass.
///
/// v1 simplification: backslash-escaped pipes (`\|`) are treated
/// as cell separators just like a bare `|`. Real-world tables
/// almost never need them and supporting it costs a state-machine
/// scan we'd rather avoid.
fileprivate func splitTableCells(_ row: String) -> [String] {
    var s = row.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("|") { s.removeFirst() }
    if s.hasSuffix("|") { s.removeLast() }
    return s.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

/// Parse `| --- | :-- | --: | :-: |` style alignment rows.
/// Returns the per-column `TableAlign` array, or nil when the
/// line isn't shaped like an alignment row at all.
///
/// Acceptance criteria per cell:
///   - one or more `-` (≥3 in spec but we permit 1+ for tolerance)
///   - optional leading / trailing `:` flagging alignment
///   - only `-`, `:`, and whitespace characters
fileprivate func parseTableAlignmentRow(_ trimmed: String) -> [TableAlign]? {
    if !trimmed.contains("|") { return nil }
    let cells = splitTableCells(trimmed)
    guard !cells.isEmpty else { return nil }
    var aligns: [TableAlign] = []
    for raw in cells {
        let cell = raw.trimmingCharacters(in: .whitespaces)
        guard !cell.isEmpty else { return nil }
        let leftColon  = cell.hasPrefix(":")
        let rightColon = cell.hasSuffix(":")
        // Strip the optional colons; what's left must be all '-'.
        var inner = cell
        if leftColon  { inner.removeFirst() }
        if rightColon { inner.removeLast() }
        guard !inner.isEmpty,
              inner.allSatisfy({ $0 == "-" }) else { return nil }
        switch (leftColon, rightColon) {
        case (true, true):   aligns.append(.center)
        case (true, false):  aligns.append(.left)
        case (false, true):  aligns.append(.right)
        case (false, false): aligns.append(.none)
        }
    }
    return aligns
}

// MARK: - Phase 32 · Task list markers

/// Match GFM task-list markers immediately after the bullet:
///   `[ ] foo`   → (false, "foo")
///   `[x] bar`   → (true,  "bar")
///   `[X] baz`   → (true,  "baz")
/// Anything else returns nil and the caller emits a normal `<li>`.
fileprivate func matchTaskMarker(_ content: String) -> (checked: Bool, content: String)? {
    guard content.hasPrefix("[") else { return nil }
    let chars = Array(content)
    // Need at least "[ ] " or "[x] ".
    guard chars.count >= 4 else { return nil }
    guard chars[2] == "]", chars[3] == " " else { return nil }
    let mark = chars[1]
    let checked: Bool
    switch mark {
    case " ":         checked = false
    case "x", "X":    checked = true
    default:          return nil
    }
    let rest = String(chars[4...])
    return (checked, rest)
}

// MARK: - Phase 32 · Footnotes

/// Result of the footnote pre-pass.
fileprivate struct FootnoteExtraction {
    /// Source with definition lines (`[^id]: text`) blanked out so
    /// the main walk doesn't render them as paragraphs.
    let body: String
    /// `id → text` for every parsed definition (whether or not
    /// any reference points at it).
    let defs: [String: String]
    /// `id → 1-based number` for ids that have **both** a
    /// definition and at least one inline reference. Inline
    /// rendering only emits sup/anchor tags for these.
    let refs: [String: Int]
    /// `(id, num)` tuples in encounter order — used to render
    /// the `<ol>` at end of doc in stable, predictable sequence.
    let orderedRefs: [(id: String, num: Int)]
}

/// Two-pass scan: pull `[^id]: text` definition lines out of the
/// source (replacing them with blank lines so paragraph state
/// machines stay happy), then number every `[^id]` reference
/// pointing at a parsed definition in encounter order.
fileprivate func extractFootnotes(from text: String) -> FootnoteExtraction {
    var defs: [String: String] = [:]
    var bodyLines: [String] = []
    let defRegex = try! NSRegularExpression(  // swiftlint:disable:this force_try
        pattern: "^\\s*\\[\\^([^\\]\\s]+)\\]:\\s*(.*)$"
    )
    for raw in text.split(separator: "\n",
                          omittingEmptySubsequences: false) {
        let line = String(raw)
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        if let match = defRegex.firstMatch(in: line, options: [], range: range) {
            let id   = nsLine.substring(with: match.range(at: 1))
            let txt  = nsLine.substring(with: match.range(at: 2))
            defs[id] = txt
            // Replace the def line with a blank one so a definition
            // sandwiched inside a paragraph causes the paragraph to
            // close, matching GFM's "definitions are block-level"
            // behaviour.
            bodyLines.append("")
        } else {
            bodyLines.append(line)
        }
    }
    let body = bodyLines.joined(separator: "\n")

    // Pass 2 — number references in encounter order, but only for
    // ids that actually have a definition (otherwise the ref
    // stays literal in renderInline).
    var refs: [String: Int] = [:]
    var ordered: [(id: String, num: Int)] = []
    let refRegex = try! NSRegularExpression(  // swiftlint:disable:this force_try
        pattern: "\\[\\^([^\\]\\s]+)\\]"
    )
    let nsBody = body as NSString
    refRegex.enumerateMatches(in: body, options: [],
                              range: NSRange(location: 0, length: nsBody.length)) { m, _, _ in
        guard let m else { return }
        let id = nsBody.substring(with: m.range(at: 1))
        guard defs[id] != nil else { return }
        if refs[id] != nil { return }     // first encounter wins
        let n = ordered.count + 1
        refs[id] = n
        ordered.append((id, n))
    }
    return FootnoteExtraction(body: body, defs: defs,
                              refs: refs, orderedRefs: ordered)
}

/// Build the `<section class="footnotes">…</section>` block that
/// closes the document. Only ids in `refs` are listed — defs
/// without a reference are silently dropped, matching how every
/// modern markdown engine handles them.
fileprivate func renderFootnoteSection(
    refs orderedRefs: [(id: String, num: Int)],
    defs: [String: String],
    baseDirectory: URL? = nil
) -> String {
    var out = "<section class=\"footnotes\">\n<hr/>\n<ol>\n"
    for entry in orderedRefs {
        guard let body = defs[entry.id] else { continue }
        let safeId = htmlEscape(entry.id)
        // Render the def text inline so emphasis / links / inline
        // code work inside footnote bodies. We deliberately don't
        // forward `footnoteRefs` here — nested footnote references
        // inside footnote definitions aren't supported in v1.
        // Phase 51a — forward baseDirectory so a footnote pointing
        // at `[caption](./fig.png)` resolves the same way an inline
        // image would.
        let bodyHTML = renderInline(body, baseDirectory: baseDirectory)
        out += "<li id=\"fn-\(safeId)\">\(bodyHTML) "
        out += "<a href=\"#fnref-\(safeId)\" class=\"footnote-back\" "
        out += "aria-label=\"Back to reference\">↩</a></li>\n"
    }
    out += "</ol>\n</section>\n"
    return out
}

// MARK: - HTML escape helpers
/// HTML-escape, but pass through `\u{0001}N\u{0001}` placeholders
/// untouched so the slot substitution at the end of renderInline
/// finds the same delimiters it inserted.
///
/// Phase 45-B-3 — fast-path: if there are no entity-trigger chars
/// and no placeholder markers, return the input unchanged. The
/// lorem-prose hot path takes this branch.
private func htmlEscapePreservingPlaceholders(_ s: String) -> String {
    if !htmlEscapeNeedsRewrite(s) {
        return s
    }
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
