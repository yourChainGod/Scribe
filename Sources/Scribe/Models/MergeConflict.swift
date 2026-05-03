//
//  MergeConflict.swift
//  Phase 68 — pure-data model + parser for the git conflict markers
//  that show up in working-tree files after a `git merge`,
//  `git pull`, or `git rebase` runs into divergent edits. The parser
//  is the foundation under the editor overlay's accept buttons:
//  it locates every well-formed `<<<<<<< … >>>>>>>` block in a
//  document and reports the textual ranges + label metadata the
//  resolver and overlay layers need to render Accept Current /
//  Incoming / Both.
//
//  We deliberately model the parser as a pure function from
//  `String → [MergeConflict]` (no actor isolation, no Combine,
//  no IO) so unit tests can exercise every state-machine branch
//  without spinning up a Workspace.
//

import Foundation

/// A single git merge / rebase conflict block recovered from a
/// document's text. Holds the byte range plus the three (or four,
/// for diff3 style) sub-payloads the resolver needs.
///
/// `range` is in NSString utf16 units so it composes directly with
/// Scintilla's character-based APIs and with `NSAttributedString`
/// replacement. `startLine` / `endLine` are 1-based to match the
/// conventions every other engine in this project uses (Outline,
/// Git gutter, Inline Blame).
struct MergeConflict: Equatable, Identifiable {
    /// Stable ID per parse. Two parses of the same text produce
    /// different UUIDs — the engine layer handles equality through
    /// `Equatable` instead. Conforming to `Identifiable` lets
    /// SwiftUI lists / overlays diff cleanly without us inventing
    /// a synthetic key.
    let id: UUID

    /// utf16 character range covering everything from the
    /// `<<<<<<<` line through the `>>>>>>>` line, inclusive of the
    /// trailing newline that follows the closing marker if present.
    /// Suitable for direct `NSString.replaceCharacters(in:with:)` /
    /// Scintilla replaceTarget calls.
    let range: NSRange

    /// 1-based line number of the `<<<<<<<` marker.
    let startLine: Int

    /// 1-based line number of the `>>>>>>>` marker.
    let endLine: Int

    /// "ours" payload — the text between `<<<<<<<` and either
    /// `|||||||` (diff3) or `=======` (default). Stored without
    /// surrounding marker lines and without a trailing newline so
    /// the resolver can decide on its own whether to add one.
    let currentText: String

    /// "theirs" payload — the text between `=======` and `>>>>>>>`.
    let incomingText: String

    /// Diff3 ancestor section (`|||||||` … `=======`). `nil` for
    /// the default 2-way conflict style; non-nil only when git was
    /// configured with `merge.conflictStyle = diff3`.
    let baseText: String?

    /// Label after `<<<<<<<` — typically `"HEAD"`, sometimes a SHA
    /// or "ours". Empty string when git omitted the label.
    let currentLabel: String

    /// Label after `>>>>>>>` — typically the merged-in branch name.
    let incomingLabel: String

    /// Label after `|||||||` (diff3 only). `nil` when there is no
    /// ancestor block.
    let baseLabel: String?
}

/// Pure state-machine parser for git conflict markers. The scan is
/// O(N) over the document text and never allocates more than the
/// per-conflict line buffers it returns, so callers can re-run it
/// on every keystroke (Workspace's debounced text sink does
/// exactly that).
enum MergeConflictParser {

    /// Walk `text` line by line, emit one `MergeConflict` per
    /// well-formed `<<<<<<< … >>>>>>>` block. Malformed blocks
    /// (markers in the wrong order, unterminated blocks, nested
    /// `<<<<<<<` inside an open conflict) are silently dropped so
    /// a partially-edited file doesn't surface garbage rows in the
    /// editor overlay.
    static func parse(_ text: String) -> [MergeConflict] {
        guard !text.isEmpty else { return [] }
        let nsString = text as NSString
        let totalLength = nsString.length
        var results: [MergeConflict] = []

        // State machine — `idle` outside a conflict, then one stage
        // per body section. Diff3 inserts a `base` stage between
        // `ours` and `theirs`; the default 2-way style skips it.
        enum State { case idle, ours, base, theirs }
        var state: State = .idle
        var blockStart = 0          // utf16 offset of the `<` line
        var startLine = 0           // 1-based start line
        var currentLines: [String] = []
        var baseLines: [String] = []
        var incomingLines: [String] = []
        var currentLabel = ""
        var incomingLabel = ""
        var baseLabel: String? = nil

        var lineIndex = 0
        var cursor = 0
        while cursor < totalLength {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            nsString.getLineStart(&lineStart,
                                  end: &lineEnd,
                                  contentsEnd: &contentsEnd,
                                  for: NSRange(location: cursor, length: 0))
            let line = nsString.substring(
                with: NSRange(location: lineStart,
                              length: contentsEnd - lineStart))
            // CRLF tolerance — strip a single trailing `\r` so the
            // marker checks don't have to wrap their own dropLast.
            let body = line.hasSuffix("\r")
                ? String(line.dropLast())
                : line
            lineIndex += 1

            switch markerKind(of: body) {
            case .ours(let label):
                // A second `<<<<<<<` while we're still inside an
                // earlier block means the earlier block was
                // malformed (or an attacker-crafted file). Reset.
                state = .ours
                blockStart = lineStart
                startLine = lineIndex
                currentLines.removeAll(keepingCapacity: true)
                baseLines.removeAll(keepingCapacity: true)
                incomingLines.removeAll(keepingCapacity: true)
                currentLabel = label
                incomingLabel = ""
                baseLabel = nil

            case .base(let label):
                if state == .ours {
                    state = .base
                    baseLabel = label
                } else {
                    state = .idle  // marker out of order
                }

            case .separator:
                if state == .ours || state == .base {
                    state = .theirs
                } else {
                    state = .idle
                }

            case .theirs(let label):
                if state == .theirs {
                    incomingLabel = label
                    let block = MergeConflict(
                        id: UUID(),
                        range: NSRange(location: blockStart,
                                       length: lineEnd - blockStart),
                        startLine: startLine,
                        endLine: lineIndex,
                        currentText: currentLines.joined(separator: "\n"),
                        incomingText: incomingLines.joined(separator: "\n"),
                        baseText: baseLabel == nil
                            ? nil
                            : baseLines.joined(separator: "\n"),
                        currentLabel: currentLabel,
                        incomingLabel: incomingLabel,
                        baseLabel: baseLabel)
                    results.append(block)
                }
                state = .idle

            case .none:
                switch state {
                case .ours:   currentLines.append(body)
                case .base:   baseLines.append(body)
                case .theirs: incomingLines.append(body)
                case .idle:   break
                }
            }

            // Safety: `getLineStart` returns lineEnd == lineStart
            // only at EOF. Without this break we'd loop forever on
            // a zero-length tail line.
            if lineEnd == cursor { break }
            cursor = lineEnd
        }
        return results
    }

    // MARK: - Marker recognition

    private enum MarkerKind {
        case ours(label: String)
        case base(label: String)
        case separator
        case theirs(label: String)
        case none
    }

    /// Conflict markers per `git-merge(1)`:
    ///   `<<<<<<<` (7 chars) optionally followed by ` <label>`
    ///   `|||||||` (7 chars) optionally followed by ` <label>` (diff3 only)
    ///   `=======` (exactly 7 chars, no label)
    ///   `>>>>>>>` (7 chars) optionally followed by ` <label>`
    /// We require column 0 — git never indents the markers.
    private static func markerKind(of line: String) -> MarkerKind {
        if let label = matchedLabel(line: line, prefix: "<<<<<<<") {
            return .ours(label: label)
        }
        if let label = matchedLabel(line: line, prefix: "|||||||") {
            return .base(label: label)
        }
        // Separator must be exactly seven `=` — anything longer
        // (e.g. a commented banner of equal signs) is regular
        // content, not a marker.
        if line == "=======" {
            return .separator
        }
        if let label = matchedLabel(line: line, prefix: ">>>>>>>") {
            return .theirs(label: label)
        }
        return .none
    }

    /// Returns the trimmed label after `prefix` when `line` is
    /// either exactly `prefix` or `prefix + " " + …`. Anything
    /// else (longer prefix run, prefix followed by punctuation)
    /// returns `nil` so the caller falls through to `.none`.
    private static func matchedLabel(line: String, prefix: String) -> String? {
        if line == prefix { return "" }
        guard line.hasPrefix(prefix + " ") else { return nil }
        let rest = line.dropFirst(prefix.count + 1)
        return String(rest).trimmingCharacters(in: .whitespaces)
    }
}
