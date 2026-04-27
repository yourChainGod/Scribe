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
    /// active document at palette-open time. We attach it via a
    /// PrefixRoute on the main registry — the user types `@` and the
    /// same panel switches modes without a teardown.
    private let symbolRegistry = CommandRegistry()

    /// Optional weak ref to the host's main command registry. When the
    /// user types `>` inside ⌘P we fall through to it so they can
    /// invoke any palette command without first dismissing ⌘P and
    /// pressing ⌘⇧P. Set once on app startup; nil ⇒ the `>` route
    /// silently degrades to "no matches".
    private weak var commandPaletteRegistry: CommandRegistry?

    /// Wire the host's main palette registry. Idempotent.
    func bindCommandPalette(_ registry: CommandRegistry) {
        commandPaletteRegistry = registry
    }

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
        rebuildPrefixRoutes(workspace: workspace, outline: outline)
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
        rebuildPrefixRoutes(workspace: workspace, outline: outline)
        PaletteWindowController.shared.toggle(
            registry: registry,
            placeholder: filePlaceholder(fileIndex: fileIndex)
        )
    }

    private func filePlaceholder(fileIndex: FileIndex) -> String {
        // Hint users about all three prefix modes from the very first
        // ⌘P press — discoverability for @symbol / :line / >command.
        let hint = "@symbol  :line  >command"
        if fileIndex.isIndexing {
            return "Indexing… type to search opened files · \(hint)"
        }
        if let root = fileIndex.rootURL {
            return "Search files in \(root.lastPathComponent) · \(hint)"
        }
        return "Search opened files · \(hint)"
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

    /// Build all three prefix routes (@symbol / :line / >command) for
    /// the current document and attach them to the main registry. Run
    /// every time the palette opens so a stale outline (e.g. document
    /// just changed) doesn't surface yesterday's symbols.
    ///
    /// Symbol payload is a snapshot copy: the palette is short-lived
    /// (open → pick → dismiss), so subscribing live to `outline.symbols`
    /// would force every CommandPalette to add a second
    /// @ObservedObject for no perceptible benefit.
    private func rebuildPrefixRoutes(workspace: Workspace,
                                     outline: SymbolOutline) {
        let activeDoc = workspace.current
        rebuildSymbolRegistry(doc: activeDoc, outline: outline)

        var routes: [PrefixRoute] = []

        // 1. "@symbol" — static sub-registry seeded above.
        if let doc = activeDoc {
            let symPlaceholder = symbolRegistry.commands.isEmpty
                ? "No symbols in “\(doc.title)”"
                : "Jump to symbol in \(doc.title) (\(symbolRegistry.commands.count))"
            routes.append(
                PrefixRoute(id: "atSymbol",
                            prefix: "@",
                            registry: symbolRegistry,
                            placeholder: symPlaceholder)
            )
        }

        // 2. ":N" — dynamic, builds a single goto-line command from
        // the digits the user typed. We accept "N" or "N:M"; the
        // column is currently ignored (Scintilla's caret API only
        // needs the line for the visible-line scroll path we use).
        if let doc = activeDoc {
            routes.append(
                PrefixRoute(id: "gotoLine",
                            prefix: ":",
                            dynamicCommands: { [weak doc] stripped in
                                Self.gotoLineCommands(stripped: stripped,
                                                      doc: doc)
                            },
                            placeholder: "Go to line in \(doc.title) (e.g. :42)")
            )
        }

        // 3. ">command" — fall-through to the host's main command
        // palette so the user doesn't need to dismiss ⌘P and press
        // ⌘⇧P. Uses the same fuzzy search; placeholder makes the
        // mode obvious.
        if let palette = commandPaletteRegistry {
            routes.append(
                PrefixRoute(id: "commandPalette",
                            prefix: ">",
                            registry: palette,
                            placeholder: "Run a command (\(palette.commands.count) available)")
            )
        }

        registry.prefixRoutes = routes
    }

    private func rebuildSymbolRegistry(doc: Document?, outline: SymbolOutline) {
        guard let doc else {
            symbolRegistry.commands = []
            return
        }
        symbolRegistry.commands = outline.symbols.map { sym in
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
    }

    /// Parse `:42` / `:42:7` / `:` (empty) into a single goto-line
    /// command. Returns an empty list when the digits are missing or
    /// out-of-range — a hint Text in the result list would be nicer
    /// but the empty-state copy ("No matches for ':abc'") is good
    /// enough today.
    private static func gotoLineCommands(stripped: String,
                                         doc: Document?) -> [ScribeCommand] {
        guard let doc else { return [] }
        // Digits before the optional ":column" suffix.
        let firstSegment = stripped.split(separator: ":").first.map(String.init) ?? stripped
        let trimmed = firstSegment.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let line = Int(trimmed),
              line >= 1 else {
            return []
        }
        return [
            ScribeCommand(
                id: "gotoLine:\(doc.id):\(line)",
                title: "Go to line \(line)",
                subtitle: "in \(doc.title)",
                keywords: ["line", "goto"],
                perform: { [weak doc] in
                    doc?.pendingScrollLine = line
                }
            )
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
