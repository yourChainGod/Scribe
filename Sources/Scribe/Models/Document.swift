//
//  Document.swift
//  Represents one tab — text content + metadata.
//

import Foundation
import SwiftUI

@MainActor
final class Document: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var text: String
    @Published var url: URL?
    @Published var encoding: TextEncoding = .utf8
    @Published var lineEnding: LineEnding = .lf
    @Published var isDirty: Bool = false
    @Published var cursorLine: Int = 1
    @Published var cursorColumn: Int = 1
    /// User-chosen Lexilla lexer name. When set, takes precedence over the
    /// extension-based detection in `LexerCatalog`. `nil` ⇒ auto.
    @Published var lexerOverride: String?
    /// 1-based line the editor should scroll/select on next presentation.
    /// Set by Workspace.openFile(at:line:) — read by ScintillaCodeEditor
    /// during makeNSView / updateNSView and cleared after consumption.
    @Published var pendingScrollLine: Int? = nil

    /// Phase 28b — `true` while Workspace is still reading + decoding
    /// the file's bytes off the main thread. The Scintilla wrapper
    /// shows a placeholder during that window so a 20 MB open doesn't
    /// freeze the UI for the half-second the synchronous
    /// `Data(contentsOf:)` used to take.
    @Published var isLoading: Bool = false

    /// Phase 28c — drain hook installed by ScintillaCodeEditor.Coordinator
    /// when it becomes the live editor. Throttled keystroke writes are
    /// the SCN_MODIFIED → doc.text sync; for multi-MB documents we'd
    /// otherwise pay an O(N) `view.string()` round-trip per character.
    /// Code paths that need a *current* `text` (Workspace.save,
    /// handleExternalChange) call this first to drain any pending
    /// throttled edit before reading. Optional because new / loading /
    /// closed documents have no live editor; reads against those see
    /// the most recent fully-synced value.
    @MainActor
    var flushPendingEdit: (() -> Void)?

    /// Phase 34c — large-file save hook installed by the editor's
    /// Coordinator on `attach(view:)`. Closures the live ScintillaView
    /// behind a Sendable façade so `Workspace.write` can drive a
    /// chunked save without poking at the view directly.
    ///   - parameter url: destination URL (passed straight through
    ///     to `ChunkedFileWriter.write(...)`).
    ///   - parameter progress: optional 0…1 callback invoked once per
    ///     written chunk. Workspace pumps it through to
    ///     `doc.saveProgress` so the status bar can render a bar.
    /// Throws `ChunkedFileWriterError` on failure; Workspace catches
    /// and turns it into an NSAlert.
    /// Optional: nil whenever no editor is currently attached
    /// (e.g. brand-new doc that's never been displayed).
    @MainActor
    var largeFileSaveHook: ((URL, (@MainActor (Double) -> Void)?) async throws -> Void)?

    /// Phase 30 — `true` when the user has opened the markdown
    /// preview pane for this tab (⌘⇧V or View menu). Per-document
    /// state rather than per-window because each tab can host a
    /// different file type and the toggle should follow the tab.
    /// EditorAreaView splits the canvas into editor | preview only
    /// when `isMarkdown && isMarkdownPreviewVisible`.
    @Published var isMarkdownPreviewVisible: Bool = false

    /// Phase 31 — git gutter status, keyed by 1-based line number.
    /// Populated by `GitGutterEngine` whenever the doc switches in,
    /// the file is saved, or an external change fires. Empty
    /// dictionary = "no changes vs HEAD" or "file isn't in a git
    /// repo / isn't tracked"; the editor margin draws nothing in
    /// either case. ScintillaCodeEditor.Coordinator observes this
    /// via `@ObservedObject` and re-applies the markers in
    /// `updateNSView` only when the dict actually changed.
    @Published var gitGutter: [Int: GitGutterStatus] = [:]

    /// Phase 34b — `true` when this document was opened via the
    /// chunked large-file path (file size >= LargeFilePolicy.threshold-
    /// Bytes). Workspace sets it before async open kicks off; the
    /// editor's Coordinator reads it to decide whether to drive its
    /// own ILoader pipeline (chunked → SCI_SETDOCPOINTER) instead of
    /// the standard `applyText(doc.text)` push.
    /// Implication: `text` stays empty for the lifetime of the
    /// document — Find / Markdown preview / git gutter that read
    /// `text` will see no content; Phase 34c is what teaches them to
    /// read straight from the Scintilla buffer instead.
    @Published var isLargeFile: Bool = false

    /// Phase 34b — 0…1 chunked-load progress for the large-file
    /// path. -1 means "not loading"; the editor Coordinator and the
    /// status bar both read this — the bar surfaces a percentage,
    /// the Coordinator uses `>= 1` as the "load is done, repaint
    /// once" signal.
    @Published var loadProgress: Double = -1

    /// Phase 34c — 0…1 chunked-save progress for the large-file
    /// path. -1 means "not saving". Workspace flips it to 0 before
    /// kicking off the streaming write; ChunkedFileWriter's
    /// per-chunk callback nudges it forward; on completion or
    /// failure it returns to -1. Save UI (status bar banner, save
    /// menu disabled state) drives off this single source of truth
    /// rather than juggling its own bool.
    @Published var saveProgress: Double = -1

    /// Phase 46b — user-pinned tab. Pinned tabs float to the front of
    /// the strip, show a pin glyph instead of the language icon, and
    /// survive across launches (keyed by URL path in
    /// `EditorPreferences.pinnedFilePaths`). Untitled documents can
    /// still toggle the flag but it doesn't persist — there's no
    /// stable key to write under. Closing a pinned tab is allowed
    /// (no confirmation); re-opening the same URL re-applies the
    /// pin via the Workspace.openFile recovery path.
    @Published var isPinned: Bool = false

    /// Phase 49b — last time this tab became the active selection.
    /// `Workspace.selectedID.didSet` stamps `Date()` here whenever the
    /// user actually switches to the tab; Quick Open (⌘P) sorts open
    /// documents by this so the most-recently-touched files float to
    /// the top of the list, mirroring VS Code's MRU. Not @Published
    /// because no SwiftUI surface needs to react to the value — it's
    /// purely an ordering key consumed by `QuickOpenController`.
    /// Defaults to `.distantPast` so a brand-new Document that has
    /// never been activated sorts after every doc that has.
    var lastActivatedAt: Date = .distantPast

    init(title: String = L10n.t("tab.untitled"), text: String = "", url: URL? = nil) {
        self.title = title
        self.text = text
        self.url = url
    }

    var displayTitle: String {
        (isDirty ? "● " : "") + title
    }

    var languageGuess: String {
        guard let url else { return "txt" }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "txt" : ext
    }

    /// Phase 30 — used by EditorAreaView to decide whether the
    /// markdown preview toggle is meaningful for this doc. We
    /// match Outline's set ("md" / "markdown") so a user who
    /// renames a file gets the preview enabled / disabled
    /// consistently with the Outline sidebar's heading parser.
    var isMarkdown: Bool {
        switch languageGuess {
        case "md", "markdown": true
        default:               false
        }
    }
}
