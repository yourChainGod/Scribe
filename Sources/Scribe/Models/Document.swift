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
}
