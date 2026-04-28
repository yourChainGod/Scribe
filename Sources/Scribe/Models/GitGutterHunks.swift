//
//  GitGutterHunks.swift
//  Phase 31b — turn the per-line `[Int: GitGutterStatus]` map into
//  contiguous "hunks" (line ranges) so the editor's ⌥⇧↑ / ⌥⇧↓
//  commands can jump to the previous / next change in one keystroke.
//
//  A hunk is just a maximal run of changed lines with no gap between
//  them. Status type doesn't matter for grouping — VSCode / GitHub
//  also collapse adjacent add/modify/delete into one navigable
//  block, which matches how a human reads "the diff at line 12".
//
//  Why pure / nonisolated:
//    Same reason as `GitDiffParser` — the engine that owns the map
//    runs main-actor, but anyone (tests, future preview UI) can
//    call this directly. No shared state, no I/O.
//

import Foundation

enum GitGutterHunks {

    /// Group the keys of `map` into contiguous closed ranges.
    /// `[2, 3, 4, 7, 9, 10]` → `[2...4, 7...7, 9...10]`.
    /// Returned ranges are sorted ascending by `lowerBound`.
    nonisolated static func groups(in map: [Int: GitGutterStatus])
        -> [ClosedRange<Int>] {
        let lines = map.keys.sorted()
        guard !lines.isEmpty else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var start = lines[0]
        var prev = lines[0]
        for line in lines.dropFirst() {
            if line == prev + 1 {
                prev = line
            } else {
                ranges.append(start...prev)
                start = line
                prev = line
            }
        }
        ranges.append(start...prev)
        return ranges
    }

    /// Start line of the next hunk after `currentLine`. If the cursor
    /// is *inside* a hunk we skip past it to the next one — staying
    /// inside the same hunk would be a no-op for the user.
    /// Wraps to the first hunk when past the last one. Returns `nil`
    /// only when the map has no hunks at all.
    nonisolated static func next(after currentLine: Int,
                                 in map: [Int: GitGutterStatus]) -> Int? {
        let g = groups(in: map)
        guard !g.isEmpty else { return nil }
        // Inside a hunk → jump past it.
        if let idx = g.firstIndex(where: { $0.contains(currentLine) }) {
            let nextIdx = idx + 1
            if nextIdx < g.count { return g[nextIdx].lowerBound }
            return g.first?.lowerBound          // wrap to top
        }
        // Not in any hunk → first hunk strictly after currentLine.
        if let hit = g.first(where: { $0.lowerBound > currentLine }) {
            return hit.lowerBound
        }
        return g.first?.lowerBound              // wrap to top
    }

    /// Start line of the hunk before `currentLine`. Symmetric with
    /// `next`: if the cursor is inside a hunk we skip back past it
    /// to the previous one. Wraps to the last hunk when before the
    /// first one. Returns `nil` only when the map has no hunks.
    nonisolated static func previous(before currentLine: Int,
                                     in map: [Int: GitGutterStatus]) -> Int? {
        let g = groups(in: map)
        guard !g.isEmpty else { return nil }
        // Inside a hunk → jump to the one before it.
        if let idx = g.firstIndex(where: { $0.contains(currentLine) }) {
            if idx > 0 { return g[idx - 1].lowerBound }
            return g.last?.lowerBound           // wrap to bottom
        }
        // Not in any hunk → last hunk strictly before currentLine.
        if let hit = g.reversed().first(where: { $0.lowerBound < currentLine }) {
            return hit.lowerBound
        }
        return g.last?.lowerBound               // wrap to bottom
    }
}
