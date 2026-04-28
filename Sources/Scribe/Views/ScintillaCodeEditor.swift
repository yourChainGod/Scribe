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
    static let REPLACESEL:       UInt32 = 2170
    static let INSERTTEXT:       UInt32 = 2003
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
    // Phase 20 — multi-cursor / multi-selection
    static let SETMULTIPLESELECTION:        UInt32 = 2563
    static let SETADDITIONALSELECTIONTYPING:UInt32 = 2565
    static let SETMULTIPASTE:               UInt32 = 2614
    static let SETSELECTIONMODE:            UInt32 = 2422
    static let GETSELECTIONS:               UInt32 = 2570
    static let CLEARSELECTIONS:             UInt32 = 2571
    static let ADDSELECTION:                UInt32 = 2573
    // Selection N caret/anchor — message IDs verified against
    // Vendor/scintilla/include/Scintilla.h. Earlier phases of
    // this codebase had them swapped with the
    // *VIRTUALSPACE / *START variants, which presented as
    // GETSELECTIONNCARET returning the selection START instead
    // of the caret end. Phase 22 caught it because reading the
    // caret of a forward-anchored selection always returned
    // anchor+0, which broke the maxEnd computation in
    // selectNextOccurrence.
    static let SETSELECTIONNCARET:          UInt32 = 2576
    static let GETSELECTIONNCARET:          UInt32 = 2577
    static let SETSELECTIONNANCHOR:         UInt32 = 2578
    static let GETSELECTIONNANCHOR:         UInt32 = 2579
    static let SETMAINSELECTION:            UInt32 = 2574
    static let GETMAINSELECTION:            UInt32 = 2575
    /// Phase 22 — `SCI_DROPSELECTIONN(int selection)` removes the
    /// numbered selection from the multi-selection set without
    /// touching the others.
    static let DROPSELECTIONN:              UInt32 = 2671
    static let WORDSTARTPOSITION:           UInt32 = 2266
    static let WORDENDPOSITION:             UInt32 = 2267
    static let GETTEXTRANGE:                UInt32 = 2162
    static let GETLINECOUNT:                UInt32 = 2154
    /// Phase 21 — `SCI_FINDCOLUMN(line, column)` returns the byte
    /// position at the given visual column on the given line, or
    /// the line-end position if the line is shorter. Cleanest way
    /// to project a caret column onto an adjacent line.
    static let FINDCOLUMN:                  UInt32 = 2456
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
    /// Phase 18 — Workspace receives the live selection text on every
    /// SCN_UPDATEUI tick so the "Find in Files" command can prefill
    /// the query from whatever the user just highlighted. We don't
    /// observe it here; the coordinator only writes to it.
    @EnvironmentObject var workspace: Workspace

    func makeCoordinator() -> Coordinator {
        Coordinator(doc: doc, prefs: prefs, findState: findState, workspace: workspace)
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
        context.coordinator.configureMultiSelection(to: view)
        return view
    }

    func updateNSView(_ view: ScintillaView, context: Context) {
        // Pick up SwiftUI-driven changes to doc/prefs. The coordinator's flag
        // is what stops the SCN_MODIFIED ↔ doc.text feedback loop.
        context.coordinator.doc = doc
        context.coordinator.prefs = prefs
        context.coordinator.findState = findState
        context.coordinator.workspace = workspace

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
        /// Workspace receives the live selection text. Held weak —
        /// Coordinator is owned by the SwiftUI Representable's
        /// state, Workspace lives at the app root, no retain cycle
        /// risk but weakness reads cleaner against future refactors.
        weak var workspace: Workspace?
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

        init(doc: Document, prefs: EditorPreferences, findState: FindState, workspace: Workspace? = nil) {
            self.doc = doc
            self.prefs = prefs
            self.findState = findState
            self.workspace = workspace
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
                    case .selectNextOccurrence: self.selectNextOccurrence()
                    case .selectAllOccurrences: self.selectAllOccurrences()
                    case .collapseToSingleCursor: self.collapseToSingleCursor()
                    case .addCaretAbove: self.addCaretAbove()
                    case .addCaretBelow: self.addCaretBelow()
                    case .skipAndSelectNextOccurrence: self.skipAndSelectNextOccurrence()
                    case .insertAtCarets(let s): self.insertAtCarets(s, in: view)
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

        /// Phase 20 — enable Scintilla's native multi-cursor support.
        /// The defaults are surprising: SCI_SETMULTIPLESELECTION and
        /// SCI_SETADDITIONALSELECTIONTYPING are both off out of the
        /// box, so ⌥-click selects rectangularly instead of adding a
        /// caret, and typing into a multi-selection only modifies
        /// the main one. Toggling them on lights up the entire
        /// multi-cursor experience the editor would otherwise lack.
        ///
        /// Multi-paste also gets enabled here (`SC_MULTIPASTE_EACH = 1`)
        /// so the clipboard pastes once per cursor — matches VSCode +
        /// Sublime + most modern editors.
        func configureMultiSelection(to view: ScintillaView) {
            view.message(SCI.SETMULTIPLESELECTION, wParam: 1)
            view.message(SCI.SETADDITIONALSELECTIONTYPING, wParam: 1)
            view.message(SCI.SETMULTIPASTE, wParam: 1)
        }

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

        // MARK: - Phase 20 multi-cursor commands

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
            if let range = findNext(needle: needle,
                                    in: view,
                                    from: maxEnd,
                                    to: docLen,
                                    skip: existing)
                ?? findNext(needle: needle,
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
            let range = findNext(needle: needle,
                                 in: view,
                                 from: mainEnd,
                                 to: docLen,
                                 skip: existing)
                ?? findNext(needle: needle,
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
                guard let r = findNext(needle: needle,
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
        private func extendCaretsByLine(delta: Int) {
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

        /// If there's already a selection, returns its text. If the
        /// caret is at a word, expands to that word and returns it.
        /// Otherwise returns "".
        private func ensureSelectionForMultiCursor(in view: ScintillaView) -> String {
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
        private func currentSelectionRanges(in view: ScintillaView) -> [Range<Int>] {
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
        private func findNext(needle: String,
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
                return findNext(needle: needle,
                                in: view,
                                from: e,
                                to: to,
                                skip: skip)
            }
            return r
        }

        private func textInRange(in view: ScintillaView, range: Range<Int>) -> String {
            guard let raw = view.string() else { return "" }
            let bytes = Array(raw.utf8)
            guard range.upperBound <= bytes.count else { return "" }
            let slice = Array(bytes[range])
            return String(data: Data(slice), encoding: .utf8) ?? ""
        }

        /// Phase 18 — read the current selection as a UTF-8 String,
        /// suitable for prefilling a Find query. Returns "" when the
        /// caret has no actual range or the bytes don't decode.
        /// Multi-line selections are truncated at the first newline
        /// because Find in Files is a single-line query field.
        private func currentSelectionText(in view: ScintillaView) -> String {
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
                    // Phase 18 — push the live selection to Workspace so
                    // the "Find in Files" command can prefill its query
                    // from whatever the user just highlighted. Single-
                    // line truncation matches what users intuitively
                    // expect (the Find bar isn't multi-line).
                    if let workspace {
                        workspace.activeSelection = currentSelectionText(in: view)
                    }
                }
            default:
                break
            }
        }
    }
}
