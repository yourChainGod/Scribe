//
//  Coordinator+Find.swift
//  Phase 28d — Find / Replace / All-matches indicator cluster.
//
//  Why this slice: Find, Replace, and the indicator-overlay
//  highlights are conceptually one feature. They share `findState`,
//  the search-target bookkeeping (`SCI_SEARCHINTARGET` +
//  `SCI_SETSEARCHFLAGS`), and the SCI_INDIC_* indicator number for
//  match overlays. Lifting them out of `ScintillaCodeEditor.swift`
//  into a dedicated extension keeps the main file focused on
//  doc/view sync + lifecycle, and lets future hash/regex tweaks
//  land here without touching everything else.
//
//  Visibility contract:
//    - public `func find* / replace*` are the entry points the
//      `findCommandSink` Combine pipe pumps;
//    - `refreshHighlightsIfNeeded` is called by `updateNSView`;
//    - `clearHighlights(in:)` is called from outside the find
//      cluster (e.g. when the find bar closes);
//    - everything else is `fileprivate`.
//

import Foundation
import Scintilla

extension ScintillaCodeEditor.Coordinator {

    // MARK: - Search flags

    /// Pack the live find toggles into Scintilla's flag bitmask.
    fileprivate func currentSearchFlags() -> UInt {
        var flags: UInt = 0
        if findState.matchCase { flags |= SCFIND.MATCHCASE }
        if findState.wholeWord { flags |= SCFIND.WHOLEWORD }
        if findState.regex     { flags |= SCFIND.REGEXP | SCFIND.CXX11REGEX }
        return flags
    }

    /// Run a single SCI_SEARCHINTARGET pass with the target window
    /// already configured by the caller. Returns the matched range
    /// (in document bytes) or `nil` if the lookup misses.
    fileprivate func searchInTarget(_ view: ScintillaView,
                                    pattern: String,
                                    flags: UInt) -> Range<Int>? {
        let bytes = Array(pattern.utf8)
        guard !bytes.isEmpty else { return nil }
        view.message(SCI.SETSEARCHFLAGS, wParam: flags)
        // SCI_SEARCHINTARGET takes (length, const char *) and
        // *returns* the match position (or -1). We need that return
        // value, so call `message:wParam:lParam:` directly with the
        // pointer reinterpreted as Int — `setReferenceProperty`
        // discards the return.
        return bytes.withUnsafeBufferPointer { buf -> Range<Int>? in
            guard let base = buf.baseAddress else { return nil }
            let result = view.message(SCI.SEARCHINTARGET,
                                      wParam: UInt(bytes.count),
                                      lParam: Int(bitPattern: base))
            if result < 0 { return nil }
            let start = Int(view.message(SCI.GETTARGETSTART))
            let end   = Int(view.message(SCI.GETTARGETEND))
            return start..<end
        }
    }

    /// SCI_SEARCHINTARGET, but loops back to the start once if the
    /// initial scan misses. Sets `matchedWrapped` so the bar can show
    /// a hint.
    fileprivate func searchWithWrap(_ view: ScintillaView,
                                    from: Int,
                                    pattern: String,
                                    flags: UInt,
                                    forward: Bool) -> (range: Range<Int>, wrapped: Bool)? {
        let length = Int(view.message(SCI.GETLENGTH))
        // First leg: from → (forward ? end : 0).
        let firstStart = forward ? from : 0
        let firstEnd   = forward ? length : from
        view.message(SCI.SETTARGETSTART, wParam: UInt(bitPattern: firstStart))
        view.message(SCI.SETTARGETEND,   wParam: UInt(bitPattern: firstEnd))
        if let hit = searchInTarget(view, pattern: pattern, flags: flags) {
            return (hit, false)
        }
        // Wrap leg.
        let wrapStart = forward ? 0 : length
        let wrapEnd   = forward ? from : 0
        view.message(SCI.SETTARGETSTART, wParam: UInt(bitPattern: wrapStart))
        view.message(SCI.SETTARGETEND,   wParam: UInt(bitPattern: wrapEnd))
        if let hit = searchInTarget(view, pattern: pattern, flags: flags) {
            return (hit, true)
        }
        return nil
    }

    // MARK: - Find: next / prev / live

    func findNext(in view: ScintillaView) {
        let pattern = findState.query
        guard !pattern.isEmpty else { return }
        findState.commitQueryToHistory()
        // Scan forward from the end of the current selection (or
        // caret) so repeated ⌘G actually advances.
        let from = Int(view.message(SCI.GETSELECTIONEND))
        performFind(in: view, from: from, forward: true, pattern: pattern)
    }

    func findPrev(in view: ScintillaView) {
        let pattern = findState.query
        guard !pattern.isEmpty else { return }
        findState.commitQueryToHistory()
        let from = Int(view.message(SCI.GETSELECTIONSTART))
        performFind(in: view, from: from, forward: false, pattern: pattern)
    }

    /// Live-search variant: search forward from the start of the
    /// current selection so growing the query keeps confirming the
    /// hit the user is looking at.
    func findCurrent(in view: ScintillaView) {
        let pattern = findState.query
        guard !pattern.isEmpty else {
            clearHighlights(in: view)
            findState.matchCount = 0
            findState.currentMatch = 0
            findState.status = ""
            return
        }
        let from = Int(view.message(SCI.GETSELECTIONSTART))
        performFind(in: view, from: from, forward: true, pattern: pattern)
    }

    fileprivate func performFind(in view: ScintillaView,
                                 from: Int,
                                 forward: Bool,
                                 pattern: String) {
        let flags = currentSearchFlags()
        guard let hit = searchWithWrap(view,
                                       from: from,
                                       pattern: pattern,
                                       flags: flags,
                                       forward: forward) else {
            findState.currentMatch = 0
            findState.matchCount = 0
            findState.status = FindBarPresentation.noMatchesStatus()
            clearHighlights(in: view)
            return
        }
        view.message(SCI.SETSEL,
                     wParam: UInt(bitPattern: hit.range.lowerBound),
                     lParam: hit.range.upperBound)
        view.message(SCI.SCROLLCARET)
        findState.status = hit.wrapped ? FindBarPresentation.wrappedStatus(forward: forward) : ""
        highlightAllMatches(in: view, pattern: pattern, flags: flags, currentRange: hit.range)
    }

    // MARK: - Replace: current / all

    func replaceCurrent(in view: ScintillaView) {
        let pattern = findState.query
        guard !pattern.isEmpty else { return }

        // SCI_REPLACETARGET operates on the current target range, not
        // the selection. To keep behaviour intuitive, we set the
        // target to the current selection iff it already matches the
        // query, then replace; otherwise we just step to the next
        // match without replacing (matches BBEdit / Sublime).
        let selStart = Int(view.message(SCI.GETSELECTIONSTART))
        let selEnd   = Int(view.message(SCI.GETSELECTIONEND))
        if selEnd > selStart {
            view.message(SCI.SETTARGETSTART, wParam: UInt(bitPattern: selStart))
            view.message(SCI.SETTARGETEND,   wParam: UInt(bitPattern: selEnd))
            if let hit = searchInTarget(view, pattern: pattern, flags: currentSearchFlags()),
               hit == selStart..<selEnd {
                let replacement = findState.replacement
                let replaced = applyReplacement(replacement,
                                                on: view,
                                                regex: findState.regex)
                // After replacement, advance to the next hit.
                let resumeFrom = selStart + replaced
                performFind(in: view, from: resumeFrom, forward: true, pattern: pattern)
                findState.status = FindBarPresentation.replacedStatus()
                return
            }
        }
        // Selection didn't match: just behave like Find Next.
        findNext(in: view)
    }

    func replaceAll(in view: ScintillaView) {
        let pattern = findState.query
        guard !pattern.isEmpty else { return }
        let flags = currentSearchFlags()
        var count = 0
        // Iterate from doc start to end. SCI_REPLACETARGET can grow or
        // shrink the doc; we always advance by the post-replacement
        // target end so we never re-match the substitution itself.
        view.message(SCI.SETTARGETSTART, wParam: 0)
        var docLen = Int(view.message(SCI.GETLENGTH))
        view.message(SCI.SETTARGETEND, wParam: UInt(bitPattern: docLen))
        while let hit = searchInTarget(view, pattern: pattern, flags: flags) {
            view.message(SCI.SETTARGETSTART, wParam: UInt(bitPattern: hit.lowerBound))
            view.message(SCI.SETTARGETEND,   wParam: UInt(bitPattern: hit.upperBound))
            let replaced = applyReplacement(findState.replacement,
                                            on: view,
                                            regex: findState.regex)
            count += 1
            let nextStart = hit.lowerBound + replaced
            docLen = Int(view.message(SCI.GETLENGTH))
            if nextStart >= docLen { break }
            view.message(SCI.SETTARGETSTART, wParam: UInt(bitPattern: nextStart))
            view.message(SCI.SETTARGETEND,   wParam: UInt(bitPattern: docLen))
        }
        findState.status = count == 0
            ? FindBarPresentation.noMatchesStatus()
            : FindBarPresentation.replacedCountStatus(count: count)
        findState.matchCount = 0
        findState.currentMatch = 0
        clearHighlights(in: view)
    }

    /// Drive SCI_REPLACETARGET / SCI_REPLACETARGETRE and return the
    /// length (in bytes) of the inserted replacement so callers can
    /// step past it.
    fileprivate func applyReplacement(_ replacement: String,
                                      on view: ScintillaView,
                                      regex: Bool) -> Int {
        let bytes = Array(replacement.utf8)
        let msg = regex ? SCI.REPLACETARGETRE : SCI.REPLACETARGET
        // Allow the empty replacement (deletion) by passing a NULL
        // pointer with length 0, matching the docs.
        if bytes.isEmpty {
            view.message(msg, wParam: 0, lParam: 0)
        } else {
            _ = bytes.withUnsafeBufferPointer { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return view.message(msg,
                                    wParam: UInt(bytes.count),
                                    lParam: Int(bitPattern: base))
            }
        }
        let s = Int(view.message(SCI.GETTARGETSTART))
        let e = Int(view.message(SCI.GETTARGETEND))
        return max(0, e - s)
    }

    // MARK: - All-matches indicator overlay

    /// Recompute the "highlight all" indicator overlay only when
    /// inputs that affect it actually changed.
    ///
    /// Phase 45-D — the *clear* path still keys off `query` so the
    /// overlay disappears the instant the user empties the field.
    /// The *scan* path keys off `debouncedQuery` so a multi-keystroke
    /// burst collapses to a single full-text re-scan after the user
    /// settles. Between keystrokes the previous overlay is left in
    /// place (no flicker, no churn).
    func refreshHighlightsIfNeeded() {
        guard let view else { return }
        guard findState.isVisible, !findState.query.isEmpty else {
            clearHighlights(in: view)
            return
        }
        let pattern = findState.debouncedQuery
        guard !pattern.isEmpty else { return }
        let flags = currentSearchFlags()
        let docLen = Int(view.message(SCI.GETLENGTH))
        if pattern == lastHighlightedQuery,
           flags == lastHighlightedFlags,
           docLen == lastHighlightedDocLength { return }
        highlightAllMatches(in: view,
                            pattern: pattern,
                            flags: flags,
                            currentRange: nil)
    }

    fileprivate func highlightAllMatches(in view: ScintillaView,
                                         pattern: String,
                                         flags: UInt,
                                         currentRange: Range<Int>?) {
        clearHighlights(in: view)
        view.message(SCI.SETINDICCURRENT, wParam: SCIND.MATCHES)

        let length = Int(view.message(SCI.GETLENGTH))
        var cursor = 0
        var count = 0
        var indexOfCurrent = 0
        while cursor < length {
            view.message(SCI.SETTARGETSTART, wParam: UInt(bitPattern: cursor))
            view.message(SCI.SETTARGETEND,   wParam: UInt(bitPattern: length))
            guard let hit = searchInTarget(view, pattern: pattern, flags: flags) else { break }
            count += 1
            if let cur = currentRange, cur == hit { indexOfCurrent = count }
            view.message(SCI.INDICFILLRANGE,
                         wParam: UInt(bitPattern: hit.lowerBound),
                         lParam: hit.upperBound - hit.lowerBound)
            cursor = hit.upperBound == hit.lowerBound ? hit.upperBound + 1 : hit.upperBound
        }
        findState.matchCount = count
        findState.currentMatch = indexOfCurrent
        lastHighlightedQuery = pattern
        lastHighlightedFlags = flags
        lastHighlightedDocLength = length
    }

    func clearHighlights(in view: ScintillaView) {
        let length = Int(view.message(SCI.GETLENGTH))
        view.message(SCI.SETINDICCURRENT, wParam: SCIND.MATCHES)
        view.message(SCI.INDICCLEARRANGE, wParam: 0, lParam: length)
        lastHighlightedQuery = ""
        lastHighlightedFlags = 0
        lastHighlightedDocLength = -1
    }
}
