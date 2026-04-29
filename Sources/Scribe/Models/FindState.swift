//
//  FindState.swift
//  Phase 4 — observable model behind ⌘F / ⌘R. Lives in the SwiftUI
//  environment so the bar stays visible across tab switches and retains
//  its query / replacement strings, which is what every modern editor
//  does.
//
//  The bar publishes user intent (toggle visibility, change query…)
//  through @Published; the editor coordinator subscribes to a Combine
//  PassthroughSubject for one-shot commands (Find Next, Replace All)
//  that aren't naturally state.
//

import Combine
import Foundation

@MainActor
final class FindState: ObservableObject {
    static let historyMax = 20

    private enum Key {
        static let queryHistory = "find.queryHistory"
        static let replacementHistory = "find.replacementHistory"
    }

    private let defaults: UserDefaults

    /// Show/hide the find bar above the editor.
    @Published var isVisible: Bool = false

    /// `true` shows the second row with the replacement field +
    /// "Replace" / "Replace All" buttons.
    @Published var isReplaceMode: Bool = false

    @Published var query: String = ""
    @Published var replacement: String = ""

    @Published var matchCase: Bool = false
    @Published var wholeWord: Bool = false
    @Published var regex: Bool = false

    /// MRU history of past queries / replacements. Persisted across
    /// launches; surfaced through the bar's history popover so users
    /// can re-run an earlier search without retyping.
    @Published var queryHistory: [String] = []
    @Published var replacementHistory: [String] = []

    /// 1-based ordinal of the currently selected match. `0` means "no
    /// active match". Driven by the editor coordinator after each search.
    @Published var currentMatch: Int = 0
    @Published var matchCount: Int = 0

    /// Short status line shown next to the count, e.g. "Wrapped" or
    /// "Replaced 12". Empty string ⇒ render nothing.
    @Published var status: String = ""

    /// One-shot commands the bar fires at the editor coordinator. The
    /// coordinator owns the search + selection logic; this state struct
    /// stays UI-only.
    enum Command {
        case findNext
        case findPrev
        /// Re-evaluate the search anchored at the *start* of the current
        /// selection — used by live-search-as-you-type so growing the
        /// query doesn't skip the match the user is staring at.
        case findCurrent
        case replaceCurrent
        case replaceAll
        case useSelection
        // Phase 20 — multi-cursor commands. Routed through this same
        // PassthroughSubject so the existing Coordinator sink picks
        // them up without an extra Combine subscription.
        case selectNextOccurrence
        case selectAllOccurrences
        case collapseToSingleCursor
        // Phase 21 — vertical (column-direction) multi-cursor.
        case addCaretAbove
        case addCaretBelow
        // Phase 22 — skip current ⌘D selection and jump to the next.
        case skipAndSelectNextOccurrence
        // Phase 23 — toggle SC_SEL_STREAM ⇄ SC_SEL_RECTANGLE.
        case toggleColumnSelectionMode
        /// Phase 31b — jump the caret to the next / previous git
        /// gutter hunk relative to its current line. Wraps top↔bottom
        /// when past the last / before the first hunk. No-op when
        /// the file has no changes vs HEAD. Routed through the same
        /// PassthroughSubject so the Coordinator's existing sink
        /// dispatches them without an extra subscription.
        case gotoNextHunk
        case gotoPrevHunk
        /// Phase 33 — insert a snippet's body at every active caret.
        /// Reuses the same Scintilla path as `insertAtCarets`; this
        /// case exists so the menu / palette can dispatch a *user-
        /// facing* insertion without going through the test-only
        /// `insertAtCarets` channel below. Multi-line bodies are
        /// honoured (each caret receives the same multi-line text;
        /// undo treats the burst as one transaction).
        case insertSnippet(String)
        /// Phase 37 — apply a text operation to the active editor
        /// selection. The Coordinator owns the Scintilla mutation and
        /// leaves the buffer unchanged if the operation throws.
        case transformSelection(TextTransformAction)
        /// Phase 37 — replace the active editor selection with a
        /// prepared Text Tools result. This is intentionally distinct
        /// from `transformSelection` because the workbench computes the
        /// text outside Scintilla and only needs the mutation path here.
        case replaceSelectionText(String)
        /// Phase 37a — cancel any Scintilla calltip before SwiftUI
        /// presents a sheet or split preview over the editor. Scintilla's
        /// Cocoa calltip window is above modal panels, so overlays must
        /// explicitly dismiss it.
        case hideInlineBlameTooltip
        /// Test-only: inserts the literal string at every caret via
        /// `SCI_REPLACESEL`. Used by the Phase 21 verification hook
        /// to render visible markers at the multi-caret positions —
        /// keystrokes via NSApp.sendAction don't reach ScintillaView.
        /// Not a user-facing command; the menu doesn't expose it.
        case insertAtCarets(String)
        /// Test-only: drives `SCI_LINEDOWNRECTEXTEND` /
        /// `SCI_CHARRIGHTRECTEXTEND` from the verification hook so
        /// the screenshot script can render a rectangular selection
        /// without keystroke synthesis through System Events.
        /// Tuple is (linesDown, charsRight); both can be 0.
        case testRectSelectExtend(linesDown: Int, charsRight: Int)
        /// Test-only: drives Inline Blame into a deterministic state
        /// for screenshot verification. The hook can switch display
        /// density, move the caret to a 1-based line, and optionally
        /// force the commit-summary calltip for a 1-based line after
        /// the blame cache has landed.
        case testInlineBlame(mode: InlineBlameMode,
                             caretLine: Int?,
                             tooltipLine: Int?)
    }
    let commands = PassthroughSubject<Command, Never>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.queryHistory = defaults.stringArray(forKey: Key.queryHistory) ?? []
        self.replacementHistory = defaults.stringArray(forKey: Key.replacementHistory) ?? []
    }

    // MARK: - Convenience

    func show(replaceMode: Bool) {
        isReplaceMode = replaceMode
        isVisible = true
    }

    func hide() {
        isVisible = false
        status = ""
    }

    // MARK: - History

    /// Push the current query onto the MRU stack. Idempotent — duplicates
    /// move to the top. Called when the user explicitly commits the
    /// search (Enter, ⌘G, dismiss with non-empty query).
    func commitQueryToHistory() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queryHistory.removeAll { $0 == trimmed }
        queryHistory.insert(trimmed, at: 0)
        if queryHistory.count > Self.historyMax {
            queryHistory = Array(queryHistory.prefix(Self.historyMax))
        }
        defaults.set(queryHistory, forKey: Key.queryHistory)
    }

    func commitReplacementToHistory() {
        // Allow empty replacement — that's a valid "delete the matches"
        // operation worth re-running. Skip only on whitespace-only entries.
        let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !replacement.isEmpty else { return }
        replacementHistory.removeAll { $0 == replacement }
        replacementHistory.insert(replacement, at: 0)
        if replacementHistory.count > Self.historyMax {
            replacementHistory = Array(replacementHistory.prefix(Self.historyMax))
        }
        defaults.set(replacementHistory, forKey: Key.replacementHistory)
    }

    func clearHistory() {
        queryHistory = []
        replacementHistory = []
        defaults.removeObject(forKey: Key.queryHistory)
        defaults.removeObject(forKey: Key.replacementHistory)
    }
}
