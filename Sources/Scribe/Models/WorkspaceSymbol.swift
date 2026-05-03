//
//  WorkspaceSymbol.swift
//  Phase 65 — one row in the workspace-wide Go to Symbol palette.
//  Pairs a `SymbolEntry` with the file it came from so the palette
//  can open the right document + line when the user picks a row.
//
//  Unlike `SymbolEntry` (which is purely about the symbol's shape
//  within one document), `WorkspaceSymbol` carries the navigation
//  tuple the palette needs:
//    - the URL to open (dispatched through Workspace.openFile)
//    - the 1-based source line to land the caret on
//    - the kind (for the palette's icon / tint)
//    - a stable id so SwiftUI ForEach / fuzzy-match rendering
//      don't churn when the list re-sorts under a fresh query.
//

import Foundation

/// One entry in the workspace-wide Go to Symbol index. Pure value;
/// Sendable so the off-main indexer can hand a big array back to
/// the MainActor without Swift 6 strict-concurrency griping.
struct WorkspaceSymbol: Equatable, Hashable, Sendable, Identifiable {
    /// Stable-ish identity. Path + line + name is unique for any
    /// single-pass parse output we emit; two symbols on the same
    /// line with the same name are vanishingly rare (and at worst
    /// one collides in the palette, which is a pure cosmetic bug).
    let id: String

    /// User-visible name the palette's primary label renders.
    let name: String

    /// SF Symbol icon / tint / "method · line 42" subtitle all
    /// come from this enum.
    let kind: SymbolKind

    /// File that owns the symbol. Resolved via
    /// `Workspace.openFile(at:line:)` when the user picks a row.
    let url: URL

    /// 1-based source line.
    let line: Int

    /// Brace-depth the source parser recorded. The palette uses it
    /// as a tiebreaker when two entries fuzzy-match identically —
    /// shallower (top-level) symbols outrank deep ones because
    /// the caller usually means the outer decl.
    let depth: Int

    init(id: String,
         name: String,
         kind: SymbolKind,
         url: URL,
         line: Int,
         depth: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.line = line
        self.depth = depth
    }

    // MARK: - Convenience

    /// Canonical id format. Exposed so tests can assert the id shape
    /// without redefining it.
    static func makeID(url: URL, line: Int, name: String) -> String {
        "\(url.standardizedFileURL.path):\(line):\(name)"
    }
}
