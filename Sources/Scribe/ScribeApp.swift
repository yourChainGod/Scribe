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
            }
            CommandMenu("Go") {
                Button("Quick Open File…") {
                    QuickOpenController.shared.toggle(workspace: workspace,
                                                      fileIndex: fileIndex)
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

                Button("Find in Files…") {
                    workspace.sidebarVisible = true
                    workspace.sidebarMode = .search
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
