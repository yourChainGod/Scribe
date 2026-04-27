//
//  ScintillaCodeEditor.swift
//  Default editor since Phase 1.7c. Wraps Scintilla's NSView-based
//  ScintillaView in a SwiftUI NSViewRepresentable.
//
//  Coordinator implements ScintillaNotificationProtocol for two-way sync:
//    SCN_MODIFIED  → view.string() is written back to doc.text + dirty flag
//    SCN_UPDATEUI  → cursor row/col is pushed to doc.cursorLine/Column
//  An isApplyingExternalUpdate guard breaks the doc → view → doc echo.
//
//  Themes track NSApp.effectiveAppearance via KVO; tab width / soft tabs
//  follow EditorPreferences live.
//

import AppKit
import Combine
import SwiftUI
import Scintilla
import Lexilla

// MARK: - SCI_* / SCN_* numeric constants
//
// Scintilla.h defines these as plain `#define`d integers; Swift's clang
// importer doesn't always pick them up, so we mirror the ones we use.
// Values verified against Vendor/scintilla/include/Scintilla.h on Scintilla 5.6.1.
private enum SCI {
    // Queries
    static let GETLENGTH:        UInt32 = 2006
    static let GETCURRENTPOS:    UInt32 = 2008
    static let LINEFROMPOSITION: UInt32 = 2166
    static let GETCOLUMN:        UInt32 = 2129
    static let GETSELECTIONSTART:UInt32 = 2143
    static let GETSELECTIONEND:  UInt32 = 2145
    static let GETSELTEXT:       UInt32 = 2161
    static let POSITIONFROMLINE: UInt32 = 2167
    static let GETLINEENDPOSITION: UInt32 = 2136
    static let GOTOLINE:         UInt32 = 2024
    // Tabs
    static let SETTABWIDTH:      UInt32 = 2036
    static let SETUSETABS:       UInt32 = 2124
    // Margins
    static let SETMARGINTYPEN:   UInt32 = 2240
    static let SETMARGINWIDTHN:  UInt32 = 2242
    // Styles
    static let STYLECLEARALL:    UInt32 = 2050
    static let STYLESETFORE:     UInt32 = 2051
    static let STYLESETBACK:     UInt32 = 2052
    static let SETSELFORE:       UInt32 = 2067
    static let SETSELBACK:       UInt32 = 2068
    static let SETCARETFORE:     UInt32 = 2069
    static let STYLESETSIZE:     UInt32 = 2055
    static let STYLESETFONT:     UInt32 = 2056
    static let SETKEYWORDS:      UInt32 = 4005
    static let SETILEXER:        UInt32 = 4033
    // Selection / scrolling
    static let SETSEL:           UInt32 = 2160
    static let SCROLLCARET:      UInt32 = 2169
    // Search
    static let SETTARGETSTART:   UInt32 = 2190
    static let GETTARGETSTART:   UInt32 = 2191
    static let SETTARGETEND:     UInt32 = 2192
    static let GETTARGETEND:     UInt32 = 2193
    static let REPLACETARGET:    UInt32 = 2194
    static let REPLACETARGETRE:  UInt32 = 2195
    static let SEARCHINTARGET:   UInt32 = 2197
    static let SETSEARCHFLAGS:   UInt32 = 2198
    // Indicators (for "highlight all matches")
    static let INDICSETSTYLE:    UInt32 = 2080
    static let INDICSETFORE:     UInt32 = 2082
    static let INDICSETALPHA:    UInt32 = 2523
    static let INDICSETUNDER:    UInt32 = 2510
    static let SETINDICCURRENT:  UInt32 = 2500
    static let INDICFILLRANGE:   UInt32 = 2504
    static let INDICCLEARRANGE:  UInt32 = 2505
}

/// Search flags as documented in Scintilla.h.
private enum SCFIND {
    static let MATCHCASE: UInt = 4
    static let WHOLEWORD: UInt = 2
    static let REGEXP:    UInt = 0x00200000
    static let CXX11REGEX:UInt = 0x00400000
}

/// Indicator style indices we use for the find bar.
private enum SCIND {
    /// Indicator index 0 (out of 0–7 user-available; 8–31 are reserved
    /// by Scintilla for things like decorations).
    static let MATCHES:   UInt = 0
    /// INDIC_ROUNDBOX = 7 — translucent rounded rectangle, common for
    /// "all matches" overlays.
    static let ROUNDBOX:  Int  = 7
}

private enum SC {
    static let MARGIN_NUMBER:    Int = 1
    static let STYLE_DEFAULT:    Int = 32
    static let STYLE_LINENUMBER: Int = 33
}

/// Lexilla SCE_C_* style indices used by the C/C++/JS/Swift lexers
/// (LexerCatalog falls back to lmCPP for these). Verified against
/// Vendor/lexilla/include/SciLexer.h.
private enum SCE_C {
    static let DEFAULT:      Int = 0
    static let COMMENT:      Int = 1
    static let COMMENTLINE:  Int = 2
    static let COMMENTDOC:   Int = 3
    static let NUMBER:       Int = 4
    static let WORD:         Int = 5
    static let STRING:       Int = 6
    static let CHARACTER:    Int = 7
    static let PREPROCESSOR: Int = 9
    static let OPERATOR:     Int = 10
    static let IDENTIFIER:   Int = 11
    static let WORD2:        Int = 16
    static let GLOBALCLASS:  Int = 19
}

/// Lexilla SCE_P_* style indices used by the Python lexer.
private enum SCE_P {
    static let DEFAULT:      Int = 0
    static let COMMENTLINE:  Int = 1
    static let NUMBER:       Int = 2
    static let STRING:       Int = 3
    static let CHARACTER:    Int = 4
    static let WORD:         Int = 5
    static let TRIPLE:       Int = 6
    static let TRIPLEDOUBLE: Int = 7
    static let CLASSNAME:    Int = 8
    static let DEFNAME:      Int = 9
    static let OPERATOR:     Int = 10
    static let IDENTIFIER:   Int = 11
    static let COMMENTBLOCK: Int = 12
    static let WORD2:        Int = 14
    static let DECORATOR:    Int = 15
    static let FSTRING:      Int = 16
}

private enum SCN {
    static let MODIFIED: UInt32 = 2008
    static let UPDATEUI: UInt32 = 2007
}

// MARK: - SwiftUI representable

struct ScintillaCodeEditor: NSViewRepresentable {
    @ObservedObject var doc: Document
    @ObservedObject var prefs: EditorPreferences
    @ObservedObject var findState: FindState

    func makeCoordinator() -> Coordinator {
        Coordinator(doc: doc, prefs: prefs, findState: findState)
    }

    func makeNSView(context: Context) -> ScintillaView {
        let view = ScintillaView(frame: .zero)
        view.setEditable(true)
        view.delegate = context.coordinator   // ScintillaNotificationProtocol
        context.coordinator.attach(view: view)

        // Initial state push. Lexer must precede font + theme so per-style
        // applies hit the right SCE_* indices.
        context.coordinator.applyText(doc.text, to: view, isExternal: true)
        context.coordinator.applyLexer(for: doc, to: view)
        context.coordinator.applyFont(prefs: prefs, to: view)
        context.coordinator.applyTabs(prefs: prefs, to: view)
        context.coordinator.applyLineNumberMargin(to: view)
        context.coordinator.applyTheme(to: view)
        context.coordinator.configureMatchIndicator(to: view)
        return view
    }

    func updateNSView(_ view: ScintillaView, context: Context) {
        // Pick up SwiftUI-driven changes to doc/prefs. The coordinator's flag
        // is what stops the SCN_MODIFIED ↔ doc.text feedback loop.
        context.coordinator.doc = doc
        context.coordinator.prefs = prefs
        context.coordinator.findState = findState

        if view.string() != doc.text {
            context.coordinator.applyText(doc.text, to: view, isExternal: true)
        }
        context.coordinator.applyLexer(for: doc, to: view)
        context.coordinator.applyFont(prefs: prefs, to: view)
        context.coordinator.applyTabs(prefs: prefs, to: view)
        context.coordinator.applyTheme(to: view)
        context.coordinator.refreshHighlightsIfNeeded()
        context.coordinator.consumePendingScroll(in: view)
    }

    // MARK: - Coordinator (Scintilla delegate)

    @MainActor
    final class Coordinator: NSObject, @preconcurrency ScintillaNotificationProtocol {
        var doc: Document
        var prefs: EditorPreferences
        var findState: FindState
        weak var view: ScintillaView?

        /// `true` while we are pushing doc → view; suppresses the SCN_MODIFIED
        /// echo that would otherwise overwrite doc.text with the same content.
        private var isApplyingExternalUpdate = false

        /// Lexer currently set on the view. Tracked so we only call
        /// `SCI_SETILEXER` when the language actually changes.
        private var currentLexer: String = ""

        private var appearanceObserver: NSKeyValueObservation?

        /// Combine sink for FindState.commands (Find Next, Replace All, …).
        private var findCommandSink: AnyCancellable?

        /// Snapshot of the find inputs that the current set of indicator
        /// highlights was drawn for. Lets `refreshHighlightsIfNeeded`
        /// avoid re-drawing every time SwiftUI sends an updateNSView.
        private var lastHighlightedQuery: String = ""
        private var lastHighlightedFlags: UInt = 0
        private var lastHighlightedDocLength: Int = -1

        init(doc: Document, prefs: EditorPreferences, findState: FindState) {
            self.doc = doc
            self.prefs = prefs
            self.findState = findState
            super.init()
        }

        deinit {
            appearanceObserver?.invalidate()
        }

        func attach(view: ScintillaView) {
            self.view = view
            // Re-theme when the user toggles light/dark in System Settings.
            // We can't capture self in a Sendable closure under strict
            // concurrency, so use a weak NSApp KVO and dispatch onto main.
            appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self, weak view] _, _ in
                guard let self, let view else { return }
                Task { @MainActor in
                    self.applyTheme(to: view)
                }
            }
            // Subscribe to one-shot find commands. The bar publishes; we
            // dispatch into the appropriate Scintilla call.
            findCommandSink = findState.commands
                .receive(on: DispatchQueue.main)
                .sink { [weak self] cmd in
                    guard let self, let view = self.view else { return }
                    switch cmd {
                    case .findNext:       self.findNext(in: view)
                    case .findPrev:       self.findPrev(in: view)
                    case .findCurrent:    self.findCurrent(in: view)
                    case .replaceCurrent: self.replaceCurrent(in: view)
                    case .replaceAll:     self.replaceAll(in: view)
                    case .useSelection:   self.adoptSelectionAsQuery(from: view)
                    }
                }
        }

        // MARK: doc → view

        func applyText(_ text: String, to view: ScintillaView, isExternal: Bool) {
            isApplyingExternalUpdate = isExternal
            view.setString(text)
            isApplyingExternalUpdate = false
        }

        func applyFont(prefs: EditorPreferences, to view: ScintillaView) {
            let family = prefs.fontName.isEmpty ? "Menlo" : prefs.fontName
            view.setFontName(family,
                             size: Int32(prefs.fontSize.rounded()),
                             bold: false,
                             italic: false)
        }

        func applyTabs(prefs: EditorPreferences, to view: ScintillaView) {
            view.message(SCI.SETTABWIDTH, wParam: UInt(prefs.tabWidth))
            view.message(SCI.SETUSETABS, wParam: prefs.softTabs ? 0 : 1)
        }

        func applyLineNumberMargin(to view: ScintillaView) {
            // Margin 0 = line numbers, ~44px wide.
            view.message(SCI.SETMARGINTYPEN, wParam: 0, lParam: Int(SC.MARGIN_NUMBER))
            view.message(SCI.SETMARGINWIDTHN, wParam: 0, lParam: 44)
        }

        func applyLexer(for doc: Document, to view: ScintillaView) {
            let descriptor = LexerCatalog.descriptor(for: doc)
            guard descriptor.lexillaName != currentLexer else { return }
            currentLexer = descriptor.lexillaName

            // Empty name ⇒ leave Scintilla on its default null lexer.
            if descriptor.lexillaName.isEmpty {
                view.setReferenceProperty(Int32(SCI.SETILEXER), parameter: 0, value: nil)
                return
            }
            if let lexerPtr = LexillaBridgeCreateLexer(descriptor.lexillaName) {
                view.setReferenceProperty(Int32(SCI.SETILEXER), parameter: 0, value: lexerPtr)
                for (idx, words) in descriptor.keywords.enumerated() {
                    view.setStringProperty(Int32(SCI.SETKEYWORDS),
                                           parameter: idx,
                                           value: words)
                }
            }
        }

        func applyTheme(to view: ScintillaView) {
            // Phase 15: prefer the user-chosen theme. `.system` falls
            // back to the original "follow NSAppearance" behaviour, so
            // existing default-theme users see no change.
            let theme = prefs.themeID.resolve(appearance: NSApp.effectiveAppearance)

            // STYLE_DEFAULT first — STYLECLEARALL copies it to every other style.
            view.message(SCI.STYLESETBACK, wParam: UInt(SC.STYLE_DEFAULT), lParam: sciColor(theme.background))
            view.message(SCI.STYLESETFORE, wParam: UInt(SC.STYLE_DEFAULT), lParam: sciColor(theme.foreground))
            view.message(SCI.STYLECLEARALL)

            // Line-number margin.
            view.message(SCI.STYLESETBACK, wParam: UInt(SC.STYLE_LINENUMBER), lParam: sciColor(theme.marginBackground))
            view.message(SCI.STYLESETFORE, wParam: UInt(SC.STYLE_LINENUMBER), lParam: sciColor(theme.marginForeground))

            // Selection + caret.
            view.message(SCI.SETSELBACK, wParam: 1, lParam: sciColor(theme.selectionBackground))
            view.message(SCI.SETCARETFORE, wParam: UInt(bitPattern: sciColor(theme.caret)))

            // Per-token colours depend on which lexer family is active.
            applyLanguageStyles(theme: theme, lexer: currentLexer, to: view)
        }

        /// Push token colours to the SCE_* style indices for the active
        /// lexer family. Adding a new family is two changes here:
        /// LexerCatalog mapping + a case in this switch.
        private func applyLanguageStyles(theme: Theme, lexer: String, to view: ScintillaView) {
            switch lexer {
            case "cpp", "javascript":
                setStyleColor(view, SCE_C.WORD,         fg: theme.keyword)
                setStyleColor(view, SCE_C.WORD2,        fg: theme.type)
                setStyleColor(view, SCE_C.STRING,       fg: theme.string)
                setStyleColor(view, SCE_C.CHARACTER,    fg: theme.string)
                setStyleColor(view, SCE_C.COMMENT,      fg: theme.comment)
                setStyleColor(view, SCE_C.COMMENTLINE,  fg: theme.comment)
                setStyleColor(view, SCE_C.COMMENTDOC,   fg: theme.comment)
                setStyleColor(view, SCE_C.NUMBER,       fg: theme.number)
                setStyleColor(view, SCE_C.PREPROCESSOR, fg: theme.preprocessor)
                setStyleColor(view, SCE_C.IDENTIFIER,   fg: theme.identifier)
                setStyleColor(view, SCE_C.GLOBALCLASS,  fg: theme.type)
            case "python":
                setStyleColor(view, SCE_P.WORD,         fg: theme.keyword)
                setStyleColor(view, SCE_P.WORD2,        fg: theme.type)
                setStyleColor(view, SCE_P.STRING,       fg: theme.string)
                setStyleColor(view, SCE_P.CHARACTER,    fg: theme.string)
                setStyleColor(view, SCE_P.TRIPLE,       fg: theme.string)
                setStyleColor(view, SCE_P.TRIPLEDOUBLE, fg: theme.string)
                setStyleColor(view, SCE_P.FSTRING,      fg: theme.string)
                setStyleColor(view, SCE_P.COMMENTLINE,  fg: theme.comment)
                setStyleColor(view, SCE_P.COMMENTBLOCK, fg: theme.comment)
                setStyleColor(view, SCE_P.NUMBER,       fg: theme.number)
                setStyleColor(view, SCE_P.CLASSNAME,    fg: theme.type)
                setStyleColor(view, SCE_P.DEFNAME,      fg: theme.type)
                setStyleColor(view, SCE_P.DECORATOR,    fg: theme.preprocessor)
                setStyleColor(view, SCE_P.IDENTIFIER,   fg: theme.identifier)
            default:
                break
            }
        }

        /// Convenience: set foreground for a SCE_* style index.
        private func setStyleColor(_ view: ScintillaView, _ style: Int, fg rgb: Int) {
            view.message(SCI.STYLESETFORE, wParam: UInt(style), lParam: sciColor(rgb))
        }

        /// Scintilla packs colours as 0x00BBGGRR in an `sptr_t`. Argument
        /// is a plain 0xRRGGBB integer.
        private func sciColor(_ rgb: Int) -> Int {
            let r = (rgb >> 16) & 0xFF
            let g = (rgb >> 8)  & 0xFF
            let b =  rgb        & 0xFF
            return (b << 16) | (g << 8) | r
        }

        // MARK: - Pending scroll (cross-file find jump)

        /// If `doc.pendingScrollLine` is set, scroll there + select the
        /// whole line, then clear the pending value. Idempotent.
        func consumePendingScroll(in view: ScintillaView) {
            guard let line = doc.pendingScrollLine else { return }
            doc.pendingScrollLine = nil
            // Scintilla line index is 0-based; our pending value is 1-based.
            let line0 = max(0, line - 1)
            view.message(SCI.GOTOLINE, wParam: UInt(line0))
            let lineStart = view.message(SCI.POSITIONFROMLINE, wParam: UInt(line0))
            let lineEnd   = view.message(SCI.GETLINEENDPOSITION, wParam: UInt(line0))
            view.message(SCI.SETSEL,
                         wParam: UInt(bitPattern: Int(lineStart)),
                         lParam: Int(lineEnd))
            view.message(SCI.SCROLLCARET)
        }

        // MARK: - Find / Replace

        /// One-time setup of indicator 0 — translucent rounded box used
        /// for "highlight all matches".
        func configureMatchIndicator(to view: ScintillaView) {
            view.message(SCI.INDICSETSTYLE, wParam: SCIND.MATCHES, lParam: SCIND.ROUNDBOX)
            view.message(SCI.INDICSETUNDER, wParam: SCIND.MATCHES, lParam: 1)   // draw under text
            view.message(SCI.INDICSETALPHA, wParam: SCIND.MATCHES, lParam: 80)
            view.message(SCI.INDICSETFORE,  wParam: SCIND.MATCHES, lParam: sciColor(0xF1C40F))
        }

        /// Pack the live find toggles into Scintilla's flag bitmask.
        private func currentSearchFlags() -> UInt {
            var flags: UInt = 0
            if findState.matchCase { flags |= SCFIND.MATCHCASE }
            if findState.wholeWord { flags |= SCFIND.WHOLEWORD }
            if findState.regex     { flags |= SCFIND.REGEXP | SCFIND.CXX11REGEX }
            return flags
        }

        /// Run a single SCI_SEARCHINTARGET pass with the target window
        /// already configured by the caller. Returns the matched range
        /// (in document bytes) or `nil` if the lookup misses.
        private func searchInTarget(_ view: ScintillaView,
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
        private func searchWithWrap(_ view: ScintillaView,
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

        private func performFind(in view: ScintillaView,
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
                findState.status = "No matches"
                clearHighlights(in: view)
                return
            }
            view.message(SCI.SETSEL,
                         wParam: UInt(bitPattern: hit.range.lowerBound),
                         lParam: hit.range.upperBound)
            view.message(SCI.SCROLLCARET)
            findState.status = hit.wrapped ? (forward ? "Wrapped to top" : "Wrapped to bottom") : ""
            highlightAllMatches(in: view, pattern: pattern, flags: flags, currentRange: hit.range)
        }

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
                    findState.status = "Replaced"
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
            findState.status = count == 0 ? "No matches" : "Replaced \(count)"
            findState.matchCount = 0
            findState.currentMatch = 0
            clearHighlights(in: view)
        }

        /// Drive SCI_REPLACETARGET / SCI_REPLACETARGETRE and return the
        /// length (in bytes) of the inserted replacement so callers can
        /// step past it.
        private func applyReplacement(_ replacement: String,
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

        // MARK: All-matches indicator

        /// Recompute the "highlight all" indicator overlay only when
        /// inputs that affect it actually changed.
        func refreshHighlightsIfNeeded() {
            guard let view else { return }
            guard findState.isVisible, !findState.query.isEmpty else {
                clearHighlights(in: view)
                return
            }
            let flags = currentSearchFlags()
            let docLen = Int(view.message(SCI.GETLENGTH))
            if findState.query == lastHighlightedQuery,
               flags == lastHighlightedFlags,
               docLen == lastHighlightedDocLength { return }
            highlightAllMatches(in: view,
                                pattern: findState.query,
                                flags: flags,
                                currentRange: nil)
        }

        private func highlightAllMatches(in view: ScintillaView,
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

        private func clearHighlights(in view: ScintillaView) {
            let length = Int(view.message(SCI.GETLENGTH))
            view.message(SCI.SETINDICCURRENT, wParam: SCIND.MATCHES)
            view.message(SCI.INDICCLEARRANGE, wParam: 0, lParam: length)
            lastHighlightedQuery = ""
            lastHighlightedFlags = 0
            lastHighlightedDocLength = -1
        }

        // MARK: view → doc (ScintillaNotificationProtocol)

        func notification(_ scn: UnsafeMutablePointer<SCNotification>?) {
            guard let scn else { return }
            let code = scn.pointee.nmhdr.code

            switch code {
            case SCN.MODIFIED:
                if !isApplyingExternalUpdate, let view {
                    let newText = view.string() ?? ""
                    if newText != doc.text {
                        doc.text = newText
                        if !doc.isDirty { doc.isDirty = true }
                    }
                }
            case SCN.UPDATEUI:
                if let view {
                    let pos = view.message(SCI.GETCURRENTPOS)
                    let line = view.message(SCI.LINEFROMPOSITION, wParam: UInt(pos))
                    let col = view.message(SCI.GETCOLUMN, wParam: UInt(pos))
                    let line1 = Int(line) + 1   // Scintilla is 0-based
                    let col1  = Int(col)  + 1
                    if doc.cursorLine != line1 { doc.cursorLine = line1 }
                    if doc.cursorColumn != col1 { doc.cursorColumn = col1 }
                }
            default:
                break
            }
        }
    }
}
