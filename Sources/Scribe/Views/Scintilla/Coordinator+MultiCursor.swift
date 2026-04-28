//
//  Coordinator+MultiCursor.swift
//  Phase 28d — every multi-cursor / column-selection / multi-caret
//  command, lifted out of ScintillaCodeEditor.swift.
//
//  Why this slice: Phases 20–24 piled multi-cursor support on top of
//  Scintilla's `SCI_ADDSELECTION` / `SCI_GETSELECTIONS` API, with
//  ~16 helpers and ~440 lines of edge-case handling around each
//  ⌘D / ⌘⇧L / ⌥⌘↑↓ chord. That made the main editor file 1080+
//  lines and forced every reader to wade through caret arithmetic
//  to reach the doc-sync code at the bottom.
//
//  Lifting the cluster doesn't share state with the rest of the
//  Coordinator beyond `view`, `findState`, and `doc` — all three
//  module-internal already — so the move is safe and invisible to
//  callers.
//
//  Visibility contract:
//    - public `func selectNextOccurrence` / `skipAnd...` /
//      `selectAllOccurrences` / `addCaret{Above,Below}` /
//      `toggleColumnSelectionMode` / `insertAtCarets` /
//      `collapseToSingleCursor` / `adoptSelectionAsQuery`: command
//      sinks pumped by FindState's Combine pipe + the test hooks;
//    - `testRectSelectExtend(linesDown:charsRight:in:)`: SCRIBE_TEST_*
//      hook only;
//    - everything else `fileprivate`.
//

import Foundation
import Scintilla

extension ScintillaCodeEditor.Coordinator {

    // MARK: - ⌘D / Select Next Occurrence

    /// ⌘D / "Select Next Occurrence". First press: if the caret
    /// has no selection, pick the word under it; if it does,
    /// keep that selection and use it as the search needle.
    /// Subsequent presses: find the next occurrence of the
    /// needle (case-sensitive, whole-word when the seed was a
    /// bare word) and add it as an additional selection,
    /// scrolling the new caret into view. Wraps around the
    /// document end to start.
    func selectNextOccurrence() {
        guard let view else { return }
        let needle = ensureSelectionForMultiCursor(in: view)
        guard !needle.isEmpty else { return }

        // Search starts after the LAST (rightmost) caret so a
        // user pressing ⌘D repeatedly walks forward through the
        // document. Without this, every press would re-find the
        // first match below the original caret.
        let n = view.message(SCI.GETSELECTIONS)
        var maxEnd = 0
        for i in 0..<Int(n) {
            let caret = Int(view.message(SCI.GETSELECTIONNCARET, wParam: UInt(i)))
            let anchor = Int(view.message(SCI.GETSELECTIONNANCHOR, wParam: UInt(i)))
            maxEnd = max(maxEnd, max(caret, anchor))
        }
        let docLen = Int(view.message(SCI.GETLENGTH))
        // Two-pass scan: first from maxEnd to EOF, then 0 to
        // maxEnd, to wrap around. Existing selection ranges are
        // skipped so we never "find" ourselves.
        let existing = currentSelectionRanges(in: view)
        if let range = mcFindNext(needle: needle,
                                  in: view,
                                  from: maxEnd,
                                  to: docLen,
                                  skip: existing)
            ?? mcFindNext(needle: needle,
                          in: view,
                          from: 0,
                          to: maxEnd,
                          skip: existing)
        {
            view.message(SCI.ADDSELECTION,
                         wParam: UInt(bitPattern: range.upperBound),
                         lParam: range.lowerBound)
            view.message(SCI.SCROLLCARET)
        }
    }

    /// ⌘K ⌘D / "Skip Next Occurrence". The user has selected a
    /// run of matches via ⌘D and wants to *un*-select the
    /// current main selection because it's an odd one out, then
    /// jump to the next match instead. VSCode + Sublime spell
    /// it the same way.
    ///
    /// Implementation: drop the main selection from the multi-
    /// set via SCI_DROPSELECTIONN, then run a normal "select
    /// next" pass anchored at the rightmost remaining caret —
    /// that's exactly the same body as `selectNextOccurrence`.
    /// If only one selection exists going in, dropping it would
    /// leave the document in a weird empty-selection state, so
    /// we fall back to plain selectNextOccurrence in that case
    /// (the user gets the next occurrence; the original is
    /// kept because there's nothing to skip into).
    func skipAndSelectNextOccurrence() {
        guard let view else { return }
        let n = Int(view.message(SCI.GETSELECTIONS))
        // Single selection: nothing to "skip", behave like ⌘D.
        // Otherwise dropping the only selection would leave 0,
        // which Scintilla treats as undefined.
        guard n > 1 else {
            selectNextOccurrence()
            return
        }
        // 1. Capture the needle + the rightmost edge of the
        //    main selection BEFORE we drop it. The next-match
        //    search needs to start past that edge so we don't
        //    just refind the slot we're supposedly skipping.
        let mainIdx = Int(view.message(SCI.GETMAINSELECTION))
        let mainAnchor = Int(view.message(SCI.GETSELECTIONNANCHOR,
                                          wParam: UInt(bitPattern: mainIdx)))
        let mainCaret = Int(view.message(SCI.GETSELECTIONNCARET,
                                         wParam: UInt(bitPattern: mainIdx)))
        let mainStart = min(mainAnchor, mainCaret)
        let mainEnd = max(mainAnchor, mainCaret)
        guard mainEnd > mainStart else { return }
        let needle = textInRange(in: view, range: mainStart..<mainEnd)
        guard !needle.isEmpty else { return }

        // 2. Drop the main selection. Scintilla auto-promotes
        //    one of the remaining ones to be the new main.
        view.message(SCI.DROPSELECTIONN, wParam: UInt(bitPattern: mainIdx))

        // 3. Search forward starting *past* the dropped range,
        //    skipping any selection that's still active so we
        //    can't pick another existing match by accident.
        //    Wraps around the doc end like selectNextOccurrence.
        let docLen = Int(view.message(SCI.GETLENGTH))
        let existing = currentSelectionRanges(in: view)
        let range = mcFindNext(needle: needle,
                               in: view,
                               from: mainEnd,
                               to: docLen,
                               skip: existing)
            ?? mcFindNext(needle: needle,
                          in: view,
                          from: 0,
                          to: mainEnd,
                          skip: existing)
        guard let r = range else { return }
        view.message(SCI.ADDSELECTION,
                     wParam: UInt(bitPattern: r.upperBound),
                     lParam: r.lowerBound)
        view.message(SCI.SCROLLCARET)
    }

    /// ⌘⇧L / "Select All Occurrences". Picks the same needle as
    /// `selectNextOccurrence` and adds every other occurrence in
    /// the document as an additional selection in one shot. No-op
    /// if the needle's empty.
    func selectAllOccurrences() {
        guard let view else { return }
        let needle = ensureSelectionForMultiCursor(in: view)
        guard !needle.isEmpty else { return }
        let docLen = Int(view.message(SCI.GETLENGTH))
        let existing = currentSelectionRanges(in: view)
        var cursor = 0
        // Bounded loop so a degenerate regex (shouldn't happen —
        // we always pass a literal) can't pin the editor.
        var iterations = 0
        while cursor < docLen, iterations < 10_000 {
            iterations += 1
            guard let r = mcFindNext(needle: needle,
                                     in: view,
                                     from: cursor,
                                     to: docLen,
                                     skip: existing) else { break }
            view.message(SCI.ADDSELECTION,
                         wParam: UInt(bitPattern: r.upperBound),
                         lParam: r.lowerBound)
            cursor = r.upperBound
        }
        view.message(SCI.SCROLLCARET)
    }

    // MARK: - ⌥⌘↑↓ / Add Cursor Above & Below

    /// ⌥⌘↑ / "Add Cursor Above". Projects every existing caret
    /// onto the line above (preserving column) and adds those
    /// projections as additional selections. Carets that are
    /// already on line 0 are skipped — there's nothing above.
    ///
    /// Same column-snapping semantics as VSCode: if the upper
    /// line is shorter than the source caret column, the new
    /// caret pins at the line end. Implemented via SCI_FINDCOLUMN
    /// which already does that snap natively.
    func addCaretAbove() {
        extendCaretsByLine(delta: -1)
    }

    /// ⌥⌘↓ / "Add Cursor Below". Mirror of `addCaretAbove`.
    /// Carets on the last line are skipped.
    func addCaretBelow() {
        extendCaretsByLine(delta: +1)
    }

    /// Shared body for the two `addCaret{Above,Below}` commands.
    /// `delta` must be ±1; anything else is meaningless.
    ///
    /// Walks every existing selection's caret, projects it onto
    /// the target line via SCI_FINDCOLUMN, deduplicates against
    /// the current set so a no-op press doesn't grow the
    /// selection, and ADDSELECTION's the survivors. Main
    /// selection is updated to the FIRST new caret so vertical
    /// repeats keep walking outward — matches VSCode's "the
    /// last caret added is the one driving the next add"
    /// intuition.
    fileprivate func extendCaretsByLine(delta: Int) {
        guard let view, abs(delta) == 1 else { return }
        let n = Int(view.message(SCI.GETSELECTIONS))
        guard n > 0 else { return }
        let lineCount = Int(view.message(SCI.GETLINECOUNT))
        // Snapshot existing carets first so the in-loop ADDSELECTION
        // calls don't widen the count we iterate over.
        var pending: [Int] = []
        var existing: Set<Int> = []
        for i in 0..<n {
            let caret = Int(view.message(SCI.GETSELECTIONNCARET, wParam: UInt(i)))
            existing.insert(caret)
        }
        for i in 0..<n {
            let caret = Int(view.message(SCI.GETSELECTIONNCARET, wParam: UInt(i)))
            let line = Int(view.message(SCI.LINEFROMPOSITION, wParam: UInt(caret)))
            let col = Int(view.message(SCI.GETCOLUMN, wParam: UInt(caret)))
            let target = line + delta
            guard target >= 0, target < lineCount else { continue }
            let pos = Int(view.message(SCI.FINDCOLUMN,
                                       wParam: UInt(bitPattern: target),
                                       lParam: col))
            // Skip projections that land on top of an already-
            // selected caret — keeps repeated presses idempotent
            // when a column-block of carets is already filled in.
            if existing.contains(pos) { continue }
            pending.append(pos)
            existing.insert(pos)
        }
        // ADDSELECTION on macOS Scintilla 5.x leaves the new
        // caret/anchor at 0 even when wParam/lParam are non-zero
        // (likely a uptr_t / Sci_Position size mismatch through
        // the ObjC bridge). Setting them explicitly via
        // SETSELECTIONNCARET / SETSELECTIONNANCHOR right after
        // gives us the position we wanted.
        for pos in pending {
            view.message(SCI.ADDSELECTION,
                         wParam: UInt(bitPattern: pos),
                         lParam: pos)
            let idx = Int(view.message(SCI.GETSELECTIONS)) - 1
            view.message(SCI.SETSELECTIONNCARET,
                         wParam: UInt(bitPattern: idx),
                         lParam: pos)
            view.message(SCI.SETSELECTIONNANCHOR,
                         wParam: UInt(bitPattern: idx),
                         lParam: pos)
        }
        if !pending.isEmpty {
            view.message(SCI.SCROLLCARET)
        }
    }

    // MARK: - ⌘⇧8 / Column (Rectangular) Selection

    /// ⌘⇧8 / "Toggle Column Selection Mode". Flips the
    /// document between SC_SEL_STREAM (default — arrows move
    /// the caret as a single point) and SC_SEL_RECTANGLE
    /// (arrows extend a rectangular selection block). VSCode
    /// uses ⌘⇧8 / Cmd+Shift+8 for the same toggle.
    ///
    /// Independent of the ⇧⌥+arrow chord that Scintilla cocoa
    /// maps to Char/LineRectExtend by default — those make a
    /// rect selection without leaving the toggle on. The
    /// toggle lets users do a long rectangle edit without
    /// holding ⇧⌥ for every key.
    ///
    /// Returns the new mode (so the menu can update the
    /// checkmark) or nil if the view is gone.
    @discardableResult
    func toggleColumnSelectionMode() -> Int? {
        guard let view else { return nil }
        let cur = Int(view.message(SCI.GETSELECTIONMODE))
        let next = (cur == SC.SEL_STREAM) ? SC.SEL_RECTANGLE : SC.SEL_STREAM
        // CHANGESELECTIONMODE (vs SETSELECTIONMODE) doesn't
        // also flip MoveExtendsSelection — we want the
        // current move-extends preference preserved across
        // the toggle.
        view.message(SCI.CHANGESELECTIONMODE, wParam: UInt(next))
        return next
    }

    /// Test-only: drive `SCI_LINEDOWNRECTEXTEND` /
    /// `SCI_CHARRIGHTRECTEXTEND` `linesDown` / `charsRight`
    /// times so the Phase 23 verification hook can produce a
    /// visible rectangle without going through System Events.
    /// In normal use these verbs reach Scintilla via the
    /// default cocoa key map (⇧⌥+arrow) — the user shouldn't
    /// need this method.
    func testRectSelectExtend(linesDown: Int, charsRight: Int, in view: ScintillaView) {
        // Force caret to absolute doc start before extending so
        // the resulting rectangle has a known origin. Without
        // this the screenshot is non-deterministic — the caret
        // can land anywhere depending on previous state.
        view.message(SCI.SETSEL, wParam: 0, lParam: 0)
        for _ in 0..<max(0, linesDown) {
            view.message(SCI.LINEDOWNRECTEXTEND)
        }
        for _ in 0..<max(0, charsRight) {
            view.message(SCI.CHARRIGHTRECTEXTEND)
        }
    }

    // MARK: - Multi-caret insert + collapse

    /// Test-only: insert `text` at every active caret. Bypasses
    /// the responder chain so the Phase 21 verification hook
    /// can prove all carets received the same input —
    /// `NSApp.sendAction(insertText:)` doesn't reach
    /// ScintillaView's text input path.
    ///
    /// Implementation: SCI_REPLACESEL only mutates the *main*
    /// selection in multi-selection mode (despite what the
    /// 5.x docs imply), and SCI_SETSEL collapses the
    /// multi-selection back to a single range. So we use
    /// SCI_INSERTTEXT — which inserts at an absolute
    /// position without touching the selection state — and
    /// walk caret positions from highest to lowest so each
    /// insert doesn't shift a position we still need to use.
    func insertAtCarets(_ text: String, in view: ScintillaView) {
        let n = Int(view.message(SCI.GETSELECTIONS))
        guard n > 0 else { return }
        // Snapshot caret positions before the loop — INSERTTEXT
        // shifts everything past it, but our snapshot stays
        // valid because we apply highest-first.
        var positions: [Int] = []
        for i in 0..<n {
            let caret = Int(view.message(SCI.GETSELECTIONNCARET, wParam: UInt(i)))
            positions.append(caret)
        }
        positions.sort(by: >)            // descending
        let bytes = Array(text.utf8) + [0]   // C string for INSERTTEXT
        for pos in positions {
            bytes.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                view.message(SCI.INSERTTEXT,
                             wParam: UInt(bitPattern: pos),
                             lParam: Int(bitPattern: base))
            }
        }
    }

    /// Esc / "Single Cursor". Drops every additional selection
    /// and leaves the main one intact at its current caret.
    /// Re-uses Scintilla's `SCI_CLEARSELECTIONS` semantics: it
    /// clears the multi-selection set but keeps the caret where
    /// the main selection's caret was sitting.
    func collapseToSingleCursor() {
        guard let view else { return }
        let n = view.message(SCI.GETSELECTIONS)
        guard n > 1 else { return }
        let mainIdx = view.message(SCI.GETMAINSELECTION)
        let caret = Int(view.message(SCI.GETSELECTIONNCARET, wParam: UInt(mainIdx)))
        // SCI_CLEARSELECTIONS leaves a single empty selection
        // at position 0 — set it explicitly so the user keeps
        // their place.
        view.message(SCI.SETSEL,
                     wParam: UInt(bitPattern: caret),
                     lParam: caret)
    }

    // MARK: - Helpers (selection / text / find)

    /// If there's already a selection, returns its text. If the
    /// caret is at a word, expands to that word and returns it.
    /// Otherwise returns "".
    fileprivate func ensureSelectionForMultiCursor(in view: ScintillaView) -> String {
        let s = Int(view.message(SCI.GETSELECTIONSTART))
        let e = Int(view.message(SCI.GETSELECTIONEND))
        if e > s {
            return textInRange(in: view, range: s..<e)
        }
        // Empty selection → expand to the surrounding word.
        let pos = Int(view.message(SCI.GETCURRENTPOS))
        let wordStart = Int(view.message(SCI.WORDSTARTPOSITION,
                                         wParam: UInt(bitPattern: pos),
                                         lParam: 1))
        let wordEnd = Int(view.message(SCI.WORDENDPOSITION,
                                       wParam: UInt(bitPattern: pos),
                                       lParam: 1))
        guard wordEnd > wordStart else { return "" }
        view.message(SCI.SETSEL,
                     wParam: UInt(bitPattern: wordStart),
                     lParam: wordEnd)
        return textInRange(in: view, range: wordStart..<wordEnd)
    }

    /// Snapshot of every (anchor, caret) pair as a normalised
    /// half-open range. Used to skip "finding ourselves" when
    /// adding the next match.
    fileprivate func currentSelectionRanges(in view: ScintillaView) -> [Range<Int>] {
        let n = Int(view.message(SCI.GETSELECTIONS))
        var out: [Range<Int>] = []
        for i in 0..<n {
            let caret = Int(view.message(SCI.GETSELECTIONNCARET, wParam: UInt(i)))
            let anchor = Int(view.message(SCI.GETSELECTIONNANCHOR, wParam: UInt(i)))
            let lo = min(caret, anchor)
            let hi = max(caret, anchor)
            if hi > lo { out.append(lo..<hi) }
        }
        return out
    }

    /// Linear UTF-8-byte scan for `needle` in [from, to). Skips
    /// any match that overlaps `skip`. Returns the half-open
    /// match range or nil.
    /// Renamed from `findNext` to `mcFindNext` to avoid colliding
    /// with the find-cluster's `findNext(in:)` after the cross-
    /// file extension split.
    fileprivate func mcFindNext(needle: String,
                                in view: ScintillaView,
                                from: Int,
                                to: Int,
                                skip: [Range<Int>]) -> Range<Int>? {
        view.message(SCI.SETTARGETSTART, wParam: UInt(bitPattern: from))
        view.message(SCI.SETTARGETEND, wParam: UInt(bitPattern: to))
        view.message(SCI.SETSEARCHFLAGS, wParam: SCFIND.MATCHCASE)
        // SCI_SEARCHINTARGET wants a UTF-8 byte buffer.
        let bytes = Array(needle.utf8)
        let result: Int = bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return -1 }
            return Int(view.message(SCI.SEARCHINTARGET,
                                    wParam: UInt(buf.count),
                                    lParam: Int(bitPattern: base)))
        }
        guard result >= 0 else { return nil }
        let s = Int(view.message(SCI.GETTARGETSTART))
        let e = Int(view.message(SCI.GETTARGETEND))
        let r = s..<e
        if skip.contains(where: { $0.overlaps(r) }) {
            // Skip past this match and keep going.
            return mcFindNext(needle: needle,
                              in: view,
                              from: e,
                              to: to,
                              skip: skip)
        }
        return r
    }

    fileprivate func textInRange(in view: ScintillaView, range: Range<Int>) -> String {
        guard let raw = view.string() else { return "" }
        let bytes = Array(raw.utf8)
        guard range.upperBound <= bytes.count else { return "" }
        let slice = Array(bytes[range])
        return String(data: Data(slice), encoding: .utf8) ?? ""
    }

    // MARK: - Find prefill from selection (Phase 18)

    /// Phase 18 — read the current selection as a UTF-8 String,
    /// suitable for prefilling a Find query. Returns "" when the
    /// caret has no actual range or the bytes don't decode.
    /// Multi-line selections are truncated at the first newline
    /// because Find in Files is a single-line query field.
    func currentSelectionText(in view: ScintillaView) -> String {
        let s = Int(view.message(SCI.GETSELECTIONSTART))
        let e = Int(view.message(SCI.GETSELECTIONEND))
        guard e > s, let raw = view.string() else { return "" }
        let bytes = Array(raw.utf8)
        guard e <= bytes.count else { return "" }
        let slice = Array(bytes[s..<e])
        guard let str = String(data: Data(slice), encoding: .utf8) else { return "" }
        // Stop at first newline — the Find bar is single-line.
        if let nl = str.firstIndex(where: { $0.isNewline }) {
            return String(str[..<nl])
        }
        return str
    }

    func adoptSelectionAsQuery(from view: ScintillaView) {
        let s = Int(view.message(SCI.GETSELECTIONSTART))
        let e = Int(view.message(SCI.GETSELECTIONEND))
        guard e > s, let raw = view.string() else { return }
        let bytes = Array(raw.utf8)
        guard e <= bytes.count else { return }
        let slice = Array(bytes[s..<e])
        if let str = String(data: Data(slice), encoding: .utf8) {
            findState.query = str
            findState.show(replaceMode: findState.isReplaceMode)
        }
    }
}
