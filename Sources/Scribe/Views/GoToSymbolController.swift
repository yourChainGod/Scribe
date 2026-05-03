//
//  GoToSymbolController.swift
//  Phase 65 — VSCode-style ⌘T "Go to Symbol in Workspace…".
//  Parallels QuickOpenController (⌘P) but the palette rows are
//  symbol entries pulled from every indexable file in the
//  workspace, not raw file paths.
//
//  The controller owns a dedicated CommandRegistry so the
//  PaletteWindowController can distinguish it from the ⌘P panel
//  via reference equality (same trick QuickOpenController uses).
//  Rows are rebuilt every time the palette opens so a fresh scan
//  of `WorkspaceSymbolIndex.symbols` lands in the fuzzy match
//  without relying on a Combine observer chain.
//
//  Lifecycle
//    1. Menu / shortcut / palette dispatches `toggle`.
//    2. Controller inspects the supplied `WorkspaceSymbolIndex`.
//       - If the index's `sourceRootURL` matches the current
//         `FileIndex.rootURL` AND the index isn't empty, reuse
//         the existing symbols.
//       - Otherwise kick off `rebuild(using:)` so the palette's
//         placeholder shows an "Indexing…" hint while the scan
//         runs. The list fills in once the index publishes.
//    3. Controller converts `symbols` → `[ScribeCommand]` and
//       hands it to PaletteWindowController.
//
//  Selection
//    Each row, on invoke, routes to `Workspace.openFile(at:line:)`
//    which handles "already open → re-select" vs. "load from
//    disk" transparently and funnels through `PendingScrollTarget`
//    to land the caret on the correct line.
//

import AppKit
import Combine
import Foundation

@MainActor
final class GoToSymbolController {
    static let shared = GoToSymbolController()

    /// Dedicated registry so PaletteWindowController treats this
    /// panel as distinct from QuickOpenController's ⌘P / the
    /// ⌘⇧P main command palette. Long-lived to keep identity
    /// stable across open/close cycles.
    private let registry = CommandRegistry()

    /// Combine sink that re-renders the palette rows whenever the
    /// `WorkspaceSymbolIndex` finishes a rebuild (`isIndexing`
    /// flips false). Cleared whenever the controller is idle so
    /// we don't keep a sink alive between palette invocations.
    private var indexingSink: AnyCancellable?

    // MARK: - Public surface

    /// Show the Go to Symbol palette. Builds / refreshes the
    /// workspace symbol index as needed.
    func show(workspace: Workspace,
              symbolIndex: WorkspaceSymbolIndex,
              fileIndex: FileIndex) {
        ensureFreshIndex(symbolIndex: symbolIndex, fileIndex: fileIndex)
        populateRegistry(workspace: workspace, symbolIndex: symbolIndex)
        subscribeForRefresh(workspace: workspace, symbolIndex: symbolIndex)
        PaletteWindowController.shared.show(
            registry: registry,
            placeholder: placeholder(for: symbolIndex)
        )
    }

    /// Menu-binding variant. Same contract as `show`, but respects
    /// PaletteWindowController's registry-equality rule so
    /// pressing ⌘T a second time dismisses the panel.
    func toggle(workspace: Workspace,
                symbolIndex: WorkspaceSymbolIndex,
                fileIndex: FileIndex) {
        ensureFreshIndex(symbolIndex: symbolIndex, fileIndex: fileIndex)
        populateRegistry(workspace: workspace, symbolIndex: symbolIndex)
        subscribeForRefresh(workspace: workspace, symbolIndex: symbolIndex)
        PaletteWindowController.shared.toggle(
            registry: registry,
            placeholder: placeholder(for: symbolIndex)
        )
    }

    // MARK: - Index management

    /// Decide whether a fresh scan is required. Rebuild when the
    /// workspace root has changed OR the catalogue is empty;
    /// otherwise trust the prior scan.
    private func ensureFreshIndex(symbolIndex: WorkspaceSymbolIndex,
                                  fileIndex: FileIndex) {
        let root = fileIndex.rootURL
        if symbolIndex.isIndexing { return }
        if symbolIndex.sourceRootURL == root && !symbolIndex.symbols.isEmpty {
            return
        }
        symbolIndex.rebuild(using: fileIndex)
    }

    private func subscribeForRefresh(workspace: Workspace,
                                     symbolIndex: WorkspaceSymbolIndex) {
        indexingSink?.cancel()
        indexingSink = symbolIndex.$isIndexing
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak workspace, weak symbolIndex] isIndexing in
                // Re-populate the registry after a rebuild finishes
                // so the palette list flips from "Indexing…" to the
                // real catalogue without requiring a re-open.
                guard isIndexing == false,
                      let self,
                      let workspace,
                      let symbolIndex else { return }
                self.populateRegistry(workspace: workspace,
                                      symbolIndex: symbolIndex)
            }
    }

    // MARK: - Row construction

    private func populateRegistry(workspace: Workspace,
                                  symbolIndex: WorkspaceSymbolIndex) {
        registry.commands = Self.makeCommands(symbols: symbolIndex.symbols,
                                              rootURL: symbolIndex.sourceRootURL,
                                              workspace: workspace)
    }

    /// Pure helper exposed to tests — builds the palette's command
    /// list from a snapshot without a live controller. Every row
    /// uses `workspace.openFile(at:line:)` on invoke.
    static func makeCommands(symbols: [WorkspaceSymbol],
                             rootURL: URL?,
                             workspace: Workspace) -> [ScribeCommand] {
        symbols.map { sym in
            ScribeCommand(
                id: sym.id,
                title: sym.name,
                subtitle: Self.makeSubtitle(for: sym, rootURL: rootURL),
                keywords: Self.makeKeywords(for: sym),
                perform: { [weak workspace] in
                    workspace?.openFile(at: sym.url, line: sym.line)
                }
            )
        }
    }

    /// Subtitle: "kind · path/relative/to/root:line". Relative path
    /// mirrors what Quick Open shows; users disambiguate symbols by
    /// the owning file more than by kind.
    static func makeSubtitle(for sym: WorkspaceSymbol,
                             rootURL: URL?) -> String {
        let path = relativePath(for: sym.url, rootURL: rootURL)
        let kind = localizedSymbolKindLabel(sym.kind)
        return Self.format("palette.symbol.workspace.detail",
                           kind,
                           path,
                           sym.line)
    }

    /// Keywords fed into the fuzzy match. We add:
    ///   - the kind label (so "class" narrows to class rows)
    ///   - the file basename (jump-by-file-then-symbol workflow)
    ///   - the path components (so typing the parent dir narrows)
    static func makeKeywords(for sym: WorkspaceSymbol) -> [String] {
        var out: [String] = []
        out.append(sym.kind.label)
        out.append(sym.url.lastPathComponent)
        out.append(contentsOf: sym.url.pathComponents.filter { $0 != "/" })
        return out
    }

    static func relativePath(for url: URL, rootURL: URL?) -> String {
        let std = url.standardizedFileURL.path
        if let root = rootURL?.standardizedFileURL.path,
           std.hasPrefix(root + "/") {
            return String(std.dropFirst(root.count + 1))
        }
        return std
    }

    // MARK: - Placeholder

    private func placeholder(for symbolIndex: WorkspaceSymbolIndex) -> String {
        Self.placeholder(isIndexing: symbolIndex.isIndexing,
                         truncated: symbolIndex.didTruncate,
                         symbolCount: symbolIndex.symbols.count,
                         rootURL: symbolIndex.sourceRootURL)
    }

    /// Pure helper exposed so tests can pin the placeholder text
    /// without a live WorkspaceSymbolIndex.
    static func placeholder(isIndexing: Bool,
                            truncated: Bool,
                            symbolCount: Int,
                            rootURL: URL?,
                            localize: (String) -> String = L10n.t) -> String {
        if isIndexing {
            return localize("palette.goToSymbol.placeholder.indexing")
        }
        guard let root = rootURL else {
            return localize("palette.goToSymbol.placeholder.noFolder")
        }
        let rootName = root.lastPathComponent
        if truncated {
            return Self.format("palette.goToSymbol.placeholder.truncated",
                               localize,
                               rootName,
                               symbolCount)
        }
        return Self.format("palette.goToSymbol.placeholder",
                           localize,
                           rootName,
                           symbolCount)
    }

    // MARK: - i18n

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
}
