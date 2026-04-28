//
//  SnippetController.swift
//  Phase 33 — drives the ⌘⇧T snippet picker. Same shape as
//  QuickOpenController: a private `CommandRegistry` holds one
//  `ScribeCommand` per snippet so we can reuse the existing
//  fuzzy-match palette UI verbatim. Selecting a row dispatches the
//  snippet body through `findState.commands.send(.insertSnippet(_:))`,
//  which the editor's Coordinator turns into an `insertAtCarets`
//  call — picking up multi-cursor support for free.
//
//  Why not a brand-new SwiftUI view:
//    Phases 3 / 6 already polished the palette UX (fuzzy match,
//    keyboard nav, dismiss-on-resign-key, screen positioning).
//    Wrapping snippets as commands lets us inherit all of it
//    without duplicating ~250 LOC.
//

import AppKit
import Foundation

@MainActor
final class SnippetController {
    static let shared = SnippetController()

    /// Private registry rebuilt every time the palette opens so the
    /// snapshot reflects the current catalog state. Long-lived
    /// because PaletteWindowController identifies the active palette
    /// by reference equality on the registry instance.
    private let registry = CommandRegistry()

    /// Show the picker for the given catalog. `findState` is the
    /// command bus the Coordinator sink subscribes to — we go
    /// through it (instead of storing a Coordinator reference) so
    /// the editor stays the single owner of any "modify the active
    /// view" path. Empty catalog ⇒ palette opens with a single
    /// "manage snippets" hint command pointing at Settings.
    func show(catalog: SnippetCatalog, findState: FindState) {
        rebuild(catalog: catalog, findState: findState)
        PaletteWindowController.shared.show(
            registry: registry,
            placeholder: placeholder(for: catalog)
        )
    }

    /// Toggle for menu binding. Same registry-equality semantics as
    /// the command palette: re-press closes if already showing this
    /// registry, otherwise shows.
    func toggle(catalog: SnippetCatalog, findState: FindState) {
        rebuild(catalog: catalog, findState: findState)
        PaletteWindowController.shared.toggle(
            registry: registry,
            placeholder: placeholder(for: catalog)
        )
    }

    // MARK: - Internals

    private func rebuild(catalog: SnippetCatalog, findState: FindState) {
        // Capture findState weakly: SnippetController is a singleton
        // that outlives the SwiftUI scene, but findState is owned by
        // ScribeApp and shouldn't be retained by the registry's
        // command closures.
        let commands: [ScribeCommand] = catalog.snippets.map { snippet in
            // Subtitle prefers the snippet's description; falls back
            // to a one-line preview of the body so the row still
            // carries useful information for unlabelled entries.
            let subtitle: String
            if !snippet.description.isEmpty {
                subtitle = snippet.description
            } else {
                subtitle = previewBody(snippet.body)
            }
            // Keywords let fuzzy match find a snippet by its prefix
            // even when the user typed only the prefix string; the
            // body itself is *not* a keyword (typing in the user's
            // language shouldn't surface every TODO snippet).
            var keywords = [snippet.prefix].filter { !$0.isEmpty }
            keywords.append("snippet")
            return ScribeCommand(
                id: "snippet:\(snippet.id.uuidString)",
                title: snippet.name,
                subtitle: subtitle,
                keywords: keywords,
                perform: { [weak findState] in
                    findState?.commands.send(.insertSnippet(snippet.body))
                }
            )
        }
        registry.commands = commands
    }

    private func placeholder(for catalog: SnippetCatalog) -> String {
        if catalog.snippets.isEmpty {
            return L10n.t("snippet.palette.placeholder.empty")
        }
        let count = catalog.snippets.count
        return String(format: L10n.t("snippet.palette.placeholder"),
                      NSNumber(value: count))
    }

    /// Trim a multi-line body down to a single line of preview, with
    /// a "↵ N more" hint when more than one line exists. Keeps the
    /// palette row readable for snippets like a markdown table.
    private func previewBody(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.first.map(String.init) ?? ""
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        if lines.count <= 1 { return trimmed }
        return "\(trimmed) ↵ +\(lines.count - 1) more"
    }
}
