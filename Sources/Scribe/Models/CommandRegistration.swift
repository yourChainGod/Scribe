//
//  CommandRegistration.swift
//  Phase 3 — declarative seed of the Command Palette. Adding a new
//  palette command is a one-liner here; ScribeApp calls
//  `CommandRegistration.refresh` whenever the surface that drives
//  command availability changes (open documents, open folder, …).
//
//  The palette covers the hand-rolled actions; built-in editing actions
//  like Copy / Paste / Find / Undo are left to AppKit's responder chain
//  for now since the palette would need to forward events into
//  ScintillaView, which we'll wire when the editor surface stabilises.
//

import AppKit

@MainActor
enum CommandRegistration {
    /// Rebuild every command. Cheap (~30 entries); call after any change
    /// that affects command surface (open tabs, recent folders, etc.).
    static func refresh(registry: CommandRegistry,
                        workspace: Workspace,
                        prefs: EditorPreferences) {
        var batch: [ScribeCommand] = []
        batch.append(contentsOf: fileCommands(workspace: workspace, prefs: prefs))
        batch.append(contentsOf: viewCommands(workspace: workspace, prefs: prefs))
        batch.append(contentsOf: tabCommands(workspace: workspace))
        batch.append(contentsOf: encodingCommands(workspace: workspace))
        batch.append(contentsOf: lineEndingCommands(workspace: workspace))
        batch.append(contentsOf: lexerCommands(workspace: workspace))
        registry.commands = batch
    }

    // MARK: - File

    private static func fileCommands(workspace: Workspace,
                                     prefs: EditorPreferences) -> [ScribeCommand] {
        [
            .init(id: "file.new",
                  title: "New Tab",
                  subtitle: "File",
                  keywords: ["create", "tab", "untitled"]) {
                workspace.newDocument()
            },
            .init(id: "file.open",
                  title: "Open File…",
                  subtitle: "File",
                  keywords: ["read", "load"]) {
                workspace.openDocument()
            },
            .init(id: "file.openFolder",
                  title: "Open Folder…",
                  subtitle: "File",
                  keywords: ["workspace", "directory"]) {
                workspace.openFolder()
            },
            .init(id: "file.save",
                  title: "Save",
                  subtitle: "File",
                  keywords: ["write", "persist"]) {
                workspace.saveCurrent()
            },
            .init(id: "file.closeFolder",
                  title: "Close Workspace Folder",
                  subtitle: "File",
                  keywords: ["unload", "workspace"]) {
                workspace.closeFolder()
            },
            .init(id: "file.clearRecent",
                  title: "Clear Recent Files",
                  subtitle: "File",
                  keywords: ["history", "reset"]) {
                prefs.clearRecent()
            },
            .init(id: "file.clearRecentFolders",
                  title: "Clear Recent Folders",
                  subtitle: "File",
                  keywords: ["history", "reset"]) {
                prefs.clearRecentFolders()
            }
        ]
    }

    // MARK: - View / preferences

    private static func viewCommands(workspace: Workspace,
                                     prefs: EditorPreferences) -> [ScribeCommand] {
        [
            .init(id: "view.toggleSidebar",
                  title: "Toggle Sidebar",
                  subtitle: "View",
                  keywords: ["hide", "show", "panel"]) {
                workspace.sidebarVisible.toggle()
            },
            .init(id: "view.zoomIn",
                  title: "Zoom In",
                  subtitle: "View",
                  keywords: ["bigger", "increase", "font"]) {
                prefs.zoomIn()
            },
            .init(id: "view.zoomOut",
                  title: "Zoom Out",
                  subtitle: "View",
                  keywords: ["smaller", "decrease", "font"]) {
                prefs.zoomOut()
            },
            .init(id: "view.actualSize",
                  title: "Actual Size",
                  subtitle: "View",
                  keywords: ["reset", "default", "font"]) {
                prefs.resetFontSize()
            },
            .init(id: "view.toggleSoftTabs",
                  title: prefs.softTabs ? "Disable Soft Tabs" : "Enable Soft Tabs",
                  subtitle: "View",
                  keywords: ["tab", "spaces", "indent"]) {
                prefs.softTabs.toggle()
            }
        ]
    }

    // MARK: - Tabs

    private static func tabCommands(workspace: Workspace) -> [ScribeCommand] {
        workspace.documents.map { doc in
            ScribeCommand(
                id: "tab.\(doc.id.uuidString)",
                title: "Switch to \(doc.title)",
                subtitle: "Tab",
                keywords: ["jump", "select"]
            ) {
                workspace.selectedID = doc.id
            }
        }
    }

    // MARK: - Encoding / line ending / lexer

    private static func encodingCommands(workspace: Workspace) -> [ScribeCommand] {
        guard let doc = workspace.current else { return [] }
        var out: [ScribeCommand] = []
        if doc.url != nil {
            for enc in TextEncoding.allCases {
                out.append(ScribeCommand(
                    id: "enc.reopen.\(enc.rawValue)",
                    title: "Reopen with \(enc.displayName)",
                    subtitle: "Encoding",
                    keywords: ["charset", "decode"]
                ) { workspace.reopen(doc: doc, as: enc) })
            }
        }
        for enc in TextEncoding.allCases {
            out.append(ScribeCommand(
                id: "enc.save.\(enc.rawValue)",
                title: "Save as \(enc.displayName)",
                subtitle: "Encoding",
                keywords: ["charset", "encode"]
            ) { workspace.setEncoding(of: doc, to: enc) })
        }
        return out
    }

    private static func lineEndingCommands(workspace: Workspace) -> [ScribeCommand] {
        guard let doc = workspace.current else { return [] }
        return LineEnding.allCases.map { ending in
            ScribeCommand(
                id: "eol.\(ending.rawValue)",
                title: "Use \(ending.rawValue) Line Endings",
                subtitle: "Line Ending",
                keywords: ["crlf", "lf", "cr", "newline"]
            ) { workspace.setLineEnding(of: doc, to: ending) }
        }
    }

    private static func lexerCommands(workspace: Workspace) -> [ScribeCommand] {
        guard let doc = workspace.current else { return [] }
        return LexerCatalog.all.map { lex in
            ScribeCommand(
                id: "lexer.\(lex.lexillaName.isEmpty ? "plain" : lex.lexillaName)",
                title: "Set Language: \(lex.display)",
                subtitle: "Syntax",
                keywords: ["highlight", "lexer", "language"]
            ) { doc.lexerOverride = lex.lexillaName.isEmpty ? nil : lex.lexillaName }
        }
    }
}
