//
//  Coordinator+InlineBlame.swift
//  Phase 35c-ii-γ — Scintilla EOL annotation integration for the
//  inline-blame chip. The data layer (GitClient.blame), the
//  formatter (RelativeTime / InlineBlameFormatter), and the cache
//  (GitBlameEngine) all landed in earlier sub-phases; this
//  extension is the bridge between them and the Scintilla view:
//  every caret tick + every blame-cache update repaints trailing
//  labels according to the user's Inline Blame mode.
//
//  Display rules:
//    - Active caret line carries
//          "  {Author}, {relative-time} • {sha7}"
//      Two leading spaces give a visual gap between the source
//      line's last character and the chip; zed uses three but
//      two read cleaner against Scintilla's caret highlight band.
//    - Current Line mode keeps the pre-settings behaviour: only
//      the main caret line has an annotation.
//    - All Lines mode paints every cached committed blame line.
//      This is intentionally opt-in because it is denser and costs
//      O(blamed-lines) per repaint.
//    - Off mode clears the EOL annotations and hides the global
//      annotation surface.
//    - Lines without blame data (untracked / not in repo /
//      engine hasn't fetched yet / commit is the all-zeros
//      uncommitted sentinel) get no annotation. Inline blame
//      stays silent until git has something interesting to say.
//    - Multi-cursor in Current Line mode: only the *main* caret's
//      line carries the chip; additional carets stay quiet. The
//      main caret is what `SCI_GETCURRENTPOS` returns, so this
//      falls out for free.
//
//  Refresh triggers:
//    1. SCN_UPDATEUI — fires whenever the caret moves, the
//       selection changes, or a style refresh paints. We hook
//       it in `notification(_:)` and call applyInlineBlame.
//    2. Engine cache mutation — `subscribeToInlineBlame(view:)`
//       installs a Combine sink on `engine.$blameByURL`. A
//       freshly-landed blame, a folder switch, a save-driven
//       refresh all flow through that publisher.
//    3. SwiftUI updateNSView — covers the lifecycle case where
//       the view is recreated for a different doc.
//
//  Why a separate style index (`SC.STYLE_INLINE_BLAME = 40`):
//    Scintilla's predefined styles run 32–39 (default / line
//    number / brace match / control char / indent guide / call
//    tip / fold display text). Lexilla emits 0–31 for
//    per-language token colouring. 40 is the first user-
//    available slot, so colouring it can't collide with the
//    active lexer's per-language styles or with Scintilla's
//    own UI affordances.
//

import AppKit
import Combine
import Scintilla

extension ScintillaCodeEditor.Coordinator {

    // MARK: - Setup

    /// One-time Scintilla setup for the inline-blame style + the
    /// global EOL-annotation visibility toggle. Idempotent: safe
    /// to call from `makeNSView` on every Coordinator attach.
    /// Module-internal (no `func` modifier) so ScintillaCodeEditor
    /// in the same module can call it from `makeNSView`.
    func configureInlineBlame(in view: ScintillaView) {
        // Stadium = soft rounded chip à la zed / GitLens. The
        // alternatives (BOXED, STANDARD) draw harder borders that
        // crowd out the source line.
        view.message(SCI.EOLANNOTATIONSETVISIBLE,
                     wParam: UInt(SC.EOLANNOTATION_STADIUM))
        // Soft grey for the chip text. We don't bind this into
        // the active theme's `comment` colour because most
        // themes pick a saturated comment fg ("blue-grey",
        // "green-grey") that would make the chip louder than
        // the source code. A fixed neutral grey reads as
        // low-emphasis on every theme we ship; 35c-iii can
        // swap it for a per-theme value if a future theme
        // actually clashes.
        view.message(SCI.STYLESETFORE,
                     wParam: UInt(SC.STYLE_INLINE_BLAME),
                     lParam: sciColor(0x808080))
        // Italic to further pull the chip away from real source
        // text. Italic + grey + chip shape is the conventional
        // "out-of-band annotation" treatment across editors.
        view.message(SCI.STYLESETITALIC,
                     wParam: UInt(SC.STYLE_INLINE_BLAME),
                     lParam: 1)
        view.message(SCI.CALLTIPUSESTYLE, wParam: 0)
        view.message(SCI.SETMOUSEDWELLTIME, wParam: 650)
    }

    /// Subscribe to the workspace's blame engine so a cache
    /// update (request lands, save invalidates, folder switch
    /// clears) repaints the chip on the visible caret line.
    /// Combine sinks fire on the main run loop already because
    /// GitBlameEngine is `@MainActor`; we still receive(on:
    /// RunLoop.main) for symmetry with the appearance observer
    /// + findCommandSink installed in attach(view:).
    ///
    /// Idempotent: the previous sink is dropped before the new
    /// one is installed (Combine's AnyCancellable cancels on
    /// reassignment).
    func subscribeToInlineBlame(view: ScintillaView) {
        guard let engine = workspace?.gitBlameEngine else { return }
        blameSink = engine.$blameByURL
            .receive(on: RunLoop.main)
            .sink { [weak self, weak view] _ in
                guard let self, let view else { return }
                Task { @MainActor in
                    self.applyInlineBlame(in: view)
                }
            }
    }

    // MARK: - Render

    /// Repaint inline-blame annotations for the selected mode.
    /// Current Line stays cheap (clear + maybe set one line);
    /// All Lines intentionally walks the cached blame map because
    /// the user explicitly asked for the denser view.
    ///
    /// Painting is "clear-all then maybe-set-one" rather than
    /// "track-previous-line then clear-just-it" because:
    ///   1. EOLANNOTATIONCLEARALL is a single Scintilla call
    ///      that the buffer already supports as a fast path.
    ///   2. We never have more than one active annotation at
    ///      any time, so "clear all" is a no-op unless we just
    ///      painted one.
    ///   3. Tracking "previous line" would require either a
    ///      stored property that races with multi-thread cache
    ///      updates, or a buffer scan to find the painted line —
    ///      both more code than just clearing.
    func applyInlineBlame(in view: ScintillaView) {
        view.message(SCI.EOLANNOTATIONCLEARALL)
        guard prefs.inlineBlameMode != .off else {
            view.message(SCI.EOLANNOTATIONSETVISIBLE,
                         wParam: UInt(SC.EOLANNOTATION_HIDDEN))
            return
        }
        view.message(SCI.EOLANNOTATIONSETVISIBLE,
                     wParam: UInt(SC.EOLANNOTATION_STADIUM))
        guard let url = doc.url else { return }
        guard let engine = workspace?.gitBlameEngine else { return }
        let currentAuthor = engine.currentAuthorName(for: url)

        switch prefs.inlineBlameMode {
        case .off:
            return
        case .currentLine:
            applyCurrentLineInlineBlame(in: view,
                                        url: url,
                                        engine: engine,
                                        currentAuthorName: currentAuthor)
        case .allLines:
            applyAllInlineBlames(in: view,
                                 url: url,
                                 engine: engine,
                                 currentAuthorName: currentAuthor)
        }
    }

    private func applyCurrentLineInlineBlame(in view: ScintillaView,
                                             url: URL,
                                             engine: GitBlameEngine,
                                             currentAuthorName: String?) {
        let pos = view.message(SCI.GETCURRENTPOS)
        let line0 = view.message(SCI.LINEFROMPOSITION,
                                 wParam: UInt(pos))
        // GitBlameEngine speaks 1-based line numbers (matching
        // GitClient + the gutter); Scintilla speaks 0-based.
        // Convert at the boundary, not throughout the call site.
        let lineNo = Int(line0) + 1
        guard let blame = engine.blameLine(for: url, line: lineNo) else { return }
        // The all-zeros sentinel is git's "this line is in the
        // working tree, not yet committed" marker. Showing
        // "Not Committed Yet, just now • 0000000" reads as
        // visual noise when every fresh edit triggers it; we
        // stay quiet until there's an actual commit to credit.
        if blame.isUncommitted { return }
        setInlineBlame(blame,
                       line0: Int(line0),
                       currentAuthorName: currentAuthorName,
                       in: view)
    }

    private func applyAllInlineBlames(in view: ScintillaView,
                                      url: URL,
                                      engine: GitBlameEngine,
                                      currentAuthorName: String?) {
        guard let lines = engine.blameLines(for: url) else { return }
        let lineCount = Int(view.message(SCI.GETLINECOUNT))
        for (lineNo, blame) in lines where !blame.isUncommitted {
            let line0 = lineNo - 1
            guard line0 >= 0, line0 < lineCount else { continue }
            setInlineBlame(blame,
                           line0: line0,
                           currentAuthorName: currentAuthorName,
                           in: view)
        }
    }

    private func setInlineBlame(_ blame: GitClient.BlameLine,
                                line0: Int,
                                currentAuthorName: String?,
                                in view: ScintillaView) {
        let label = InlineBlameFormatter.label(for: blame,
                                               currentAuthorName: currentAuthorName)
        view.setStringProperty(Int32(SCI.EOLANNOTATIONSETTEXT),
                               parameter: line0,
                               value: label)
        view.message(SCI.EOLANNOTATIONSETSTYLE,
                     wParam: UInt(line0),
                     lParam: SC.STYLE_INLINE_BLAME)
    }

    // MARK: - Tooltip

    func showInlineBlameTooltipIfNeeded(in view: ScintillaView,
                                        position rawPosition: Int) {
        hideInlineBlameTooltip(in: view)
        guard NSApp.isActive, view.window?.isKeyWindow == true else { return }
        guard workspace?.isTextToolsPresented != true else { return }
        guard prefs.inlineBlameMode != .off else { return }
        guard let url = doc.url else { return }
        guard let engine = workspace?.gitBlameEngine else { return }

        let position = max(0, rawPosition)
        let line0 = view.message(SCI.LINEFROMPOSITION,
                                 wParam: UInt(position))
        if prefs.inlineBlameMode == .currentLine {
            let caret = view.message(SCI.GETCURRENTPOS)
            let caretLine0 = view.message(SCI.LINEFROMPOSITION,
                                          wParam: UInt(caret))
            guard line0 == caretLine0 else { return }
        }
        let lineNo = Int(line0) + 1
        guard let blame = engine.blameLine(for: url, line: lineNo),
              !blame.isUncommitted else { return }

        let tooltip = InlineBlameFormatter.tooltip(
            for: blame,
            currentAuthorName: engine.currentAuthorName(for: url)
        )
        inlineBlameTooltipView = InlineBlameTooltipPresenter.show(
            text: tooltip,
            position: position,
            line0: Int(line0),
            in: view,
            replacing: inlineBlameTooltipView
        )
    }

    func hideInlineBlameTooltip(in view: ScintillaView) {
        InlineBlameTooltipPresenter.hide(inlineBlameTooltipView, in: view)
        inlineBlameTooltipView = nil
    }

    // MARK: - Verification Hook

    func testInlineBlame(mode: InlineBlameMode,
                         caretLine: Int?,
                         tooltipLine: Int?,
                         in view: ScintillaView) {
        prefs.inlineBlameMode = mode
        if let caretLine {
            moveCaretToLine(caretLine, in: view)
        }
        applyInlineBlame(in: view)
        if let tooltipLine {
            let line0 = clampedLine0(tooltipLine, in: view)
            let position = Int(view.message(SCI.GETLINEENDPOSITION,
                                            wParam: UInt(line0)))
            showInlineBlameTooltipIfNeeded(in: view, position: position)
        }
    }

    private func moveCaretToLine(_ line1: Int, in view: ScintillaView) {
        let line0 = clampedLine0(line1, in: view)
        view.message(SCI.GOTOLINE, wParam: UInt(line0))
        let position = view.message(SCI.POSITIONFROMLINE,
                                    wParam: UInt(line0))
        view.message(SCI.SETSEL,
                     wParam: UInt(bitPattern: Int(position)),
                     lParam: Int(position))
        view.message(SCI.SCROLLCARET)
    }

    private func clampedLine0(_ line1: Int, in view: ScintillaView) -> Int {
        let lineCount = max(1, Int(view.message(SCI.GETLINECOUNT)))
        return min(max(0, line1 - 1), lineCount - 1)
    }
}
