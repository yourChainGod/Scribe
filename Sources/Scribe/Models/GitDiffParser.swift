//
//  GitDiffParser.swift
//  Phase 31 — pure function that turns the output of
//  `git diff --no-color --no-ext-diff -U0 HEAD -- <file>`
//  into a `[Int: GitGutterStatus]` dictionary keyed by 1-based
//  line number in the *working tree* file.
//
//  Why -U0:
//    Without context, every emitted hunk describes only the lines
//    that actually changed. A single `@@ -OLDSTART,OLDLEN
//    +NEWSTART,NEWLEN @@` header tells us:
//
//      OLDLEN  NEWLEN  meaning
//      ------  ------  -----------------------------------------
//      > 0     > 0     `OLDLEN` lines replaced by `NEWLEN` lines
//      0       > 0     `NEWLEN` brand-new lines starting at NEWSTART
//      > 0     0       `OLDLEN` lines deleted just before NEWSTART
//
//    The parser doesn't have to read the body of the hunk; we only
//    need the per-line status, and the header carries it.
//
//  Why pure / nonisolated:
//    Lets a background `Task.detached` call this without dragging
//    main-actor isolation along. The engine that owns the diff
//    string runs on @MainActor; parsing happens off-main and the
//    result is published back via the engine.
//

import Foundation

/// What the gutter should draw on a given working-tree line.
enum GitGutterStatus: Sendable, Equatable {
    /// New line that doesn't exist at HEAD.
    case added
    /// Existing line whose content changed since HEAD.
    case modified
    /// One or more HEAD lines were deleted just *above* this
    /// working-tree line. The gutter draws a small marker at the
    /// top of the row instead of filling the cell.
    case deletedAbove
}

enum GitDiffParser {

    /// Parse the unified-diff text into a per-line status map.
    /// Empty input (`""`) is the common "no changes" case and
    /// returns an empty dictionary.
    nonisolated static func parse(_ unifiedDiff: String) -> [Int: GitGutterStatus] {
        var out: [Int: GitGutterStatus] = [:]
        // Iterate by line; we only care about hunk headers (`@@`).
        // Body lines are skipped entirely — see the file header
        // comment for why the header alone is sufficient.
        for raw in unifiedDiff.split(separator: "\n",
                                     omittingEmptySubsequences: false) {
            let line = String(raw)
            guard line.hasPrefix("@@ ") else { continue }
            guard let header = parseHunkHeader(line) else { continue }
            applyHunk(header, into: &out)
        }
        return out
    }

    // MARK: - Internals

    /// Decoded form of `@@ -OLDSTART[,OLDLEN] +NEWSTART[,NEWLEN] @@`.
    /// The trailing optional "@@ section heading" suffix is ignored.
    fileprivate struct HunkHeader: Equatable {
        var oldStart: Int
        var oldLen: Int
        var newStart: Int
        var newLen: Int
    }

    /// Parse the `@@ … @@` line. Returns nil for any malformed
    /// header (so a corrupt diff doesn't crash the parser, it just
    /// produces an empty gutter for the file).
    fileprivate static func parseHunkHeader(_ line: String) -> HunkHeader? {
        // "@@ -1,2 +3,4 @@ optional heading"
        // 1. Strip the leading "@@ ".
        let body = line.dropFirst(3)
        // 2. Split off the trailing " @@" (and anything after).
        guard let endRange = body.range(of: " @@") else { return nil }
        let coords = body[..<endRange.lowerBound]
        // 3. Tokens: ["-OLD", "+NEW"]. Anything else is malformed.
        let parts = coords.split(separator: " ")
        guard parts.count == 2,
              parts[0].hasPrefix("-"),
              parts[1].hasPrefix("+") else { return nil }
        let old = String(parts[0].dropFirst())   // drop the '-'
        let new = String(parts[1].dropFirst())   // drop the '+'
        guard let oldPair = parseLengthPair(old),
              let newPair = parseLengthPair(new) else { return nil }
        return HunkHeader(oldStart: oldPair.start, oldLen: oldPair.len,
                          newStart: newPair.start, newLen: newPair.len)
    }

    /// `"5"` → (5, 1)   (default length is 1)
    /// `"5,3"` → (5, 3)
    /// `"5,0"` → (5, 0) (deletion)
    /// `"0,0"` → (0, 0) (degenerate; we treat it as no-op)
    fileprivate static func parseLengthPair(_ s: String) -> (start: Int, len: Int)? {
        let parts = s.split(separator: ",")
        guard let start = Int(parts[0]) else { return nil }
        if parts.count == 1 { return (start, 1) }
        guard parts.count == 2, let len = Int(parts[1]) else { return nil }
        return (start, len)
    }

    /// Translate the header into per-line entries on the working
    /// tree side (the "+" coordinates).
    fileprivate static func applyHunk(_ h: HunkHeader,
                                      into out: inout [Int: GitGutterStatus]) {
        // Pure addition: HEAD had no lines here, working tree gained
        // newLen lines at newStart. Mark every one as `.added`.
        if h.oldLen == 0, h.newLen > 0 {
            for offset in 0..<h.newLen {
                out[h.newStart + offset] = .added
            }
            return
        }
        // Pure deletion: working tree dropped oldLen lines just
        // *after* line `newStart`. Mark `newStart + 1` (or `1` if
        // the deletion was at the top) so the user sees a small
        // marker at the boundary line.
        //
        // git's convention with -U0: when newLen=0, newStart is the
        // line in the new file *before* the deletion point. Special
        // case: deleting from the start of the file gives newStart=0.
        if h.oldLen > 0, h.newLen == 0 {
            let target = h.newStart == 0 ? 1 : h.newStart
            // Don't overwrite an `.added` or `.modified` already at
            // this row — those are stronger signals; deletion just
            // augments. (Multiple hunks can land on adjacent rows
            // when both an insert and a delete touch the same area.)
            if out[target] == nil {
                out[target] = .deletedAbove
            }
            return
        }
        // Replacement: every new-side line is `.modified`. We don't
        // emit a separate `.deletedAbove` — the caller can tell from
        // a different oldLen vs newLen ratio in v2 if needed; for
        // v1 a uniform stripe matches what GitHub / VSCode show.
        if h.oldLen > 0, h.newLen > 0 {
            for offset in 0..<h.newLen {
                out[h.newStart + offset] = .modified
            }
            return
        }
        // 0,0 — no-op. Shouldn't appear in real git output but we
        // tolerate it.
    }
}
