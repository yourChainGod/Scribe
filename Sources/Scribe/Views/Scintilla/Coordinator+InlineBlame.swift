//
//  Coordinator+InlineBlame.swift
//  Phase 35c-ii-γ — Scintilla EOL annotation integration for the
//  inline-blame chip. The data layer (GitClient.blame), the
//  formatter (RelativeTime), and the cache (GitBlameEngine) all
//  landed in earlier sub-phases; this extension is the bridge
//  between them and the Scintilla view: every caret tick + every
//  blame-cache update repaints a chip-shaped trailing label on
//  the active line.
//
//  Display rules:
//    - Active caret line carries
//          "  {Author}, {relative-time} • {sha7}"
//      Two leading spaces give a visual gap between the source
//      line's last character and the chip; zed uses three but
//      two read cleaner against Scintilla's caret highlight band.
//    - Other lines have no annotation. Painting every line
//      would crowd out the source code and re-rendering on
//      every scroll would cost O(visible-lines) per redraw.
//    - Lines without blame data (untracked / not in repo /
//      engine hasn't fetched yet / commit is the all-zeros
//      uncommitted sentinel) get no annotation. Inline blame
//      stays silent until git has something interesting to say.
//    - Multi-cursor: only the *main* caret's line carries the
//      chip; additional carets stay quiet. The main caret is
//      what `SCI_GETCURRENTPOS` returns, so this falls out for
//      free.
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

    /// Repaint the inline-blame chip on the active line. Cheap:
    /// clear all annotations, then set one line if we have a
    /// blame to show. Called on every SCN_UPDATEUI tick + every
    /// engine cache mutation, so it has to stay O(1).
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
        guard let url = doc.url else { return }
        guard let engine = workspace?.gitBlameEngine else { return }
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
        let label = formatBlameLabel(for: blame)
        // SCI_*SETTEXT messages take a const char * via lParam.
        // Scintilla cocoa exposes setStringProperty:parameter:value:
        // as the Swift-friendly wrapper that handles the NSString
        // → C string conversion + null termination.
        view.setStringProperty(Int32(SCI.EOLANNOTATIONSETTEXT),
                               parameter: Int(line0),
                               value: label)
        view.message(SCI.EOLANNOTATIONSETSTYLE,
                     wParam: UInt(line0),
                     lParam: SC.STYLE_INLINE_BLAME)
    }

    // MARK: - Format

    /// Build the chip text "  {Author}, {relTime} • {sha7}".
    ///
    /// - Two-space prefix: visual gap between source line and chip.
    /// - Author: the human's display name from `git blame`'s
    ///   `author` line.
    /// - Comma + relTime: "3 minutes ago" / "刚刚" via
    ///   `RelativeTime.describe`.
    /// - Bullet + 7-char SHA: enough to point at a commit
    ///   without consuming half the screen.
    ///
    /// Format matches zed's default layout. We deliberately do
    /// *not* include the commit summary here — a typical
    /// summary is 30–60 chars and would push the chip past
    /// the line wrap on narrow editors. 35c-ii's hover tooltip
    /// (TODO) is where the summary belongs.
    private func formatBlameLabel(for blame: GitClient.BlameLine) -> String {
        let sha7 = String(blame.sha.prefix(7))
        let time = RelativeTime.describe(epoch: blame.authorTime)
        return "  \(blame.author), \(time) • \(sha7)"
    }
}
