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
        batch.append(contentsOf: textCommands(workspace: workspace, findState: findState, prefs: prefs, localize: localize))
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
            },
            // Phase 41f — toggle inline color swatches. Title flips
            // with the current setting so the palette match always
            // reads as the verb the user expects.
            .init(id: "view.toggleColorSwatches",
                  title: prefs.inlineColorSwatchesEnabled
                    ? localize("palette.command.colorSwatch.hide")
                    : localize("palette.command.colorSwatch.show"),
                  subtitle: localize("menu.view"),
                  keywords: ["color", "swatch", "hex", "rgb", "hsl",
                             "preview", "highlight", "颜色", "色块"]) {
                prefs.inlineColorSwatchesEnabled.toggle()
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
                                     prefs: EditorPreferences,
                                     localize: (String) -> String) -> [ScribeCommand] {
        guard workspace.current != nil, let findState else { return [] }
        var commands: [ScribeCommand] = [
            ScribeCommand(id: "text.openTools",
                          title: localize("palette.command.text.openTools"),
                          subtitle: localize("palette.badge.text"),
                          keywords: ["text tools", "text", "tools", "split", "merge", "columns", "workbench"]) {
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
             ["text", "transform", "decimal", "hex", "base", "convert"]),
            // Phase 41a — Hash digests. English keywords listed
            // alongside the algorithm so the palette finds them on
            // either side of a Chinese / English locale flip.
            ("text.hash.md5", "palette.command.text.hash.md5", .md5,
             ["text", "transform", "hash", "md5", "checksum", "digest"]),
            ("text.hash.sha1", "palette.command.text.hash.sha1", .sha1,
             ["text", "transform", "hash", "sha", "sha1", "sha-1", "checksum", "digest"]),
            ("text.hash.sha256", "palette.command.text.hash.sha256", .sha256,
             ["text", "transform", "hash", "sha", "sha256", "sha-256", "checksum", "digest"]),
            ("text.hash.sha512", "palette.command.text.hash.sha512", .sha512,
             ["text", "transform", "hash", "sha", "sha512", "sha-512", "checksum", "digest"]),
            ("text.hash.crc32", "palette.command.text.hash.crc32", .crc32,
             ["text", "transform", "hash", "crc", "crc32", "checksum", "zlib"])
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
        // Phase 41a — JWT decoder palette entry. Pre-fills with
        // the live selection (empty string ⇒ blank panel; the
        // sheet's text editor lets the user paste).
        commands.append(
            ScribeCommand(id: "text.decodeJWT",
                          title: localize("palette.command.text.decodeJWT"),
                          subtitle: localize("palette.badge.text"),
                          keywords: ["text", "transform", "jwt", "json", "web", "token", "decode", "claims"]) {
                workspace.jwtSheet = JWTSheetRequest(prefill: workspace.activeTextSelection)
            }
        )
        // Phase 41d — Line Ops palette entries. The IDs and
        // keywords mirror the Tools ▶ Line Ops menu so the
        // palette finds them via either English or Chinese
        // mnemonic on `Cmd+Shift+P`.
        let lineOpSpecs: [(id: String,
                           titleKey: String,
                           action: TextTransformAction,
                           keywords: [String])] = [
            ("text.lines.dedupe", "palette.command.lines.dedupe", .dedupeLines,
             ["lines", "dedupe", "deduplicate", "unique", "去重"]),
            ("text.lines.dropBlank", "palette.command.lines.dropBlank", .dropBlankLines,
             ["lines", "blank", "empty", "drop", "去空行"]),
            ("text.lines.reverse", "palette.command.lines.reverse", .reverseLines,
             ["lines", "reverse", "flip", "反转"]),
            ("text.lines.trim", "palette.command.lines.trim", .trimTrailing,
             ["lines", "trim", "trailing", "whitespace", "去尾空格"]),
            ("text.lines.tabsToSpaces", "palette.command.lines.tabsToSpaces",
             .tabsToSpaces(width: prefs.tabWidth),
             ["lines", "tabs", "spaces", "indent"]),
            ("text.lines.spacesToTabs", "palette.command.lines.spacesToTabs",
             .spacesToTabs(width: prefs.tabWidth),
             ["lines", "spaces", "tabs", "indent"]),
            ("text.lines.sortLex", "palette.command.lines.sort.lex",
             .sortLines(mode: .lexicographic, descending: false),
             ["lines", "sort", "lexicographic", "asc", "排序"]),
            ("text.lines.sortLexDesc", "palette.command.lines.sort.lex.desc",
             .sortLines(mode: .lexicographic, descending: true),
             ["lines", "sort", "lexicographic", "desc", "倒序"]),
            ("text.lines.sortIcase", "palette.command.lines.sort.icase",
             .sortLines(mode: .caseInsensitive, descending: false),
             ["lines", "sort", "case", "insensitive"]),
            ("text.lines.sortNatural", "palette.command.lines.sort.natural",
             .sortLines(mode: .natural, descending: false),
             ["lines", "sort", "natural", "version"]),
            ("text.lines.sortNumeric", "palette.command.lines.sort.numeric",
             .sortLines(mode: .numeric, descending: false),
             ["lines", "sort", "numeric"]),
            ("text.lines.sortLength", "palette.command.lines.sort.length",
             .sortLines(mode: .length, descending: false),
             ["lines", "sort", "length"]),
            ("text.case.lower", "palette.command.case.lower", .caseTransform(mode: .lower),
             ["case", "lower", "lowercase", "小写"]),
            ("text.case.upper", "palette.command.case.upper", .caseTransform(mode: .upper),
             ["case", "upper", "uppercase", "大写"]),
            ("text.case.title", "palette.command.case.title", .caseTransform(mode: .title),
             ["case", "title"]),
            ("text.case.sentence", "palette.command.case.sentence", .caseTransform(mode: .sentence),
             ["case", "sentence"]),
            ("text.case.camel", "palette.command.case.camel", .caseTransform(mode: .camel),
             ["case", "camel", "camelCase"]),
            ("text.case.snake", "palette.command.case.snake", .caseTransform(mode: .snake),
             ["case", "snake", "snake_case"]),
            ("text.case.kebab", "palette.command.case.kebab", .caseTransform(mode: .kebab),
             ["case", "kebab", "kebab-case"]),
            // Phase 41c — Format / Minify per language. JSON / XML
            // have a wide audience (config, RSS, SVG); CSS / SQL
            // serve devs. All are pure transforms via TextTransform-
            // Action so palette routing is identical to line ops.
            ("text.format.json.pretty", "palette.command.format.json.pretty", .formatJSON,
             ["format", "pretty", "json", "格式化"]),
            ("text.format.json.minify", "palette.command.format.json.minify", .minifyJSON,
             ["format", "minify", "json", "压缩"]),
            ("text.format.xml.pretty", "palette.command.format.xml.pretty", .formatXML,
             ["format", "pretty", "xml", "html"]),
            ("text.format.xml.minify", "palette.command.format.xml.minify", .minifyXML,
             ["format", "minify", "xml", "html"]),
            ("text.format.css.pretty", "palette.command.format.css.pretty", .formatCSS,
             ["format", "pretty", "css", "stylesheet"]),
            ("text.format.css.minify", "palette.command.format.css.minify", .minifyCSS,
             ["format", "minify", "css", "stylesheet"]),
            ("text.format.sql.pretty", "palette.command.format.sql.pretty", .formatSQL,
             ["format", "pretty", "sql", "query"]),
            ("text.format.sql.minify", "palette.command.format.sql.minify", .minifySQL,
             ["format", "minify", "sql", "query"]),
        ]

        // Phase 41b — Generator pack. UUID / Lorem / Timestamp
        // insert immediately; Password / QR live as separate
        // palette entries that pop their respective sheets via
        // the workspace state. Done as plain commands (not via
        // textCommands' TextTransformAction list) because the
        // dispatch shape is "insert literal" rather than
        // "transform selection".
        let now = Date()
        let snippetSpecs: [(id: String, titleKey: String,
                            generate: () -> String,
                            keywords: [String])] = [
            ("text.gen.uuid", "palette.command.generator.uuid",
             { Generators.uuidV4() },
             ["uuid", "guid", "generate", "id"]),
            ("text.gen.lorem.short", "palette.command.generator.lorem.short",
             { Generators.lorem(wordCount: 10) },
             ["lorem", "ipsum", "placeholder", "fill", "短", "占位"]),
            ("text.gen.lorem.paragraph", "palette.command.generator.lorem.paragraph",
             { Generators.lorem(wordCount: 50) },
             ["lorem", "ipsum", "placeholder", "paragraph"]),
            ("text.gen.lorem.long", "palette.command.generator.lorem.long",
             { Generators.lorem(wordCount: 100) },
             ["lorem", "ipsum", "placeholder", "long"]),
            ("text.gen.ts.iso", "palette.command.generator.timestamp.iso",
             { Generators.timestamp(format: .iso8601, now: now) },
             ["timestamp", "iso8601", "now", "时间戳"]),
            ("text.gen.ts.isoCompact", "palette.command.generator.timestamp.isoCompact",
             { Generators.timestamp(format: .iso8601Compact, now: now) },
             ["timestamp", "iso", "compact"]),
            ("text.gen.ts.unixS", "palette.command.generator.timestamp.unixS",
             { Generators.timestamp(format: .unixSeconds, now: now) },
             ["timestamp", "unix", "epoch", "seconds"]),
            ("text.gen.ts.unixMs", "palette.command.generator.timestamp.unixMs",
             { Generators.timestamp(format: .unixMillis, now: now) },
             ["timestamp", "unix", "epoch", "millis"]),
            ("text.gen.ts.rfc", "palette.command.generator.timestamp.rfc",
             { Generators.timestamp(format: .rfc2822, now: now) },
             ["timestamp", "rfc2822", "email"]),
            ("text.gen.ts.date", "palette.command.generator.timestamp.date",
             { Generators.timestamp(format: .yyyymmdd, now: now) },
             ["timestamp", "date", "yyyy"]),
            ("text.gen.ts.dateTime", "palette.command.generator.timestamp.dateTime",
             { Generators.timestamp(format: .yyyymmddHHMMSS, now: now) },
             ["timestamp", "datetime"]),
        ]
        commands.append(contentsOf: snippetSpecs.map { spec in
            ScribeCommand(id: spec.id,
                          title: localize(spec.titleKey),
                          subtitle: localize("palette.badge.text"),
                          keywords: spec.keywords) {
                findState.commands.send(.insertSnippet(spec.generate()))
            }
        })

        // Sheet-bound generators — split out so the cap-on-now()
        // logic above stays clean. Capture `workspace` directly
        // (already in scope as a function arg).
        commands.append(ScribeCommand(
            id: "text.gen.password",
            title: localize("palette.command.generator.password"),
            subtitle: localize("palette.badge.text"),
            keywords: ["password", "generate", "random", "密码"]) {
            workspace.passwordSheet = PasswordSheetRequest()
        })
        commands.append(ScribeCommand(
            id: "text.gen.qr",
            title: localize("palette.command.generator.qr"),
            subtitle: localize("palette.badge.text"),
            keywords: ["qr", "qrcode", "二维码"]) {
            let prefill = workspace.activeTextSelection
            workspace.qrSheet = QRSheetRequest(prefill: prefill)
        })
        // Phase 41e — Regex Playground.
        commands.append(ScribeCommand(
            id: "text.regex.playground",
            title: localize("palette.command.regex.playground"),
            subtitle: localize("palette.badge.text"),
            keywords: ["regex", "regexp", "regular", "expression",
                       "match", "test", "正则"]) {
            let prefill = workspace.activeTextSelection
            workspace.regexSheet = RegexSheetRequest(prefillSubject: prefill)
        })
        // Phase 44 — Hex viewer.
        commands.append(ScribeCommand(
            id: "text.hexview",
            title: localize("palette.command.hexview"),
            subtitle: localize("palette.badge.text"),
            keywords: ["hex", "hexadecimal", "binary", "dump",
                       "xxd", "hexdump", "十六进制"]) {
            guard let doc = workspace.current else { return }
            let data = Data(doc.text.utf8)
            workspace.hexViewerSheet = HexViewerRequest(
                title: doc.title, data: data)
        })

        commands.append(contentsOf: lineOpSpecs.map { spec in
            ScribeCommand(id: spec.id,
                          title: localize(spec.titleKey),
                          subtitle: localize("palette.badge.text"),
                          keywords: spec.keywords) {
                findState.commands.send(.transformSelection(spec.action))
            }
        })
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
