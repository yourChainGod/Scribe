//
//  EditorViewportState.swift
//  Audit H1 — high-frequency caret + viewport signals, lifted out of
//  `Document`.
//
//  These five values are written by `ScintillaCodeEditor` on every
//  SCN_UPDATEUI (caret move) and V_SCROLL (scroll) tick — i.e. many
//  times per second during a drag-select or a scroll gesture. While
//  they lived on `Document` as `@Published`, every such tick fired
//  `Document.objectWillChange`, forcing the ~6 views that observe a
//  Document (tab row, sidebar row, status bar, editor, minimap,
//  preview) to re-evaluate their bodies even though `title` /
//  `isDirty` / `text` hadn't changed.
//
//  Mirrors the treatment `Workspace` already gives `activeSelection`
//  (deliberately kept off its published surface — see Workspace.swift).
//  Now only the views that actually read cursor / viewport — the
//  status-bar line:col label, the minimap viewport overlay, and the
//  editor↔preview scroll-sync plumbing — observe this object; the rest
//  no longer churn on caret movement or scrolling.
//
//  Lifecycle: one instance per `Document`, held as a plain `let`
//  (`Document.viewport`). It outlives nothing the Document doesn't, so
//  there's no retain-cycle or dangling-pointer concern.
//

import Foundation

@MainActor
final class EditorViewportState: ObservableObject {
    /// 1-based caret line. Written by ScintillaCodeEditor's
    /// SCN_UPDATEUI handler; read by the status bar (line:col),
    /// the outline's "you are here" highlight, and the markdown
    /// preview's caret-reveal path.
    @Published var cursorLine: Int = 1

    /// 1-based caret column. Status-bar only.
    @Published var cursorColumn: Int = 1

    /// 1-based source line at the top of the editor's visible
    /// viewport. Written by the V_SCROLL handler after every
    /// vertical scroll; read by MarkdownPreviewPane to drive the
    /// editor→preview scroll-sync, and by the Document Map's overlay.
    /// A dedicated signal (not `cursorLine`) keeps the caret-driven
    /// reveal independent of viewport drag gestures.
    @Published var viewportTopLine: Int = 1

    /// 1-based source line at the *bottom* of the editor's visible
    /// viewport (last fully or partially visible row). Published
    /// alongside `viewportTopLine` on every V_SCROLL tick; the
    /// Document Map's overlay reads both to size the translucent
    /// rectangle showing where the user is in the buffer.
    @Published var viewportBottomLine: Int = 1

    /// Reverse channel: 1-based source line at the top of the
    /// *preview's* viewport. Published by MarkdownPreviewPane's JS
    /// scroll handler (via WKScriptMessageHandler); observed by
    /// ScintillaCodeEditor to drive SCI_SETFIRSTVISIBLELINE so the
    /// editor follows when the user drags the preview scroll thumb.
    /// Kept distinct from `viewportTopLine` (editor→preview) so the
    /// two directions don't silently fight over a single variable.
    @Published var previewViewportTopLine: Int = 1
}
