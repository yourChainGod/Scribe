//
//  ScribeApp.swift
//  Scribe — A native macOS text editor.
//
//  This file is intentionally thin. The heavy lifting lives in:
//    - App/StartupEnvironment.swift — SCRIBE_AUTO_* parsing + auto-open dispatch
//    - App/TestHooks.swift          — SCRIBE_TEST_* verification hooks
//    - App/AppCommands.swift        — `.commands { ... }` macOS menu surface
//
//  What stays here is the minimum SwiftUI Scene declaration: the
//  @StateObject graph and the `body` that wires it together.
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
    /// Phase 33 — user's snippet collection. Owned at the app level
    /// so the ⌘⇧T palette and the Settings → Snippets tab share
    /// one source of truth; @Published mutations from the editor
    /// pane immediately reflect in the picker.
    @StateObject private var snippets = SnippetCatalog()
    private let findInFilesEngine = FindInFilesEngine()

    init() {
        AppActivation.makeRegular()

        let preferences = EditorPreferences()
        let env = StartupEnvironment.current()
        // Skip the default Untitled when SCRIBE_AUTO_OPEN already
        // gave us something to load.
        let ws = Workspace(prefs: preferences,
                           openInitialUntitled: env.autoOpenURLs.isEmpty)
        StartupAutoOpen.apply(env, to: ws)

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
                .environmentObject(snippets)
                .themed(prefs: prefs)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear(perform: bootstrap)
                .onChange(of: workspace.documents.map(\.id)) { _, _ in
                    CommandRegistration.refresh(registry: commands,
                                                workspace: workspace,
                                                prefs: prefs,
                                                findState: findState)
                }
                .onChange(of: workspace.selectedID) { _, _ in
                    CommandRegistration.refresh(registry: commands,
                                                workspace: workspace,
                                                prefs: prefs,
                                                findState: findState)
                    outline.update(for: workspace.current)
                }
                .onChange(of: workspace.current?.text) { _, _ in
                    outline.update(for: workspace.current)
                }
                .onChange(of: prefs.softTabs) { _, _ in
                    CommandRegistration.refresh(registry: commands,
                                                workspace: workspace,
                                                prefs: prefs,
                                                findState: findState)
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
        // Phase 38g — file/edit/zoom ops live in the SwiftUI
        // `.toolbar` (rendered by macOS on the same physical row
        // as the traffic lights). Sidebar mode tabs + collapse
        // button stay inside the sidebar's own top row — they're
        // sidebar controls, not app-level commands. The vertical
        // splitter between sidebar and detail starts from below
        // the toolbar and runs uninterrupted to the status bar.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            ScribeCommands(workspace: workspace,
                           prefs: prefs,
                           findState: findState,
                           findInFiles: findInFiles,
                           fileIndex: fileIndex,
                           outline: outline,
                           commands: commands,
                           snippets: snippets,
                           findInFilesEngine: findInFilesEngine)
        }

        Settings {
            SettingsView()
                .environmentObject(prefs)
                .environmentObject(snippets)
                .themed(prefs: prefs)
        }
    }

    /// One-shot wiring at first appearance of the main window.
    /// Splits out from `body` so the closure doesn't grow large
    /// enough to upset SwiftUI's view-builder type-checker.
    @MainActor
    private func bootstrap() {
        CommandRegistration.refresh(registry: commands,
                                    workspace: workspace,
                                    prefs: prefs,
                                    findState: findState)
        // Wire ⌘P's `>` route through to the same registry ⌘⇧P
        // uses, so users can run any palette command without
        // dismissing Quick Open first.
        QuickOpenController.shared.bindCommandPalette(commands)
        // External FS changes (git checkout, mv, npm install) ⇒
        // reload the file tree so the sidebar matches disk. The
        // index already updates itself; this is the host-app
        // callback for the FileNode view layer.
        fileIndex.onFileSystemChange = { [workspace] in
            workspace.folderRoot?.reload()
        }
        // First-launch: index the folder we restored from
        // SCRIBE_AUTO_FOLDER / Recent if any.
        if let root = workspace.folderRoot?.url {
            fileIndex.rebuild(at: root)
        }
        outline.update(for: workspace.current)

        // Drive every SCRIBE_TEST_* hook. Production users never
        // hit any of these because every variable defaults to
        // "unset" and every hook short-circuits on absence.
        TestHooks.runAll(TestHookContext(
            workspace: workspace,
            prefs: prefs,
            findState: findState,
            findInFiles: findInFiles,
            findInFilesEngine: findInFilesEngine,
            fileIndex: fileIndex,
            outline: outline,
            commands: commands
        ))
    }
}
