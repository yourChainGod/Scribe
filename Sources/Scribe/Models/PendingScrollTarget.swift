//
//  PendingScrollTarget.swift
//  Phase 49c — explicit, atomically-written caret destination shared
//  by every "jump-the-editor-here" path: cross-file find, symbol
//  outline, scribe -l ... CLI startup, and Quick Open's `:line:col`
//  route. Pre-49c the editor consumed a bare `Int?` line; lifting it
//  into a struct lets the column ride alongside without risking a
//  half-applied SwiftUI update where the consumer sees the new line
//  but the old (or absent) column.
//

import Foundation

/// Destination handed to `ScintillaCodeEditor.consumePendingScroll`.
/// Both fields are 1-based to match the editor's user-visible numbers
/// — Scintilla's 0-based indices are confined to the consumer.
struct PendingScrollTarget: Equatable, Hashable {
    /// 1-based source-line number. Always required; a `0` or
    /// negative value would mean "no jump", which `nil` already
    /// expresses.
    let line: Int

    /// 1-based visual column. `nil` ⇒ no column was requested; the
    /// consumer falls back to its prior behaviour of selecting the
    /// whole destination line so the user gets a high-visibility
    /// landing cue. A non-nil column suppresses the line-select and
    /// drops the caret precisely on the requested column, with
    /// `SCI_FINDCOLUMN` snapping to line-end if the line is shorter.
    let column: Int?

    init(line: Int, column: Int? = nil) {
        self.line = line
        self.column = column
    }
}
