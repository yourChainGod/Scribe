//
//  ScribeApp.swift
//  Scribe — A native macOS text editor.
//

import SwiftUI
import AppKit

@main
struct ScribeApp: App {
    @StateObject private var prefs: EditorPreferences
    @StateObject private var workspace: Workspace
    @StateObject private var commands = CommandRegistry()
    @StateObject private var findState = FindState()
    @StateObject private var findInFiles = FindInFilesState()
    @StateObject private var fileIndex = FileIndex()
    @StateObject private var outline = SymbolOutline()
    private let findInFilesEngine = FindInFilesEngine()

    init() {
        // SwiftPM-built executables default to background activation policy.
        // Force regular UI app so the window actually appears in Dock + foreground.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        let preferences = EditorPreferences()

        // Files to auto-open at startup, expressed as a colon-separated path
        // list in `SCRIBE_AUTO_OPEN`. We deliberately do NOT consume
        // `CommandLine.arguments`: SwiftUI's WindowGroup interprets positional
        // file arguments as an "open document" intent and refuses to
        // materialize the main window until an NSDocument-based open event
        // arrives — which never happens for SwiftPM-built unbundled
        // executables.  See HANDOFF section 5.7 for the full diagnosis.
        let autoOpen: [URL] = (ProcessInfo.processInfo.environment["SCRIBE_AUTO_OPEN"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .compactMap { path in
                FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
            }

        // Skip the default Untitled when SCRIBE_AUTO_OPEN already gave us
        // something to load.
        let ws = Workspace(prefs: preferences, openInitialUntitled: autoOpen.isEmpty)

        // Defer auto-open to the next runloop turn so the WindowGroup gets
        // its NSWindow materialized first. Eager mutation of @Published state
        // here is observed to delay (or skip!) NSWindow creation on
        // macOS 14+ / swift-tools 5.9.
        let autoFolder = (ProcessInfo.processInfo.environment["SCRIBE_AUTO_FOLDER"] ?? "")
        // SCRIBE_AUTO_COMPARE expects "leftPath:rightPath" — opens the
        // diff view straight away. Used by Phase 5 verification scripts.
        let autoCompare = (ProcessInfo.processInfo.environment["SCRIBE_AUTO_COMPARE"] ?? "")
        DispatchQueue.main.async {
            for url in autoOpen {
                ws.openFile(at: url)
            }
            if !autoFolder.isEmpty {
                let url = URL(fileURLWithPath: autoFolder)
                if FileManager.default.fileExists(atPath: url.path) {
                    ws.openFolder(at: url)
                }
            }
            if !autoCompare.isEmpty {
                let parts = autoCompare.split(separator: ":", maxSplits: 1)
                                       .map(String.init)
                if parts.count == 2,
                   FileManager.default.fileExists(atPath: parts[0]),
                   FileManager.default.fileExists(atPath: parts[1]) {
                    let session = DiffSession()
                    session.load(left: URL(fileURLWithPath: parts[0]),
                                 right: URL(fileURLWithPath: parts[1]))
                    ws.compareSession = session
                }
            }
        }

        _prefs = StateObject(wrappedValue: preferences)
        _workspace = StateObject(wrappedValue: ws)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(findInFilesEngine: findInFilesEngine)
                .environmentObject(workspace)
                .environmentObject(prefs)
                .environmentObject(commands)
                .environmentObject(findState)
                .environmentObject(findInFiles)
                .environmentObject(fileIndex)
                .environmentObject(outline)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    CommandRegistration.refresh(
                        registry: commands,
                        workspace: workspace,
                        prefs: prefs
                    )
                    // Wire ⌘P's `>` route through to the same registry
                    // ⌘⇧P uses, so users can run any palette command
                    // without dismissing Quick Open first.
                    QuickOpenController.shared.bindCommandPalette(commands)
                    // External FS changes (git checkout, mv, npm install)
                    // → reload the file tree so the sidebar matches disk.
                    // The index already updates itself; this is the
                    // host-app callback for the FileNode view layer.
                    fileIndex.onFileSystemChange = { [workspace] in
                        workspace.folderRoot?.reload()
                    }
                    // First-launch: index the folder we restored from
                    // SCRIBE_AUTO_FOLDER / Recent if any.
                    if let root = workspace.folderRoot?.url {
                        fileIndex.rebuild(at: root)
                    }
                    outline.update(for: workspace.current)
                    // Phase 23 verification hook: SCRIBE_TEST_RECT_SELECT
                    // = "<linesDown>:<charsRight>" toggles the doc
                    // into SC_SEL_RECTANGLE then drives
                    // LINEDOWNRECTEXTEND × N + CHARRIGHTRECTEXTEND × M
                    // so the screenshot script can show a real
                    // rectangle highlight without keystroke synthesis.
                    if let raw = ProcessInfo.processInfo.environment["SCRIBE_TEST_RECT_SELECT"] {
                        let parts = raw.split(separator: ":").map(String.init)
                        let lines = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
                        let chars = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            findState.commands.send(.toggleColumnSelectionMode)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                findState.commands.send(.testRectSelectExtend(linesDown: lines, charsRight: chars))
                            }
                        }
                    }
                    // Phase 22 verification hook: SCRIBE_TEST_SKIP_NEXT
                    // = "<needle>" runs ⌘D twice (so two occurrences
                    // are selected), then ⌃⌘D once (skip current,
                    // pick next). Used by the screenshot script to
                    // demonstrate the skip-and-advance behaviour.
                    if let needle = ProcessInfo.processInfo.environment["SCRIBE_TEST_SKIP_NEXT"],
                       !needle.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            findState.query = needle
                            findState.commands.send(.findCurrent)   // selects first match
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                findState.commands.send(.selectNextOccurrence) // 2 selections
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    findState.commands.send(.selectNextOccurrence) // 3 selections
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        // skip the current main and replace with the next match
                                        findState.commands.send(.skipAndSelectNextOccurrence)
                                    }
                                }
                            }
                        }
                    }
                    // Phase 21 verification hook: SCRIBE_TEST_MULTI_VERTICAL
                    // = "<count>" sends `addCaretBelow` <count> times,
                    // then sends a literal "* " typing event so the
                    // screenshot script gets a visible proof that all
                    // stacked carets received the keystroke. Pure
                    // caret bars are tough to capture in a static
                    // screenshot — the inserted markers tell the
                    // story instead.
                    if let raw = ProcessInfo.processInfo.environment["SCRIBE_TEST_MULTI_VERTICAL"],
                       let n = Int(raw), n > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            for _ in 0..<n {
                                findState.commands.send(.addCaretBelow)
                            }
                            // After the carets are stacked, inject a
                            // marker into all of them via SCI_REPLACESEL
                            // so the screenshot has visible proof. The
                            // responder-chain insertText: path doesn't
                            // reach ScintillaView, so we route through
                            // the Coordinator instead.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                findState.commands.send(.insertAtCarets("★"))
                            }
                        }
                    }
                    // Phase 20 verification hook: SCRIBE_TEST_MULTI_SELECT
                    // takes a literal needle, finds it in the active
                    // document, selects every occurrence as a multi-
                    // cursor selection. Used by the screenshot script
                    // to demonstrate multi-cursor without driving
                    // ⌘D keystrokes through System Events.
                    if let needle = ProcessInfo.processInfo.environment["SCRIBE_TEST_MULTI_SELECT"],
                       !needle.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            // Stash the needle as the "selection" the
                            // command will pick up. The Coordinator
                            // expands the live selection to a word
                            // when no range exists, so we set the
                            // selection text via FindState then
                            // adopt it back into the editor.
                            findState.query = needle
                            findState.commands.send(.findCurrent)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                findState.commands.send(.selectAllOccurrences)
                            }
                        }
                    }
                    // Phase 18 verification hook: SCRIBE_TEST_FIND_FROM_SELECTION
                    // primes Workspace.activeSelection so the screenshot
                    // script can demonstrate the prefill-from-selection
                    // path without driving an actual SCN_UPDATEUI tick.
                    if let s = ProcessInfo.processInfo.environment["SCRIBE_TEST_FIND_FROM_SELECTION"],
                       !s.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            workspace.activeSelection = s
                        }
                    }
                    // Phase 15 verification hook: SCRIBE_TEST_THEME pins
                    // the editor to the named theme at startup so the
                    // screenshot script can grab a single palette
                    // without driving the View > Editor Theme menu.
                    if let themeRaw = ProcessInfo.processInfo.environment["SCRIBE_TEST_THEME"],
                       let id = ThemeID(rawValue: themeRaw) {
                        prefs.themeID = id
                    }
                    // Phase 11 verification hook: SCRIBE_TEST_PALETTE_QUERY
                    // pre-fills ⌘P with the given query so we can take a
                    // screenshot of the symbol-mode UI without
                    // synthesising keystrokes through a non-activating
                    // panel (which simulators struggle to drive).
                    if let q = ProcessInfo.processInfo.environment["SCRIBE_TEST_PALETTE_QUERY"],
                       !q.isEmpty {
                        // outline parses asynchronously: 250 ms debounce
                        // + detached parse on a background queue.
                        // 1.5 s is comfortable headroom for any file
                        // we'd reasonably auto-open at startup.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            QuickOpenController.shared.show(
                                workspace: workspace,
                                fileIndex: fileIndex,
                                outline: outline,
                                initialQuery: q
                            )
                        }
                    }
                    // Phase 16 verification hook: run Find-in-Files
                    // against the seeded folder. Lets the screenshot
                    // workflow exercise the result tree without
                    // depending on flaky keystroke synthesis through
                    // the borderless Find sidebar.
                    if let q = ProcessInfo.processInfo.environment["SCRIBE_TEST_FIND_QUERY"],
                       !q.isEmpty {
                        // folderRoot is opened by SCRIBE_AUTO_FOLDER in
                        // ScribeApp.init's 0.05 s delay, so we resolve
                        // the root inside the closure rather than at
                        // onAppear time when it's still nil.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            guard let root = workspace.folderRoot?.url else { return }
                            workspace.sidebarMode = .search
                            workspace.sidebarVisible = true
                            findInFiles.query = q
                            let opts = FindInFilesOptions(
                                query: q,
                                matchCase: false,
                                wholeWord: false,
                                regex: false,
                                includeGlobs: [],
                                excludeGlobs: []
                            )
                            findInFilesEngine.search(options: opts,
                                                     root: root,
                                                     into: findInFiles)
                            // Optional: SCRIBE_TEST_FIND_DESELECT is a
                            // comma-separated list of filenames whose
                            // checkbox should be unticked once results
                            // arrive. Lets the screenshot script
                            // demonstrate the partial-replace summary
                            // without simulating clicks on a checkbox.
                            if let deselect = ProcessInfo.processInfo.environment["SCRIBE_TEST_FIND_DESELECT"],
                               !deselect.isEmpty {
                                let names = deselect.split(separator: ",")
                                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    for r in findInFiles.results
                                        where names.contains(r.url.lastPathComponent) {
                                        findInFiles.toggleSelection(r.url)
                                    }
                                }
                            }
                            // Phase 17 verification hook: line-level
                            // opt-out. Format is
                            //   "<filename>:<line>,<filename>:<line>"
                            // e.g. "lib.rs:2,main.rs:1". Resolved
                            // against current findInFiles.results.
                            if let lines = ProcessInfo.processInfo.environment["SCRIBE_TEST_FIND_DESELECT_LINES"],
                               !lines.isEmpty {
                                let pairs = lines.split(separator: ",")
                                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                    for pair in pairs {
                                        let parts = pair.split(separator: ":")
                                        guard parts.count == 2,
                                              let line = Int(parts[1]) else { continue }
                                        let name = String(parts[0])
                                        if let result = findInFiles.results.first(
                                            where: { $0.url.lastPathComponent == name }
                                        ) {
                                            findInFiles.toggleLineSelection(result.url, line: line)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .onChange(of: workspace.documents.map(\.id)) { _, _ in
                    CommandRegistration.refresh(registry: commands, workspace: workspace, prefs: prefs)
                }
                .onChange(of: workspace.selectedID) { _, _ in
                    CommandRegistration.refresh(registry: commands, workspace: workspace, prefs: prefs)
                    outline.update(for: workspace.current)
                }
                .onChange(of: workspace.current?.text) { _, _ in
                    outline.update(for: workspace.current)
                }
                .onChange(of: prefs.softTabs) { _, _ in
                    CommandRegistration.refresh(registry: commands, workspace: workspace, prefs: prefs)
                }
                .onChange(of: workspace.folderRoot?.url) { _, newRoot in
                    if let newRoot {
                        fileIndex.rebuild(at: newRoot)
                    } else {
                        fileIndex.clear()
                    }
                }
                .onOpenURL { url in
                    workspace.openFile(at: url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { workspace.newDocument() }
                    .keyboardShortcut("n")
                Button("Open…") { workspace.openDocument() }
                    .keyboardShortcut("o")
                Button("Open Folder…") { workspace.openFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                RecentFilesMenu(prefs: prefs, workspace: workspace)
                RecentFoldersMenu(prefs: prefs, workspace: workspace)
            }
            CommandGroup(after: .saveItem) {
                Button("Save") { workspace.saveCurrent() }
                    .keyboardShortcut("s")
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { prefs.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { prefs.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { prefs.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)

                // Phase 15 — theme picker. Sub-menu so the View root
                // doesn't grow long; checkmark on the active item
                // works because the prefs object is observed by the
                // host scene.
                Menu("Editor Theme") {
                    ForEach(ThemeID.allCases) { id in
                        Button {
                            prefs.themeID = id
                        } label: {
                            // Leading checkmark by way of label —
                            // SwiftUI's Menu doesn't natively expose a
                            // "checked" state on plain Buttons.
                            if prefs.themeID == id {
                                Label(id.displayName, systemImage: "checkmark")
                            } else {
                                Text(id.displayName)
                            }
                        }
                    }
                }
            }
            CommandMenu("Go") {
                Button("Quick Open File…") {
                    QuickOpenController.shared.toggle(workspace: workspace,
                                                      fileIndex: fileIndex,
                                                      outline: outline)
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Command Palette…") {
                    PaletteWindowController.shared.toggle(registry: commands)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                Button("Show Outline") {
                    workspace.sidebarVisible = true
                    workspace.sidebarMode = .outline
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Tools") {
                Button("Compare Files…") {
                    let session = DiffSession()
                    session.chooseAndCompare()
                    if session.leftURL != nil, session.rightURL != nil {
                        workspace.compareSession = session
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .option])

                Button("Compare with HEAD") {
                    guard let url = workspace.current?.url else { return }
                    let session = DiffSession()
                    session.loadGitHEAD(file: url)
                    // Surface the session whether or not the load
                    // succeeded — the panel renders the error message
                    // when there's no result.
                    workspace.compareSession = session
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace.current?.url == nil)
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find…") {
                    findState.show(replaceMode: false)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Replace…") {
                    findState.show(replaceMode: true)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Button("Find Next") {
                    if !findState.isVisible { findState.show(replaceMode: false) }
                    findState.commands.send(.findNext)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") {
                    if !findState.isVisible { findState.show(replaceMode: false) }
                    findState.commands.send(.findPrev)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button("Use Selection for Find") {
                    findState.show(replaceMode: false)
                    findState.commands.send(.useSelection)
                }
                .keyboardShortcut("e", modifiers: .command)

                Divider()

                // Phase 24 — Multi-Cursor commands grouped under a
                // submenu so the parent Edit menu doesn't sprawl
                // past 20 items. The submenu's contents are the
                // accumulated work of phases 20–23. SwiftUI's
                // Menu view nests inside CommandGroup just fine —
                // it ends up as an NSMenu submenu in the bridged
                // AppKit menubar.
                Menu("Multi-Cursor") {
                    // Horizontal multi-cursor (Phase 20).
                    Button("Select Next Occurrence") {
                        findState.commands.send(.selectNextOccurrence)
                    }
                    .keyboardShortcut("d", modifiers: .command)

                    Button("Select All Occurrences") {
                        findState.commands.send(.selectAllOccurrences)
                    }
                    .keyboardShortcut("l", modifiers: [.command, .shift])

                    // Phase 22 — skip the current ⌘D selection and jump
                    // to the next occurrence. VSCode binds it to the
                    // chord ⌘K ⌘D, which SwiftUI's KeyboardShortcut
                    // can't express (single-key only). ⌃⌘D is the
                    // closest unused single shortcut on Scribe's
                    // existing key map.
                    Button("Skip Next Occurrence") {
                        findState.commands.send(.skipAndSelectNextOccurrence)
                    }
                    .keyboardShortcut("d", modifiers: [.command, .control])

                    Divider()

                    // Phase 21 — vertical multi-cursor. ⌥⌘↑/⌥⌘↓
                    // matches VSCode + Sublime; on Sublime it's
                    // ⌃⇧↑/↓ but the ⌥⌘ pair feels more macOS-native.
                    Button("Add Cursor Above") {
                        findState.commands.send(.addCaretAbove)
                    }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])

                    Button("Add Cursor Below") {
                        findState.commands.send(.addCaretBelow)
                    }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                    Divider()

                    // Phase 23 — column / rectangular selection
                    // toggle. ⌘⇧8 matches VSCode + IntelliJ.
                    // Independent of the ⇧⌥+arrow chord (Scintilla
                    // cocoa default → rect extend) — the toggle
                    // is for users who want to type / arrow into a
                    // rectangle without holding a modifier the
                    // whole time.
                    Button("Toggle Column Selection Mode") {
                        findState.commands.send(.toggleColumnSelectionMode)
                    }
                    .keyboardShortcut("8", modifiers: [.command, .shift])

                    Button("Single Cursor") {
                        findState.commands.send(.collapseToSingleCursor)
                    }
                    // ⌃⇧Esc — plain Esc is reserved for "hide find bar".
                    .keyboardShortcut(.escape, modifiers: [.control, .shift])
                }

                Divider()

                Button("Find in Files…") {
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
                                regex: false,                       // literal — selection text shouldn't
                                                                    // be re-interpreted as regex by accident
                                includeGlobs: [],
                                excludeGlobs: []
                            )
                            findInFilesEngine.search(options: opts,
                                                     root: root,
                                                     into: findInFiles)
                        }
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Divider()

                Button("Hide Find Bar") {
                    findState.hide()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(prefs)
        }
    }
}

private struct RecentFilesMenu: View {
    @ObservedObject var prefs: EditorPreferences
    let workspace: Workspace

    var body: some View {
        Menu("Open Recent") {
            if prefs.recentFiles.isEmpty {
                Text("No Recent Files")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(prefs.recentFiles, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        workspace.openFile(at: url)
                    }
                }
                Divider()
                Button("Clear Menu") { prefs.clearRecent() }
            }
        }
    }
}

private struct RecentFoldersMenu: View {
    @ObservedObject var prefs: EditorPreferences
    let workspace: Workspace

    var body: some View {
        Menu("Open Recent Folder") {
            if prefs.recentFolders.isEmpty {
                Text("No Recent Folders")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(prefs.recentFolders, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        workspace.openFolder(at: url)
                    }
                }
                Divider()
                Button("Clear Menu") { prefs.clearRecentFolders() }
            }
        }
    }
}
