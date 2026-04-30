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
        Self.filePlaceholder(isIndexing: fileIndex.isIndexing,
                             rootURL: fileIndex.rootURL)
    }

    static func filePlaceholder(isIndexing: Bool,
                                rootURL: URL?,
                                localize: (String) -> String = L10n.t) -> String {
        // Hint users about all three prefix modes from the very first
        // ⌘P press — discoverability for @symbol / :line / >command.
        let hint = localize("palette.placeholder.modeHint")
        if isIndexing {
            return Self.format("palette.placeholder.indexing", localize, hint)
        }
        if let root = rootURL {
            return Self.format("palette.placeholder.filesWithHint",
                               localize,
                               root.lastPathComponent,
                               hint)
        }
        return Self.format("palette.placeholder.openedFiles", localize, hint)
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
                                        isOpenDocument: true))
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
                                            isOpenDocument: false))
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
                ? Self.format("palette.symbol.empty", doc.title)
                : Self.format("palette.symbol.placeholder",
                              doc.title,
                              symbolRegistry.commands.count)
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
                            placeholder: Self.format("palette.gotoLine.placeholder", doc.title))
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
                            placeholder: Self.format("palette.commandRoute.placeholder",
                                                     palette.commands.count))
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
            let kindLabel = Self.localizedSymbolKindLabel(sym.kind)
            let subtitle = Self.format("palette.symbol.detail",
                                       kindLabel,
                                       sym.lineNumber)
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
    static func gotoLineCommands(stripped: String,
                                 doc: Document?,
                                 localize: (String) -> String = L10n.t) -> [ScribeCommand] {
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
                title: Self.format("palette.command.gotoLine", localize, line),
                subtitle: Self.format("palette.command.gotoLine.detail", localize, doc.title),
                keywords: ["line", "goto"],
                perform: { [weak doc] in
                    doc?.pendingScrollLine = line
                }
            )
        ]
    }

    struct QuickOpenCommandMetadata: Equatable {
        let id: String
        let title: String
        let subtitle: String
        let keywords: [String]
    }

    static func commandMetadata(for url: URL,
                                rootURL: URL?,
                                isOpenDocument: Bool) -> QuickOpenCommandMetadata {
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

        let subtitle = parentPath.isEmpty ? "—" : parentPath
        // Keywords let fuzzy match find files by their parent path even
        // when the user typed only the directory name.
        var keywords = parentPath.split(separator: "/").map(String.init)
        if isOpenDocument { keywords.append("open") }

        let role = isOpenDocument ? "open" : "file"
        return QuickOpenCommandMetadata(
            id: "quickopen.\(role):\(url.path)",
            title: url.lastPathComponent,
            subtitle: subtitle,
            keywords: keywords
        )
    }

    private static func localizedSymbolKindLabel(_ kind: SymbolKind) -> String {
        switch kind {
        case .function: return L10n.t("symbol.kind.function")
        case .method: return L10n.t("symbol.kind.method")
        case .classDecl: return L10n.t("symbol.kind.class")
        case .structDecl: return L10n.t("symbol.kind.struct")
        case .enumDecl: return L10n.t("symbol.kind.enum")
        case .protocolDecl: return L10n.t("symbol.kind.protocol")
        case .extensionDecl: return L10n.t("symbol.kind.extension")
        case .typealiasDecl: return L10n.t("symbol.kind.typealias")
        case .property: return L10n.t("symbol.kind.property")
        case .heading: return L10n.t("symbol.kind.heading")
        case .test: return L10n.t("symbol.kind.test")
        }
    }

    private static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: L10n.t(key), arguments: args)
    }

    private static func format(_ key: String,
                               _ localize: (String) -> String,
                               _ args: CVarArg...) -> String {
        String(format: localize(key), arguments: args)
    }

    private func makeCommand(for url: URL,
                             rootURL: URL?,
                             workspace: Workspace,
                             isOpenDocument: Bool) -> ScribeCommand {
        let metadata = Self.commandMetadata(for: url,
                                            rootURL: rootURL,
                                            isOpenDocument: isOpenDocument)

        return ScribeCommand(
            id: metadata.id,
            title: metadata.title,
            subtitle: metadata.subtitle,
            keywords: metadata.keywords,
            perform: { [weak workspace] in
                workspace?.openFile(at: url)
            }
        )
    }
}
