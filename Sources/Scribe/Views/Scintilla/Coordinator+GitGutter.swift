//
//  Coordinator+GitGutter.swift
//  Phase 31 — paints the git-gutter strip in margin 1 of the editor.
//  Reads `doc.gitGutter` (filled by `GitGutterEngine`) and translates
//  each entry into a Scintilla marker on the corresponding line.
//
//  Margin layout
//      0  line numbers           (44 px)  — applyLineNumberMargin
//      1  git gutter             ( 6 px)  — this file
//      …  reserved for future Document Map / fold strip
//
//  Why margin 1 and not an indicator
//    Indicators paint over the *text*; gutters paint in the *margin*.
//    Markers are the right primitive — they live in their own column,
//    don't fight the lexer's syntax colours, and Scintilla already
//    handles their scrolling + clipping.
//
//  Repaint strategy
//    1. `lastAppliedGitGutter` cache — SwiftUI calls `updateNSView`
//       on every prefs / cursor tick. If `doc.gitGutter` is byte-
//       identical to the last apply we skip the entire path.
//    2. Wipe-and-add — when the dictionary did change we delete our
//       three marker numbers from every line, then add the new set.
//       Per-marker counts are tens-to-hundreds in normal use, so
//       full-buffer wipe is cheaper than tracking incremental deltas.
//
//  Marker number choice
//    21 / 22 / 23 sits in the user-available range (0–24; 25–31 are
//    reserved for Scintilla's folding system). The mask on margin 1
//    pins exactly these three so other markers (bookmarks, breakpoints
//    if we ever add them) won't bleed into the gutter strip.
//

import AppKit
import Scintilla

extension ScintillaCodeEditor.Coordinator {

    /// Stable marker numbers used for the git-gutter strip in margin 1.
    fileprivate enum GitGutterMarker {
        static let added: Int        = 21
        static let modified: Int     = 22
        static let deletedAbove: Int = 23
        /// Bitmask with the three marker bits set, applied to margin 1
        /// via `SCI_SETMARGINMASKN` so unrelated markers are filtered.
        static let mask: Int = (1 << added) | (1 << modified) | (1 << deletedAbove)
    }

    /// Margin width in pixels. Wide enough that FULLRECT colour bars
    /// read at typical zoom levels but narrow enough to feel like an
    /// indicator strip rather than a second sidebar.
    fileprivate static let gitGutterMarginWidth = 6

    /// One-time setup of margin 1: type + width + marker mask, then
    /// the three marker glyph definitions and their colours. Called
    /// from `makeNSView` immediately after `applyLineNumberMargin`.
    func configureGitGutterMargin(in view: ScintillaView) {
        view.message(SCI.SETMARGINTYPEN,
                     wParam: 1,
                     lParam: SC.MARGIN_SYMBOL)
        view.message(SCI.SETMARGINWIDTHN,
                     wParam: 1,
                     lParam: ScintillaCodeEditor.Coordinator.gitGutterMarginWidth)
        view.message(SCI.SETMARGINMASKN,
                     wParam: 1,
                     lParam: GitGutterMarker.mask)

        // Added — solid green stripe filling the cell.
        defineGitGutterMarker(view,
                              num: GitGutterMarker.added,
                              type: SC.MARK_FULLRECT,
                              rgb: 0x4CAF50)
        // Modified — solid yellow stripe filling the cell.
        defineGitGutterMarker(view,
                              num: GitGutterMarker.modified,
                              type: SC.MARK_FULLRECT,
                              rgb: 0xF1C40F)
        // DeletedAbove — narrow red sliver on the left edge of the
        // cell. Subtler than FULLRECT so a deletion-only hunk doesn't
        // look like a brand-new line, but distinct enough that the
        // user can spot it.
        defineGitGutterMarker(view,
                              num: GitGutterMarker.deletedAbove,
                              type: SC.MARK_LEFTRECT,
                              rgb: 0xE74C3C)
    }

    /// Apply the latest `[Int: GitGutterStatus]` from `doc.gitGutter`
    /// to the margin. Called from `updateNSView` on every SwiftUI tick;
    /// no-ops cheaply when the dictionary hasn't changed.
    func applyGitGutter(in view: ScintillaView) {
        let map = doc.gitGutter
        if map == lastAppliedGitGutter { return }
        lastAppliedGitGutter = map

        // Wipe our three marker numbers from every line. We use
        // `MARKERDELETE(line, marker)` per-line because the bulk
        // `SCI_MARKERDELETEALL(marker)` would also drop markers we
        // didn't set (in case the lexer ever wires its own glyph
        // into the same number — unlikely but defensive).
        let lineCount = Int(view.message(SCI.GETLINECOUNT))
        if lineCount > 0 {
            for line in 0..<lineCount {
                let lineParam = UInt(line)
                view.message(SCI.MARKERDELETE,
                             wParam: lineParam,
                             lParam: GitGutterMarker.added)
                view.message(SCI.MARKERDELETE,
                             wParam: lineParam,
                             lParam: GitGutterMarker.modified)
                view.message(SCI.MARKERDELETE,
                             wParam: lineParam,
                             lParam: GitGutterMarker.deletedAbove)
            }
        }

        // Paint the new state. `line0 = line1 - 1` because Scintilla
        // is 0-based but `GitDiffParser` emits 1-based working-tree
        // line numbers (matches what every other tool reports).
        for (line1, status) in map {
            let line0 = line1 - 1
            guard line0 >= 0, line0 < lineCount else { continue }
            let marker: Int
            switch status {
            case .added:        marker = GitGutterMarker.added
            case .modified:     marker = GitGutterMarker.modified
            case .deletedAbove: marker = GitGutterMarker.deletedAbove
            }
            view.message(SCI.MARKERADD,
                         wParam: UInt(line0),
                         lParam: marker)
        }
    }

    // MARK: - Hunk navigation (Phase 31b)

    /// Jump the caret to the start of the next hunk after the current
    /// line. Wraps to the top of the file when past the last hunk.
    /// No-op (with a soft beep) when the file has no changes vs HEAD —
    /// the user pressing ⌥⇧↓ on a clean file shouldn't get a silent
    /// dead key.
    func gotoNextHunk(in view: ScintillaView) {
        guard let target = GitGutterHunks.next(after: currentLine1Based(in: view),
                                               in: doc.gitGutter) else {
            NSSound.beep()
            return
        }
        moveCaret(to: target, in: view)
    }

    /// Symmetric with `gotoNextHunk` — jumps to the previous hunk.
    func gotoPrevHunk(in view: ScintillaView) {
        guard let target = GitGutterHunks.previous(before: currentLine1Based(in: view),
                                                   in: doc.gitGutter) else {
            NSSound.beep()
            return
        }
        moveCaret(to: target, in: view)
    }

    /// Caret line in 1-based coordinates so it speaks the same dialect
    /// as `GitDiffParser`. Scintilla uses 0-based internally; we add 1
    /// at the boundary instead of sprinkling +1 across the call sites.
    fileprivate func currentLine1Based(in view: ScintillaView) -> Int {
        let pos = view.message(SCI.GETCURRENTPOS)
        let line0 = view.message(SCI.LINEFROMPOSITION, wParam: UInt(pos), lParam: 0)
        return Int(line0) + 1
    }

    /// Move the caret to the start of `line1` (1-based) and scroll it
    /// into view. `SCI_GOTOLINE` already resets selection + collapses
    /// any multi-cursor state, so we don't need to do that ourselves.
    fileprivate func moveCaret(to line1: Int, in view: ScintillaView) {
        let line0 = max(0, line1 - 1)
        view.message(SCI.GOTOLINE, wParam: UInt(line0))
        view.message(SCI.SCROLLCARET)
    }

    /// Glyph + colour pair for one marker number. Uses `sciColor` from
    /// `Coordinator+Theme.swift` to get Scintilla's BGR-swizzled int
    /// representation of the RGB literal — consistent with every
    /// other colour push in the editor.
    fileprivate func defineGitGutterMarker(_ view: ScintillaView,
                                           num: Int,
                                           type: Int,
                                           rgb: Int) {
        view.message(SCI.MARKERDEFINE,
                     wParam: UInt(num),
                     lParam: type)
        let bgr = sciColor(rgb)
        view.message(SCI.MARKERSETBACK,
                     wParam: UInt(num),
                     lParam: bgr)
        view.message(SCI.MARKERSETFORE,
                     wParam: UInt(num),
                     lParam: bgr)
    }
}
