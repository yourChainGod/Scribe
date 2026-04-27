//
//  QuickOpenController.swift
//  Phase 6 — VSCode-style ⌘P "Quick Open File". Reuses the floating
//  palette panel + fuzzy CommandRegistry from Phase 3, but the commands
//  it registers are file-open actions sourced from FileIndex.
//
//  We keep a private CommandRegistry instance dedicated to file
//  commands so it can coexist with the global ⌘⇧P registry without
//  polluting the action list there.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
final class QuickOpenController {
    static let shared = QuickOpenController()

    /// File-open commands, recomputed each time the palette opens so
    /// the snapshot reflects the current FileIndex state. Kept as a
    /// long-lived object because PaletteWindowController identifies the
    /// active palette via reference equality on the registry.
    private let registry = CommandRegistry()

    /// Sub-registry that owns "@symbol" commands while ⌘P is showing.
    /// Re-populated every time show()/toggle() runs so it reflects the
    /// active document's symbols at palette-open time. We attach it
    /// via a PrefixRoute on the main registry — the user types `@` and
    /// the same panel switches modes without a teardown.
    private let symbolRegistry = CommandRegistry()

    /// Show the Quick Open panel against the current FileIndex.
    /// Open files first (MRU order from Workspace.documents) → indexed
    /// files alphabetically. Empty workspace ⇒ shows just the open tabs.
    /// Typing `@` switches the palette to symbol-jump mode against the
    /// active document's outline.
    func show(workspace: Workspace,
              fileIndex: FileIndex,
              outline: SymbolOutline,
              initialQuery: String = "") {
        rebuild(workspace: workspace, fileIndex: fileIndex)
        rebuildSymbols(workspace: workspace, outline: outline)
        PaletteWindowController.shared.show(
            registry: registry,
            placeholder: filePlaceholder(fileIndex: fileIndex),
            initialQuery: initialQuery
        )
    }

    /// Toggle for menu binding. Same registry-equality semantics as
    /// the command palette.
    func toggle(workspace: Workspace,
                fileIndex: FileIndex,
                outline: SymbolOutline) {
        rebuild(workspace: workspace, fileIndex: fileIndex)
        rebuildSymbols(workspace: workspace, outline: outline)
        PaletteWindowController.shared.toggle(
            registry: registry,
            placeholder: filePlaceholder(fileIndex: fileIndex)
        )
    }

    private func filePlaceholder(fileIndex: FileIndex) -> String {
        if fileIndex.isIndexing {
            return "Indexing… type to search opened files (or @ to jump to a symbol)"
        }
        if let root = fileIndex.rootURL {
            return "Search files in \(root.lastPathComponent) — type @ to jump to a symbol"
        }
        return "Search opened files — type @ to jump to a symbol"
    }

    // MARK: - Command construction

    private func rebuild(workspace: Workspace, fileIndex: FileIndex) {
        var commands: [ScribeCommand] = []

        // Already-open documents first; these are the most likely
        // re-targets and shouldn't disappear into a 50k-entry list.
        let openURLs = Set(workspace.documents.compactMap { $0.url?.standardizedFileURL })
        for doc in workspace.documents {
            guard let url = doc.url?.standardizedFileURL else { continue }
            commands.append(makeCommand(for: url,
                                        rootURL: fileIndex.rootURL,
                                        workspace: workspace,
                                        prefix: "● "))
        }

        // Then indexed files, minus the ones already in `openURLs`.
        // FileIndex caps at 200k; cmdrebuild is microsecond-cheap per
        // entry, so we don't paginate here.
        if let root = fileIndex.rootURL {
            for url in fileIndex.files {
                let std = url.standardizedFileURL
                if openURLs.contains(std) { continue }
                commands.append(makeCommand(for: std,
                                            rootURL: root,
                                            workspace: workspace,
                                            prefix: ""))
            }
        }
        registry.commands = commands
    }

    /// Snapshot the active document's symbols into `symbolRegistry`
    /// and attach it as a "@" prefix route on the main registry. Run
    /// every time the palette opens so a stale outline (e.g. document
    /// just changed) doesn't surface yesterday's symbols.
    ///
    /// We deliberately copy the symbols at palette-open time rather
    /// than subscribe to `outline.symbols`: the palette is short-lived
    /// (open → pick → dismiss) and the alternative would require a
    /// second @ObservedObject in CommandPalette for a feature that
    /// doesn't benefit from live updates.
    private func rebuildSymbols(workspace: Workspace,
                                outline: SymbolOutline) {
        guard let doc = workspace.current else {
            symbolRegistry.commands = []
            registry.prefixRoutes = []
            return
        }
        let commands: [ScribeCommand] = outline.symbols.map { sym in
            // Subtitle = "<kind> · line <n>" so the row carries enough
            // context to disambiguate two functions called `helper` in
            // the same file.
            let subtitle = "\(sym.kind.label) · line \(sym.lineNumber)"
            return ScribeCommand(
                id: "symbol:\(doc.id):\(sym.id)",
                title: sym.name,
                subtitle: subtitle,
                keywords: [sym.kind.label],
                perform: { [weak doc] in
                    doc?.pendingScrollLine = sym.lineNumber
                }
            )
        }
        symbolRegistry.commands = commands

        let placeholder = commands.isEmpty
            ? "No symbols in “\(doc.title)”"
            : "Jump to symbol in \(doc.title) (\(commands.count))"
        registry.prefixRoutes = [
            PrefixRoute(id: "atSymbol",
                        prefix: "@",
                        registry: symbolRegistry,
                        placeholder: placeholder)
        ]
    }

    private func makeCommand(for url: URL,
                             rootURL: URL?,
                             workspace: Workspace,
                             prefix: String) -> ScribeCommand {
        // Subtitle = path relative to workspace root if possible;
        // otherwise the absolute parent path. Quick Open users mostly
        // disambiguate by directory, not basename.
        let parentPath: String
        if let root = rootURL {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            parentPath = (rel as NSString).deletingLastPathComponent
        } else {
            parentPath = (url.path as NSString).deletingLastPathComponent
        }

        let title = prefix + url.lastPathComponent
        let subtitle = parentPath.isEmpty ? "—" : parentPath
        // Keywords let fuzzy match find files by their parent path even
        // when the user typed only the directory name.
        let keywords = parentPath.split(separator: "/").map(String.init)

        return ScribeCommand(
            id: "quickopen:\(url.path)",
            title: title,
            subtitle: subtitle,
            keywords: keywords,
            perform: { [weak workspace] in
                workspace?.openFile(at: url)
            }
        )
    }
}
