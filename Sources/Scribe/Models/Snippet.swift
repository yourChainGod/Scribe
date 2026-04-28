//
//  Snippet.swift
//  Phase 33 — text-insert templates surfaced in the ⌘⇧T palette.
//
//  v1 scope:
//    - prefix → body text replacement, no placeholder navigation
//    - inserted at the current caret (or every caret when multi-cursor
//      is active, via `insertAtCarets` from Coordinator+MultiCursor)
//    - persisted as JSON in UserDefaults; managed in
//      Settings → Snippets tab + ⌘⇧T palette picker
//
//  Out of scope:
//    - `${1:placeholder}` field jumping (v2 — needs a SnippetSession
//      tracking carets across tab presses)
//    - Tab-key trigger from buffer text (v2 — Scintilla autocomplete)
//    - Per-language scoping (v2 — currently every snippet shows for
//      every document)
//

import Foundation

/// A single snippet entry. `Codable` for JSON round-trip into
/// UserDefaults; `Identifiable` so SwiftUI lists key on `id` rather
/// than a synthesised hash that would change when other fields edit.
struct Snippet: Codable, Identifiable, Equatable, Sendable {
    /// Stable identity — survives renaming `name` / editing `body`.
    var id: UUID
    /// Display name in the palette + Settings list.
    var name: String
    /// Short keyword for fuzzy-match in the palette ("todo", "table",
    /// …). Optional — empty string = match by `name` only.
    var prefix: String
    /// Text to insert at the caret. Multi-line OK.
    var body: String
    /// Optional one-line description. Surfaces as the palette
    /// subtitle and the Settings list secondary label.
    var description: String

    init(id: UUID = UUID(),
         name: String,
         prefix: String = "",
         body: String,
         description: String = "") {
        self.id = id
        self.name = name
        self.prefix = prefix
        self.body = body
        self.description = description
    }
}
