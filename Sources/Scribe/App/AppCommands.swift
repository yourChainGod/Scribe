//
//  AppCommands.swift
//  ScribeApp's `.commands { ... }` payload — the macOS menu bar.
//  Lives outside ScribeApp.swift so the @main scene type stays
//  readable as a Scene declaration; this file is the menu surface.
//
//  Why a `Commands`-conforming struct rather than a free `var commands`:
//    - SwiftUI's `Commands` builder is curried at the type level
//      (`some Commands`), so we have to expose a type, not a value.
//    - The struct lets us pass every observable through as a
//      property rather than capturing them in a closure, which keeps
//      the callsite at ScribeApp.body matching the pattern used by
//      the Settings scene.
//

import SwiftUI
import AppKit

struct ScribeCommands: Commands {
    @ObservedObject var workspace: Workspace
    @ObservedObject var prefs: EditorPreferences
    @ObservedObject var findState: FindState
    @ObservedObject var findInFiles: FindInFilesState
    @ObservedObject var fileIndex: FileIndex
    @ObservedObject var outline: SymbolOutline
    @ObservedObject var commands: CommandRegistry
    /// Phase 33 — passed through so the Edit → Insert Snippet menu
    /// can hand the active catalog to SnippetController.
    @ObservedObject var snippets: SnippetCatalog
    let findInFilesEngine: FindInFilesEngine

    var body: some Commands {
        // — File menu —
        CommandGroup(replacing: .newItem) {
            Button { workspace.newDocument() } label: { Text("menu.file.new", bundle: .module) }
                .keyboardShortcut("n")
            Button { workspace.openDocument() } label: { Text("menu.file.open", bundle: .module) }
                .keyboardShortcut("o")
            Button { workspace.openFolder() } label: { Text("menu.file.openFolder", bundle: .module) }
                .keyboardShortcut("o", modifiers: [.command, .option])
            RecentFilesMenu(prefs: prefs, workspace: workspace)
            RecentFoldersMenu(prefs: prefs, workspace: workspace)
        }
        CommandGroup(after: .saveItem) {
            Button { workspace.saveCurrent() } label: { Text("menu.file.save", bundle: .module) }
                .keyboardShortcut("s")
        }

        // — View menu —
        CommandGroup(after: .toolbar) {
            Button { prefs.zoomIn() } label: { Text("menu.view.zoomIn", bundle: .module) }
                .keyboardShortcut("+", modifiers: .command)
            Button { prefs.zoomOut() } label: { Text("menu.view.zoomOut", bundle: .module) }
                .keyboardShortcut("-", modifiers: .command)
            Button { prefs.resetFontSize() } label: { Text("menu.view.zoomReset", bundle: .module) }
                .keyboardShortcut("0", modifiers: .command)

            // Phase 15 — theme picker. Sub-menu so the View root
            // doesn't grow long; checkmark on the active item works
            // because the prefs object is observed by the host scene.
            // Phase 36 — drives the global UI theme. The editor
            // follows by default (toggle in Settings > Appearance to
            // decouple).
            Menu {
                ForEach(ThemeID.allCases) { id in
                    Button {
                        prefs.uiThemeID = id
                    } label: {
                        // Leading checkmark by way of label —
                        // SwiftUI's Menu doesn't natively expose a
                        // "checked" state on plain Buttons.
                        if prefs.uiThemeID == id {
                            Label(id.displayName, systemImage: "checkmark")
                        } else {
                            Text(id.displayName)
                        }
                    }
                }
            } label: {
                Text("menu.view.editorTheme", bundle: .module)
            }

            Divider()

            // Phase 30 — Markdown preview pane toggle. Disabled when
            // the active document isn't markdown so the user gets a
            // clear cue that it does nothing for, say, a .swift file.
            Button {
                workspace.toggleMarkdownPreview()
            } label: {
                if workspace.current?.isMarkdownPreviewVisible == true {
                    Label(L10n.t("menu.view.markdownPreview"),
                          systemImage: "checkmark")
                } else {
                    Text("menu.view.markdownPreview", bundle: .module)
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!workspace.canToggleMarkdownPreview)
        }

        // — Go menu —
        CommandMenu(Text("menu.go", bundle: .module)) {
            Button {
                QuickOpenController.shared.toggle(workspace: workspace,
                                                  fileIndex: fileIndex,
                                                  outline: outline)
            } label: { Text("menu.go.quickOpen", bundle: .module) }
            .keyboardShortcut("p", modifiers: .command)

            Button {
                PaletteWindowController.shared.toggle(registry: commands)
            } label: { Text("menu.go.commandPalette", bundle: .module) }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button {
                workspace.sidebarVisible = true
                workspace.sidebarMode = .outline
            } label: { Text("menu.view.showOutline", bundle: .module) }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        // — Tools menu —
        CommandMenu(Text("menu.tools", bundle: .module)) {
            Button {
                workspace.isTextToolsPresented = true
            } label: {
                Text("menu.tools.textTools", bundle: .module)
            }
            .disabled(workspace.current == nil)

            Menu {
                TextTransformCommandButtons(findState: findState, workspace: workspace, prefs: prefs)
            } label: {
                Text("menu.tools.transformSelection", bundle: .module)
            }
            .disabled(workspace.current == nil)

            // Phase 41a — Hash submenu surfaced at the top level
            // so users can find it without drilling into Transform
            // Selection. Same actions, same shortcut path
            // (FindState.commands → Coordinator → Scintilla
            // REPLACESEL).
            Menu {
                Button { findState.commands.send(.transformSelection(.md5)) } label: {
                    Text("transform.hash.md5", bundle: .module)
                }
                Button { findState.commands.send(.transformSelection(.sha1)) } label: {
                    Text("transform.hash.sha1", bundle: .module)
                }
                Button { findState.commands.send(.transformSelection(.sha256)) } label: {
                    Text("transform.hash.sha256", bundle: .module)
                }
                Button { findState.commands.send(.transformSelection(.sha512)) } label: {
                    Text("transform.hash.sha512", bundle: .module)
                }
                Button { findState.commands.send(.transformSelection(.crc32)) } label: {
                    Text("transform.hash.crc32", bundle: .module)
                }
            } label: {
                Text("transform.hash.menu", bundle: .module)
            }
            .disabled(workspace.current == nil)

            // Phase 41a — JWT decoder. Independent button (no
            // submenu) — there's only one action.
            Button {
                let prefill = workspace.activeTextSelection
                workspace.jwtSheet = JWTSheetRequest(prefill: prefill)
            } label: {
                Text("transform.jwt.decode", bundle: .module)
            }

            // Phase 41d — Line operations grouped by purpose.
            Menu {
                LineOpsCommandButtons(findState: findState, prefs: prefs)
            } label: {
                Text("lineops.menu", bundle: .module)
            }
            .disabled(workspace.current == nil)

            Divider()

            Button {
                let session = DiffSession()
                session.chooseAndCompare()
                if session.leftURL != nil, session.rightURL != nil {
                    workspace.compareSession = session
                }
            } label: {
                Text("menu.tools.diff", bundle: .module)
            }
            .keyboardShortcut("d", modifiers: [.command, .option])

            Button {
                guard let url = workspace.current?.url else { return }
                let session = DiffSession()
                session.loadGitHEAD(file: url)
                // Surface the session whether or not the load
                // succeeded — the panel renders the error message
                // when there's no result.
                workspace.compareSession = session
            } label: {
                Text("menu.tools.compareHEAD", bundle: .module)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(workspace.current?.url == nil)

            Divider()

            // Phase 31b — git-gutter hunk navigation. Wraps top↔bottom
            // and beeps if the file has no changes vs HEAD. ⌥⇧↓ / ⌥⇧↑
            // mirror the "Option = navigate by chunks" convention
            // already used by addCaretAbove/Below (⌘⌥↑/↓).
            // Disabled when there's no document to navigate against
            // (initial untitled buffer scenarios).
            Button {
                findState.commands.send(.gotoNextHunk)
            } label: {
                Text("menu.tools.nextHunk", bundle: .module)
            }
            .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            .disabled(workspace.current == nil)

            Button {
                findState.commands.send(.gotoPrevHunk)
            } label: {
                Text("menu.tools.prevHunk", bundle: .module)
            }
            .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
            .disabled(workspace.current == nil)
        }

        // — Edit menu —
        CommandGroup(replacing: .textEditing) {
            Button {
                findState.show(replaceMode: false)
            } label: { Text("menu.edit.find", bundle: .module) }
            .keyboardShortcut("f", modifiers: .command)

            Button {
                findState.show(replaceMode: true)
            } label: { Text("menu.edit.replace", bundle: .module) }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Button {
                if !findState.isVisible { findState.show(replaceMode: false) }
                findState.commands.send(.findNext)
            } label: { Text("menu.edit.findNext", bundle: .module) }
            .keyboardShortcut("g", modifiers: .command)

            Button {
                if !findState.isVisible { findState.show(replaceMode: false) }
                findState.commands.send(.findPrev)
            } label: { Text("menu.edit.findPrev", bundle: .module) }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Button {
                findState.show(replaceMode: false)
                findState.commands.send(.useSelection)
            } label: { Text("menu.edit.useSelection", bundle: .module) }
            .keyboardShortcut("e", modifiers: .command)

            Divider()

            // Phase 24 — Multi-Cursor commands grouped under a submenu
            // so the parent Edit menu doesn't sprawl past 20 items.
            // The submenu's contents are the accumulated work of
            // phases 20–23. SwiftUI's Menu nests inside CommandGroup
            // just fine — it ends up as an NSMenu submenu in the
            // bridged AppKit menu bar.
            Menu {
                Button {
                    findState.commands.send(.selectNextOccurrence)
                } label: { Text("menu.edit.selectNext", bundle: .module) }
                .keyboardShortcut("d", modifiers: .command)

                Button {
                    findState.commands.send(.selectAllOccurrences)
                } label: { Text("menu.edit.selectAll.occ", bundle: .module) }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                // Phase 22 — skip the current ⌘D selection and jump
                // to the next occurrence. VSCode binds it to the
                // chord ⌘K ⌘D, which SwiftUI's KeyboardShortcut
                // can't express (single-key only). ⌃⌘D is the
                // closest unused single shortcut on Scribe's
                // existing key map.
                Button {
                    findState.commands.send(.skipAndSelectNextOccurrence)
                } label: { Text("menu.edit.skipNext", bundle: .module) }
                .keyboardShortcut("d", modifiers: [.command, .control])

                Divider()

                // Phase 21 — vertical multi-cursor. ⌥⌘↑/⌥⌘↓ matches
                // VSCode + Sublime; on Sublime it's ⌃⇧↑/↓ but the
                // ⌥⌘ pair feels more macOS-native.
                Button {
                    findState.commands.send(.addCaretAbove)
                } label: { Text("menu.edit.cursorAbove", bundle: .module) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])

                Button {
                    findState.commands.send(.addCaretBelow)
                } label: { Text("menu.edit.cursorBelow", bundle: .module) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                Divider()

                // Phase 23 — column / rectangular selection toggle.
                // ⌘⇧8 matches VSCode + IntelliJ. Independent of the
                // ⇧⌥+arrow chord (Scintilla cocoa default → rect
                // extend) — the toggle is for users who want to type
                // / arrow into a rectangle without holding a
                // modifier the whole time.
                Button {
                    findState.commands.send(.toggleColumnSelectionMode)
                } label: { Text("menu.edit.columnSelect", bundle: .module) }
                .keyboardShortcut("8", modifiers: [.command, .shift])

                Button {
                    findState.commands.send(.collapseToSingleCursor)
                } label: { Text("menu.edit.singleCursor", bundle: .module) }
                // ⌃⇧Esc — plain Esc is reserved for "hide find bar".
                .keyboardShortcut(.escape, modifiers: [.control, .shift])
            } label: {
                Text("menu.edit.multiCursor", bundle: .module)
            }

            Divider()

            Button {
                workspace.sidebarVisible = true
                workspace.sidebarMode = .search
                // Phase 18: prefill the query with the live editor
                // selection (if any) and kick off a search right
                // away. Empty selection ⇒ original behaviour
                // (focus the input, leave any prior query alone).
                let selection = workspace.activeSelection
                if !selection.isEmpty {
                    findInFiles.query = selection
                    if let root = workspace.folderRoot?.url {
                        let opts = FindInFilesOptions(
                            query: selection,
                            matchCase: findInFiles.matchCase,
                            wholeWord: findInFiles.wholeWord,
                            regex: false,             // literal — selection text shouldn't
                                                      // be re-interpreted as regex by accident
                            includeGlobs: [],
                            excludeGlobs: []
                        )
                        findInFilesEngine.search(options: opts,
                                                 root: root,
                                                 into: findInFiles)
                    }
                }
            } label: { Text("menu.edit.findInFiles", bundle: .module) }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            // Phase 33 — Insert Snippet… ⌘⇧T. Pops the snippet picker
            // (a CommandPalette over a snippet-derived registry) so
            // the user can fuzzy-find a template by name or prefix.
            // The picker dispatches the body through findState.commands
            // → Coordinator → insertAtCarets, which lands the same
            // text at every active caret. Disabled when the catalog
            // is empty *and* there's no document — Settings → Snippets
            // is the empty-state recovery path.
            Button {
                SnippetController.shared.toggle(catalog: snippets,
                                                findState: findState)
            } label: { Text("menu.edit.insertSnippet", bundle: .module) }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(workspace.current == nil)

            Divider()

            Button {
                findState.hide()
            } label: { Text("menu.edit.hideFindBar", bundle: .module) }
            .keyboardShortcut(.escape, modifiers: [])
        }
    }
}

// MARK: - Recent submenus

/// "Open Recent" — files. Sourced from EditorPreferences.recentFiles.
struct RecentFilesMenu: View {
    @ObservedObject var prefs: EditorPreferences
    let workspace: Workspace

    var body: some View {
        Menu {
            if prefs.recentFiles.isEmpty {
                Text("menu.file.noRecentFiles", bundle: .module)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(prefs.recentFiles, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        workspace.openFile(at: url)
                    }
                }
                Divider()
                Button {
                    prefs.clearRecent()
                } label: { Text("menu.file.openRecentClear", bundle: .module) }
            }
        } label: {
            Text("menu.file.openRecent", bundle: .module)
        }
    }
}

/// "Open Recent Folder" — workspace folders. Sourced from
/// EditorPreferences.recentFolders.
struct RecentFoldersMenu: View {
    @ObservedObject var prefs: EditorPreferences
    let workspace: Workspace

    var body: some View {
        Menu {
            if prefs.recentFolders.isEmpty {
                Text("menu.file.noRecentFolders", bundle: .module)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(prefs.recentFolders, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        workspace.openFolder(at: url)
                    }
                }
                Divider()
                Button {
                    prefs.clearRecentFolders()
                } label: { Text("menu.file.openRecentClear", bundle: .module) }
            }
        } label: {
            Text("menu.file.openRecentFolder", bundle: .module)
        }
    }
}
