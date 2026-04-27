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

    /// Show the Quick Open panel against the current FileIndex.
    /// Open files first (MRU order from Workspace.documents) → indexed
    /// files alphabetically. Empty workspace ⇒ shows just the open tabs.
    func show(workspace: Workspace, fileIndex: FileIndex) {
        rebuild(workspace: workspace, fileIndex: fileIndex)
        let placeholder = fileIndex.isIndexing
            ? "Indexing… type to search opened files"
            : (fileIndex.rootURL == nil
                ? "Search opened files…"
                : "Search files in \(fileIndex.rootURL!.lastPathComponent)…")
        PaletteWindowController.shared.show(registry: registry,
                                            placeholder: placeholder)
    }

    /// Toggle for menu binding. Same registry-equality semantics as
    /// the command palette.
    func toggle(workspace: Workspace, fileIndex: FileIndex) {
        rebuild(workspace: workspace, fileIndex: fileIndex)
        let placeholder = fileIndex.isIndexing
            ? "Indexing… type to search opened files"
            : (fileIndex.rootURL == nil
                ? "Search opened files…"
                : "Search files in \(fileIndex.rootURL!.lastPathComponent)…")
        PaletteWindowController.shared.toggle(registry: registry,
                                              placeholder: placeholder)
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
