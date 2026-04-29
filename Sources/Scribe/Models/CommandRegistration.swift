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
                        prefs: EditorPreferences,
                        findState: FindState? = nil,
                        localize: (String) -> String = L10n.t) {
        var batch: [ScribeCommand] = []
        batch.append(contentsOf: fileCommands(workspace: workspace, prefs: prefs, localize: localize))
        batch.append(contentsOf: viewCommands(workspace: workspace, prefs: prefs, localize: localize))
        batch.append(contentsOf: textCommands(workspace: workspace, findState: findState, localize: localize))
        batch.append(contentsOf: tabCommands(workspace: workspace, localize: localize))
        batch.append(contentsOf: encodingCommands(workspace: workspace, localize: localize))
        batch.append(contentsOf: lineEndingCommands(workspace: workspace, localize: localize))
        batch.append(contentsOf: lexerCommands(workspace: workspace, localize: localize))
        registry.commands = batch
    }

    // MARK: - File

    private static func fileCommands(workspace: Workspace,
                                     prefs: EditorPreferences,
                                     localize: (String) -> String) -> [ScribeCommand] {
        [
            .init(id: "file.new",
                  title: localize("palette.command.newTab"),
                  subtitle: localize("menu.file"),
                  keywords: ["new", "create", "tab", "untitled", "file"]) {
                workspace.newDocument()
            },
            .init(id: "file.open",
                  title: localize("palette.command.openFile"),
                  subtitle: localize("menu.file"),
                  keywords: ["open", "file", "read", "load"]) {
                workspace.openDocument()
            },
            .init(id: "file.openFolder",
                  title: localize("menu.file.openFolder"),
                  subtitle: localize("menu.file"),
                  keywords: ["open", "folder", "workspace", "directory"]) {
                workspace.openFolder()
            },
            .init(id: "file.save",
                  title: localize("menu.file.save"),
                  subtitle: localize("menu.file"),
                  keywords: ["save", "file", "write", "persist"]) {
                workspace.saveCurrent()
            },
            .init(id: "file.closeFolder",
                  title: localize("palette.command.closeWorkspaceFolder"),
                  subtitle: localize("menu.file"),
                  keywords: ["close", "folder", "unload", "workspace"]) {
                workspace.closeFolder()
            },
            .init(id: "file.clearRecent",
                  title: localize("palette.command.clearRecentFiles"),
                  subtitle: localize("menu.file"),
                  keywords: ["clear", "recent", "files", "history", "reset"]) {
                prefs.clearRecent()
            },
            .init(id: "file.clearRecentFolders",
                  title: localize("palette.command.clearRecentFolders"),
                  subtitle: localize("menu.file"),
                  keywords: ["clear", "recent", "folders", "history", "reset"]) {
                prefs.clearRecentFolders()
            }
        ]
    }

    // MARK: - View / preferences

    private static func viewCommands(workspace: Workspace,
                                     prefs: EditorPreferences,
                                     localize: (String) -> String) -> [ScribeCommand] {
        var commands: [ScribeCommand] = [
            .init(id: "view.toggleSidebar",
                  title: localize("menu.view.toggleSidebar"),
                  subtitle: localize("menu.view"),
                  keywords: ["toggle", "sidebar", "hide", "show", "panel", "view"]) {
                workspace.sidebarVisible.toggle()
            },
            .init(id: "view.zoomIn",
                  title: localize("menu.view.zoomIn"),
                  subtitle: localize("menu.view"),
                  keywords: ["zoom", "in", "bigger", "increase", "font", "view"]) {
                prefs.zoomIn()
            },
            .init(id: "view.zoomOut",
                  title: localize("menu.view.zoomOut"),
                  subtitle: localize("menu.view"),
                  keywords: ["zoom", "out", "smaller", "decrease", "font", "view"]) {
                prefs.zoomOut()
            },
            .init(id: "view.actualSize",
                  title: localize("palette.command.actualSize"),
                  subtitle: localize("menu.view"),
                  keywords: ["actual", "size", "reset", "default", "font", "view"]) {
                prefs.resetFontSize()
            },
            .init(id: "view.toggleSoftTabs",
                  title: prefs.softTabs
                    ? localize("palette.command.disableSoftTabs")
                    : localize("palette.command.enableSoftTabs"),
                  subtitle: localize("menu.view"),
                  keywords: ["soft", "tabs", "tab", "spaces", "indent", "view"]) {
                prefs.softTabs.toggle()
            }
        ]

        if workspace.current != nil {
            commands.append(
                .init(id: "view.markdownPreview",
                      title: localize("menu.view.markdownPreview"),
                      subtitle: localize("menu.view"),
                      keywords: ["markdown", "preview", "render", "split", "html", "view"]) {
                    workspace.toggleMarkdownPreview()
                }
            )
        }

        return commands
    }

    // MARK: - Text operations

    private static func textCommands(workspace: Workspace,
                                     findState: FindState?,
                                     localize: (String) -> String) -> [ScribeCommand] {
        guard workspace.current != nil, let findState else { return [] }
        var commands: [ScribeCommand] = [
            ScribeCommand(id: "text.openTools",
                          title: localize("palette.command.text.openTools"),
                          subtitle: localize("palette.badge.text"),
                          keywords: ["text tools", "text", "tools", "split", "merge", "columns", "workbench"]) {
                workspace.textToolsMode = .columns
                workspace.isTextToolsPresented = true
            },
            ScribeCommand(id: "text.openTransformTools",
                          title: localize("palette.command.text.openTransformTools"),
                          subtitle: localize("palette.badge.text"),
                          keywords: ["text tools", "text", "transform", "workbench", "encode", "decode", "base", "conversion"]) {
                workspace.textToolsMode = .transform
                workspace.isTextToolsPresented = true
            }
        ]
        let specs: [(id: String, titleKey: String, action: TextTransformAction, keywords: [String])] = [
            ("text.urlEncode", "palette.command.text.urlEncode", .urlEncode,
             ["text", "transform", "url", "percent", "encode"]),
            ("text.urlDecode", "palette.command.text.urlDecode", .urlDecode,
             ["text", "transform", "url", "percent", "decode"]),
            ("text.base64Encode", "palette.command.text.base64Encode", .base64Encode,
             ["text", "transform", "base64", "encode"]),
            ("text.base64Decode", "palette.command.text.base64Decode", .base64Decode,
             ["text", "transform", "base64", "decode"]),
            ("text.htmlEscape", "palette.command.text.htmlEscape", .htmlEscape,
             ["text", "transform", "html", "escape", "encode"]),
            ("text.htmlUnescape", "palette.command.text.htmlUnescape", .htmlUnescape,
             ["text", "transform", "html", "unescape", "decode"]),
            ("text.jsonEscape", "palette.command.text.jsonEscape", .jsonStringEscape,
             ["text", "transform", "json", "string", "escape", "encode"]),
            ("text.jsonUnescape", "palette.command.text.jsonUnescape", .jsonStringUnescape,
             ["text", "transform", "json", "string", "unescape", "decode"]),
            ("text.binaryToDecimal", "palette.command.text.binaryToDecimal", .convertBase(fromBase: 2, toBase: 10),
             ["text", "transform", "binary", "decimal", "base", "convert"]),
            ("text.decimalToBinary", "palette.command.text.decimalToBinary", .convertBase(fromBase: 10, toBase: 2),
             ["text", "transform", "decimal", "binary", "base", "convert"]),
            ("text.octalToDecimal", "palette.command.text.octalToDecimal", .convertBase(fromBase: 8, toBase: 10),
             ["text", "transform", "octal", "decimal", "base", "convert"]),
            ("text.decimalToOctal", "palette.command.text.decimalToOctal", .convertBase(fromBase: 10, toBase: 8),
             ["text", "transform", "decimal", "octal", "base", "convert"]),
            ("text.hexToDecimal", "palette.command.text.hexToDecimal", .convertBase(fromBase: 16, toBase: 10),
             ["text", "transform", "hex", "decimal", "base", "convert"]),
            ("text.decimalToHex", "palette.command.text.decimalToHex", .convertBase(fromBase: 10, toBase: 16),
             ["text", "transform", "decimal", "hex", "base", "convert"])
        ]

        commands.append(contentsOf: specs.map { spec in
            ScribeCommand(id: spec.id,
                          title: localize(spec.titleKey),
                          subtitle: localize("palette.badge.text"),
                          keywords: spec.keywords) {
                findState.commands.send(.transformSelection(spec.action))
            }
        })
        commands.append(
            ScribeCommand(id: "text.shuffleLines",
                          title: localize("palette.command.text.shuffleLines"),
                          subtitle: localize("palette.badge.text"),
                          keywords: ["text", "transform", "shuffle", "random", "lines", "row", "rows"]) {
                findState.commands.send(.transformSelection(.shuffleLines(seed: UInt64.random(in: UInt64.min...UInt64.max))))
            }
        )
        return commands
    }

    // MARK: - Tabs

    private static func tabCommands(workspace: Workspace,
                                    localize: (String) -> String) -> [ScribeCommand] {
        workspace.documents.map { doc in
            ScribeCommand(
                id: "tab.\(doc.id.uuidString)",
                title: format("palette.command.switchTo", localize, doc.title),
                subtitle: localize("palette.badge.tab"),
                keywords: ["switch", "tab", "jump", "select"]
            ) {
                workspace.selectedID = doc.id
            }
        }
    }

    // MARK: - Encoding / line ending / lexer

    private static func encodingCommands(workspace: Workspace,
                                         localize: (String) -> String) -> [ScribeCommand] {
        guard let doc = workspace.current else { return [] }
        var out: [ScribeCommand] = []
        if doc.url != nil {
            for enc in TextEncoding.allCases {
                out.append(ScribeCommand(
                    id: "enc.reopen.\(enc.rawValue)",
                    title: format("palette.command.reopenWith", localize, enc.displayName),
                    subtitle: localize("palette.badge.encoding"),
                    keywords: ["encoding", "enc", "charset", "decode", "reopen"]
                ) { workspace.reopen(doc: doc, as: enc) })
            }
        }
        for enc in TextEncoding.allCases {
            out.append(ScribeCommand(
                id: "enc.save.\(enc.rawValue)",
                title: format("palette.command.saveAsEncoding", localize, enc.displayName),
                subtitle: localize("palette.badge.encoding"),
                keywords: ["encoding", "enc", "charset", "encode", "save"]
            ) { workspace.setEncoding(of: doc, to: enc) })
        }
        return out
    }

    private static func lineEndingCommands(workspace: Workspace,
                                           localize: (String) -> String) -> [ScribeCommand] {
        guard let doc = workspace.current else { return [] }
        return LineEnding.allCases.map { ending in
            ScribeCommand(
                id: "eol.\(ending.rawValue)",
                title: format("palette.command.useLineEndings", localize, ending.rawValue),
                subtitle: localize("palette.badge.lineEnding"),
                keywords: ["line", "ending", "line ending", "crlf", "lf", "cr", "newline"]
            ) { workspace.setLineEnding(of: doc, to: ending) }
        }
    }

    private static func lexerCommands(workspace: Workspace,
                                      localize: (String) -> String) -> [ScribeCommand] {
        guard let doc = workspace.current else { return [] }
        return LexerCatalog.all.map { lex in
            ScribeCommand(
                id: "lexer.\(lex.lexillaName.isEmpty ? "plain" : lex.lexillaName)",
                title: format("palette.command.setLanguage", localize, lex.display),
                subtitle: localize("palette.badge.syntax"),
                keywords: ["syntax", "highlight", "lexer", "language"]
            ) { doc.lexerOverride = lex.lexillaName.isEmpty ? nil : lex.lexillaName }
        }
    }

    private static func format(_ key: String,
                               _ localize: (String) -> String,
                               _ args: CVarArg...) -> String {
        String(format: localize(key), arguments: args)
    }
}
