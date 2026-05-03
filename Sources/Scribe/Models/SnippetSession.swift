//
//  SnippetSession.swift
//  Phase 63 — runtime state for an active snippet expansion. Tracks
//  the live byte ranges of every tab stop after the snippet has been
//  inserted, advances them as the user types inside / around the
//  placeholders, and remembers which stop is currently selected so
//  Tab can cycle to the next one.
//
//  The session is a *value* type on purpose: every coordinator-level
//  mutation goes through `apply(modification:)` / `advance()` and
//  hands the new state back. That keeps "is the session still
//  alive?" decisions at the call site (the Coordinator) — out of
//  this struct's mental model.
//
//  Byte ranges, not UTF-16
//    `SnippetParser` reports stops in UTF-16 code units against the
//    plain text it produces; the editor side translates to UTF-8
//    *byte* offsets before constructing a session. Scintilla
//    operates exclusively on byte offsets, so keeping the session
//    storage in bytes means every `apply` / `advance` is a pure
//    integer operation — no NSString round-trips.
//

import Foundation

/// Live view of an in-flight snippet expansion. One instance per
/// expansion; the Coordinator owns at most one at a time (nested
/// snippets are deferred to a future phase).
struct SnippetSession: Equatable, Sendable {

    /// One stop's *current* byte range in the buffer, plus the
    /// snippet-defined index (`0` for the terminal stop).
    struct Stop: Equatable, Sendable {
        /// Snippet index from the parser (`$N`'s `N`).
        let index: Int
        /// Live byte range in the document. `start == end` for a
        /// zero-width stop — Scintilla treats those as a caret
        /// drop, not a selection.
        var start: Int
        var end: Int

        var length: Int { end - start }
    }

    /// Stops in *visit order* (non-zero ascending by index, then
    /// the `$0` terminal stop). The current stop is `stops[currentIndex]`
    /// while the session is alive.
    var stops: [Stop]

    /// 0-based index into `stops` for the currently-focused stop.
    /// Valid range is `0..<stops.count` — the Coordinator ends the
    /// session before this advances past the last entry.
    var currentIndex: Int

    /// `true` when the cursor is parked on the terminal `$0` stop.
    /// Pressing Tab from here ends the session.
    var isOnTerminalStop: Bool {
        currentIndex >= 0 && currentIndex < stops.count
            && stops[currentIndex].index == 0
    }

    /// The stop the user is currently editing.
    var current: Stop {
        stops[currentIndex]
    }

    // MARK: - Construction

    /// Build a session for `parsed` snippet inserted at `caretByte`
    /// in the buffer, given the snippet's plain text. Translates
    /// the parser's UTF-16 ranges into UTF-8 byte ranges so the
    /// editor side can call `SCI_SETSEL` directly.
    ///
    /// Returns `nil` when the parsed snippet has only the synthetic
    /// trailing `$0`, i.e. there are no user-visible placeholders
    /// to navigate. The caller falls back to the plain `INSERTTEXT`
    /// path so single-token bodies (the Phase 33 status quo) keep
    /// working without an active session.
    static func make(parsed: ParsedSnippet,
                     insertedAt caretByte: Int) -> SnippetSession? {
        // No real placeholders → don't open a session. The synthetic
        // `$0` is at the very tail and contributes no navigation
        // value beyond "leave the caret where you'd type next",
        // which is also Scintilla's default after `INSERTTEXT`.
        if parsed.stops.count == 1 && parsed.stops[0].index == 0 {
            return nil
        }

        // Convert each stop's UTF-16 (location, length) over plainText
        // into a UTF-8 byte range. The two run together because the
        // common ASCII case is a no-op identity.
        let nsPlain = parsed.plainText as NSString
        var byteStops: [Stop] = []
        byteStops.reserveCapacity(parsed.stops.count)
        for stop in parsed.stops {
            // Slice `[0, stop.location)` and `[stop.location, end)`
            // by UTF-16, then count UTF-8 bytes for each. NSString
            // substring is O(n) and parser stops are sorted by visit
            // order (not source order), so the slices may overlap —
            // two short substring calls per stop is the simplest
            // implementation and snippets are short by nature.
            let prefixRange = NSRange(location: 0, length: stop.location)
            let stopRange = NSRange(location: stop.location,
                                    length: stop.length)
            // Bounds check: the parser guarantees the ranges are
            // valid for `parsed.plainText`, so an out-of-range here
            // would be a parser bug we want to surface loudly.
            precondition(prefixRange.upperBound <= nsPlain.length,
                         "stop prefix range exceeds plain text")
            precondition(stopRange.upperBound <= nsPlain.length,
                         "stop range exceeds plain text")
            let prefixBytes = nsPlain.substring(with: prefixRange).utf8.count
            let stopBytes = nsPlain.substring(with: stopRange).utf8.count
            let absStart = caretByte + prefixBytes
            let absEnd = absStart + stopBytes
            byteStops.append(Stop(index: stop.index,
                                  start: absStart,
                                  end: absEnd))
        }

        return SnippetSession(stops: byteStops, currentIndex: 0)
    }

    // MARK: - Modifications

    /// Apply a single buffer modification to every live stop's range.
    /// `pos` is the starting byte offset of the change. `length` is
    /// the number of bytes inserted (positive) or deleted (negative;
    /// `pos + |length|` is the deletion end).
    ///
    /// Boundary semantics
    ///   * Insert at `pos == start` of a stop *expands* the right
    ///     edge — the typed char is treated as part of the stop's
    ///     replacement text. Same for `pos == end`.
    ///   * Insert at `pos < start` shifts the stop right.
    ///   * Insert at `pos > end` is a no-op for the stop.
    ///   * Delete is the dual: positions inside the deletion collapse
    ///     to `pos`; positions strictly past the deletion shift left
    ///     by `|length|`.
    mutating func apply(modificationAt pos: Int, length: Int) {
        if length == 0 { return }
        for i in stops.indices {
            var stop = stops[i]
            if length > 0 {
                stop.start = shiftedForInsert(boundary: stop.start,
                                              insertPos: pos,
                                              length: length,
                                              isStartOfStop: true,
                                              stop: stop)
                stop.end = shiftedForInsert(boundary: stop.end,
                                            insertPos: pos,
                                            length: length,
                                            isStartOfStop: false,
                                            stop: stop)
            } else {
                let delLen = -length
                stop.start = shiftedForDelete(boundary: stop.start,
                                              delStart: pos,
                                              delLen: delLen)
                stop.end = shiftedForDelete(boundary: stop.end,
                                            delStart: pos,
                                            delLen: delLen)
            }
            stops[i] = stop
        }
    }

    /// Insert at `insertPos` shifts a boundary `b` based on whether
    /// the boundary is the START or END of its stop. The asymmetry
    /// matters at the *exact* boundary value: insertion at `b` where
    /// `b == stop.start` keeps the start fixed (so typed text grows
    /// inside the placeholder); insertion at `b == stop.end` extends
    /// the end (so trailing typing extends the placeholder).
    private func shiftedForInsert(boundary b: Int,
                                  insertPos pos: Int,
                                  length: Int,
                                  isStartOfStop: Bool,
                                  stop: Stop) -> Int {
        if pos < b { return b + length }
        if pos > b { return b }
        // pos == b
        if isStartOfStop {
            // Insert exactly at start — text goes *into* the stop.
            // Boundary unchanged; the END boundary will pick up the
            // shift on its own pass.
            return b
        }
        // Insert at end of stop — extend it. The asymmetry only
        // applies when there's a non-empty stop to extend; for
        // zero-width stops both branches collide on `pos == start ==
        // end` and we still want the typed text to grow the stop,
        // so the END branch's `b + length` wins.
        return b + length
    }

    /// Delete shifts a boundary `b` based on the deletion's bounds
    /// `[delStart, delStart + delLen)`. Boundary inside the deletion
    /// collapses to `delStart`; boundary strictly past the deletion
    /// shifts left by `delLen`.
    private func shiftedForDelete(boundary b: Int,
                                  delStart: Int,
                                  delLen: Int) -> Int {
        let delEnd = delStart + delLen
        if b <= delStart { return b }
        if b >= delEnd { return b - delLen }
        // delStart < b < delEnd → collapse to delStart.
        return delStart
    }

    // MARK: - Navigation

    /// Advance to the next stop. Returns `false` when there isn't
    /// one — the caller ends the session.
    mutating func advance() -> Bool {
        guard currentIndex + 1 < stops.count else { return false }
        currentIndex += 1
        return true
    }

    /// Step back to the previous stop, if any. Returns `false` for
    /// the very first stop (Tab + ⇧Tab from the entry stop is a
    /// no-op rather than a session-ender).
    mutating func retreat() -> Bool {
        guard currentIndex > 0 else { return false }
        currentIndex -= 1
        return true
    }
}
