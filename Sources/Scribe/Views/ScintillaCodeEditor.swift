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
        context.coordinator.configureGitGutterMargin(in: view)
        context.coordinator.applyTheme(to: view)
        context.coordinator.configureMatchIndicator(to: view)
        context.coordinator.configureMultiSelection(to: view)
        // Suppress the built-in English right-click menu so SwiftUI's
        // .contextMenu modifier on EditorAreaView can take over. With
        // SC_POPUP_NEVER the responder chain bubbles the right-click
        // up to SwiftUI's gesture system, which then renders our
        // localised menu.
        view.message(SCI.USEPOPUP, wParam: UInt(0))   // SC_POPUP_NEVER
        return view
    }

    func updateNSView(_ view: ScintillaView, context: Context) {
        // Pick up SwiftUI-driven changes to doc/prefs. The coordinator's flag
        // is what stops the SCN_MODIFIED ↔ doc.text feedback loop.
        context.coordinator.doc = doc
        context.coordinator.prefs = prefs
        context.coordinator.findState = findState
        context.coordinator.workspace = workspace

        // Cheap-signature short-circuit: SwiftUI calls updateNSView on
        // every prefs / findState / cursor-tick mutation. For a 20 MB
        // document the old `view.string() != doc.text` path roundtripped
        // the entire buffer through Scintilla → NSString → Swift String
        // every time, even though the typical path (user typing) never
        // mutates doc.text out-of-band — Scintilla is the source of
        // truth via SCN_MODIFIED. We compare byte counts first
        // (`SCI_GETLENGTH` is O(1)); only when they match do we pay
        // for the full equality check that catches the rare external-
        // change race (Workspace.handleExternalChange).
        let viewLen = Int(view.message(SCI.GETLENGTH))
        let docLen = doc.text.utf8.count
        let needsResync: Bool = (viewLen != docLen) || view.string() != doc.text
        if needsResync {
            context.coordinator.applyText(doc.text, to: view, isExternal: true)
        }
        context.coordinator.applyLexer(for: doc, to: view)
        context.coordinator.applyFont(prefs: prefs, to: view)
        context.coordinator.applyTabs(prefs: prefs, to: view)
        context.coordinator.applyTheme(to: view)
        context.coordinator.refreshHighlightsIfNeeded()
        context.coordinator.applyGitGutter(in: view)
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
        /// Module-internal (no `private`) so the same-module
        /// `Coordinator+Theme.swift` extension can read + write it
        /// without the file collapsing back into one giant blob.
        var currentLexer: String = ""

        private var appearanceObserver: NSKeyValueObservation?

        /// Combine sink for FindState.commands (Find Next, Replace All, …).
        private var findCommandSink: AnyCancellable?

        /// Snapshot of the find inputs that the current set of indicator
        /// highlights was drawn for. Lets `refreshHighlightsIfNeeded`
        /// avoid re-drawing every time SwiftUI sends an updateNSView.
        /// Module-internal (no `private`) so the same-module
        /// `Coordinator+Find.swift` extension can drive them — the
        /// matching state is conceptually owned by the find cluster.
        var lastHighlightedQuery: String = ""
        var lastHighlightedFlags: UInt = 0
        var lastHighlightedDocLength: Int = -1

        /// Phase 28c — debounce handle for the SCN_MODIFIED → doc.text
        /// sync. Each modification cancels the previous in-flight Task
        /// and schedules a fresh 50 ms timer; only after the user stops
        /// typing do we pay the O(N) `view.string()` round-trip. Code
        /// paths that need an authoritative `doc.text` (save, external
        /// change check) drain via `flushDocSync()` first.
        private var pendingDocSync: Task<Void, Never>?

        /// Phase 31 — last `[Int: GitGutterStatus]` actually rendered
        /// to the margin. SwiftUI calls `updateNSView` on every
        /// unrelated tick (cursor move, prefs change…), and re-painting
        /// markers is O(line-count) — checking the cached snapshot
        /// against the current `doc.gitGutter` lets us no-op the path
        /// in the common case where nothing about git status moved.
        /// Module-internal so `Coordinator+GitGutter.swift` can read +
        /// write it.
        var lastAppliedGitGutter: [Int: GitGutterStatus] = [:]

        /// 50 ms feels imperceptible to the user but covers the
        /// common burst-typing window (sustained typing rarely sees
        /// keystrokes < 30 ms apart). Lower = stale-text risk before
        /// save; higher = saves can race ahead of the typist.
        private static let docSyncThrottleNanos: UInt64 = 50_000_000

        init(doc: Document, prefs: EditorPreferences, findState: FindState, workspace: Workspace? = nil) {
            self.doc = doc
            self.prefs = prefs
            self.findState = findState
            self.workspace = workspace
            super.init()
            // Install the drain hook on the document so save / external-
            // change paths can pull a fresh snapshot. We capture self
            // weakly — the hook is removed in deinit but a defensive
            // weak ref means a stale closure surviving (e.g. after a
            // doc swap) is a no-op rather than a use-after-free.
            doc.flushPendingEdit = { [weak self] in self?.flushDocSync() }
        }

        deinit {
            appearanceObserver?.invalidate()
            pendingDocSync?.cancel()
            // We *don't* clear `doc.flushPendingEdit` here — Swift 6
            // strict makes deinit nonisolated, and `Document` is
            // `@MainActor`. The drain closure captures `self` weakly,
            // so a stale invocation after Coordinator deinit is a
            // safe no-op rather than a use-after-free. The next
            // Coordinator that takes over the doc overwrites the hook
            // in its init.
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
                    case .toggleColumnSelectionMode: self.toggleColumnSelectionMode()
                    case .gotoNextHunk: self.gotoNextHunk(in: view)
                    case .gotoPrevHunk: self.gotoPrevHunk(in: view)
                    case .insertSnippet(let body): self.insertAtCarets(body, in: view)
                    case .insertAtCarets(let s): self.insertAtCarets(s, in: view)
                    case let .testRectSelectExtend(d, r):
                        self.testRectSelectExtend(linesDown: d, charsRight: r, in: view)
                    }
                }
        }

        // MARK: doc → view

        func applyText(_ text: String, to view: ScintillaView, isExternal: Bool) {
            isApplyingExternalUpdate = isExternal
            view.setString(text)
            isApplyingExternalUpdate = false
            // applyText is the *push* path (doc → view). Any throttled
            // pull (view → doc) is now stale — the view's content was
            // just overwritten. Cancel the pending Task so a delayed
            // tick can't clobber the freshly-pushed text.
            pendingDocSync?.cancel()
            pendingDocSync = nil
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

        // applyLexer / applyTheme / applyLanguageStyles / setStyleColor /
        // sciColor moved to Views/Scintilla/Coordinator+Theme.swift.

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

        // currentSearchFlags / searchInTarget / searchWithWrap /
        // findNext / findPrev / findCurrent / performFind /
        // replaceCurrent / replaceAll / applyReplacement moved to
        // Views/Scintilla/Coordinator+Find.swift.

        // MARK: - Phase 20 multi-cursor commands
        // selectNextOccurrence / skipAndSelectNextOccurrence /
        // selectAllOccurrences / addCaret{Above,Below} /
        // extendCaretsByLine / toggleColumnSelectionMode /
        // testRectSelectExtend / insertAtCarets /
        // collapseToSingleCursor / ensureSelectionForMultiCursor /
        // currentSelectionRanges / mcFindNext / textInRange /
        // currentSelectionText / adoptSelectionAsQuery moved to
        // Views/Scintilla/Coordinator+MultiCursor.swift.


        // refreshHighlightsIfNeeded / highlightAllMatches /
        // clearHighlights moved to Views/Scintilla/Coordinator+Find.swift.

        // MARK: view → doc (ScintillaNotificationProtocol)

        /// Schedule (or reschedule) the throttled doc.text pull.
        /// Each new SCN_MODIFIED cancels the prior in-flight Task so
        /// only the *last* keystroke in a burst pays the round-trip.
        /// The Task is `@MainActor`-bound implicitly via Coordinator.
        private func scheduleDocSync() {
            pendingDocSync?.cancel()
            pendingDocSync = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Coordinator.docSyncThrottleNanos)
                guard let self, !Task.isCancelled else { return }
                self.flushDocSync()
            }
        }

        /// Drain the pending throttled write — called either by the
        /// throttle Task firing, or synchronously by callers that
        /// need an authoritative `doc.text` (Workspace.save,
        /// handleExternalChange) via `doc.flushPendingEdit?()`.
        ///
        /// Reads the entire view buffer; this is the O(N) path we
        /// were paying *per keystroke* before throttling. Now we
        /// pay it once per typing pause, which is what the user
        /// experiences as "the file became saveable".
        func flushDocSync() {
            guard let view else { return }
            pendingDocSync?.cancel()
            pendingDocSync = nil
            let newText = view.string() ?? ""
            if newText != doc.text {
                doc.text = newText
            }
        }

        func notification(_ scn: UnsafeMutablePointer<SCNotification>?) {
            guard let scn else { return }
            let code = scn.pointee.nmhdr.code

            switch code {
            case SCN.MODIFIED:
                if !isApplyingExternalUpdate {
                    // Mark dirty *immediately* so the title bar dot, tab
                    // close-confirm, and "unsaved changes" UI react on
                    // the very first keystroke — only the heavy text
                    // sync is throttled.
                    if !doc.isDirty { doc.isDirty = true }
                    scheduleDocSync()
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
