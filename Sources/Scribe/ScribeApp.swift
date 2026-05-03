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
    /// Phase 65 — workspace-wide symbol catalogue that backs the
    /// ⌘T "Go to Symbol in Workspace…" palette. Lives at the app
    /// level alongside `fileIndex` because a single workspace
    /// root produces one catalogue; every window / sheet that
    /// might want to jump into a symbol reads the same store.
    @StateObject private var workspaceSymbolIndex = WorkspaceSymbolIndex()
    /// Phase 33 — user's snippet collection. Owned at the app level
    /// so the ⌘⇧T palette and the Settings → Snippets tab share
    /// one source of truth; @Published mutations from the editor
    /// pane immediately reflect in the picker.
    @StateObject private var snippets = SnippetCatalog()
    /// Phase 57 — clipboard history. Single store for the whole app
    /// so every editor / sidebar / sheet hits the same FIFO. Polling
    /// kicks off in `bootstrap()` once the window is up, so a launch
    /// that never opens the main window doesn't spin the timer.
    ///
    /// Phase 67 — constructed in `init()` so the persisted
    /// `ClipboardHistoryPolicy` from `EditorPreferences` reaches the
    /// store before the very first `record()` call. Subsequent
    /// Settings toggles flow through `.onChange` modifiers in
    /// `body` and call `updatePolicy(_:)` on this instance.
    @StateObject private var clipboardHistory: ClipboardHistoryStore
    private let findInFilesEngine = FindInFilesEngine()

    init() {
        AppActivation.makeRegular()

        let preferences = EditorPreferences()
        let env = StartupEnvironment.current()
        // Phase 67d — figure out whether the workspace should start
        // with the default Untitled tab. Three skip conditions:
        //   1. CLI / `SCRIBE_AUTO_OPEN` named files (env path).
        //   2. The previous session left at least one titled tab
        //      open AND every persisted path still exists on disk
        //      — these will be re-opened by `SessionRestore.apply`.
        // Falling through both leaves the legacy first-run
        // experience: a fresh Untitled buffer.
        let hasAutoOpen = !env.autoOpenURLs.isEmpty
        let hasUsableSession = !hasAutoOpen
            && SessionRestore.usableRestorePaths(prefs: preferences).isEmpty == false
        let ws = Workspace(prefs: preferences,
                           openInitialUntitled: !(hasAutoOpen || hasUsableSession))
        StartupAutoOpen.apply(env, to: ws)
        // Phase 67d — restore last session's tabs when the CLI hasn't
        // already populated the workspace. `apply` is a no-op if the
        // pref blob is empty or every path has gone missing on disk.
        SessionRestore.apply(prefs: preferences,
                             to: ws,
                             skip: hasAutoOpen)

        // Phase 69 — auto-save scratch lifecycle on launch:
        //   1. If the user has flipped the master switch off,
        //      wipe every scratch entry from a previous "on"
        //      session so "off means off" is honoured.
        //   2. Otherwise, prune expired entries first (so the
        //      recovery sheet doesn't list weeks-old abandoned
        //      Untitleds), then surface a recovery prompt for
        //      whatever's left. The prompt is non-nil only when
        //      there's something to restore — quiet first launch.
        if !preferences.autoSaveScratchEnabled {
            ws.scratchStore.clearAll()
        } else {
            ws.scratchStore.pruneExpired(
                retentionDays: preferences.autoSaveScratchRetentionDays)
            ws.crashRecoveryPrompt = CrashRecovery.detectPending(
                store: ws.scratchStore)
        }

        _prefs = StateObject(wrappedValue: preferences)
        _workspace = StateObject(wrappedValue: ws)
        // Phase 67 — pass the persisted policy in at construction
        // time so the store loads the on-disk FIFO (when persist is
        // ON) and applies the TTL sweep before SwiftUI ever shows
        // the picker. Default storage URL points at
        // ~/Library/Application Support/Scribe/clipboard-history.json
        // — see ClipboardHistoryStore.defaultStorageURL().
        _clipboardHistory = StateObject(
            wrappedValue: ClipboardHistoryStore(
                policy: preferences.clipboardHistoryPolicy))
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
                .environmentObject(workspaceSymbolIndex)
                .environmentObject(snippets)
                .environmentObject(clipboardHistory)
                .themed(prefs: prefs)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear(perform: bootstrap)
                .onChange(of: workspace.documents.map(\.id)) { _, _ in
                    CommandRegistration.refresh(registry: commands,
                                                workspace: workspace,
                                                prefs: prefs,
                                                findState: findState,
                                                clipboardHistory: clipboardHistory,
                                                fileIndex: fileIndex,
                                                workspaceSymbolIndex: workspaceSymbolIndex)
                }
                .onChange(of: workspace.selectedID) { _, _ in
                    CommandRegistration.refresh(registry: commands,
                                                workspace: workspace,
                                                prefs: prefs,
                                                findState: findState,
                                                clipboardHistory: clipboardHistory,
                                                fileIndex: fileIndex,
                                                workspaceSymbolIndex: workspaceSymbolIndex)
                    outline.update(for: workspace.current)
                }
                .onChange(of: workspace.current?.text) { _, _ in
                    outline.update(for: workspace.current)
                }
                .onChange(of: prefs.softTabs) { _, _ in
                    CommandRegistration.refresh(registry: commands,
                                                workspace: workspace,
                                                prefs: prefs,
                                                findState: findState,
                                                clipboardHistory: clipboardHistory,
                                                fileIndex: fileIndex,
                                                workspaceSymbolIndex: workspaceSymbolIndex)
                }
                // Phase 67 — Settings can flip persistence /
                // capacity / TTL independently of each other.
                // Three onChange hooks (rather than one combined
                // observer) keep the wiring explicit and match
                // the Phase 36 / 56 precedent for per-pref hooks.
                // Each call recomputes the composite snapshot
                // through `prefs.clipboardHistoryPolicy` so the
                // store sees a coherent value even mid-drag.
                .onChange(of: prefs.clipboardHistoryPersistEnabled) { _, _ in
                    clipboardHistory.updatePolicy(prefs.clipboardHistoryPolicy)
                }
                .onChange(of: prefs.clipboardHistoryMaxItems) { _, _ in
                    clipboardHistory.updatePolicy(prefs.clipboardHistoryPolicy)
                }
                .onChange(of: prefs.clipboardHistoryRetentionDays) { _, _ in
                    clipboardHistory.updatePolicy(prefs.clipboardHistoryPolicy)
                }
                // Phase 69 — user flipped the master switch off from
                // Settings. Match the launch-time "off means off"
                // behaviour: wipe every existing scratch so the next
                // launch doesn't prompt for restore.
                .onChange(of: prefs.autoSaveScratchEnabled) { _, enabled in
                    if !enabled {
                        workspace.scratchStore.clearAll()
                    }
                }
                .onChange(of: workspace.folderRoot?.url) { _, newRoot in
                    if let newRoot {
                        fileIndex.rebuild(at: newRoot)
                    } else {
                        fileIndex.clear()
                    }
                    // Phase 65 — folder swap invalidates the
                    // workspace symbol catalogue. The index
                    // lazily rebuilds itself the next time the
                    // user invokes ⌘T, so we just drop the
                    // stale snapshot here.
                    workspaceSymbolIndex.clear()
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
                           workspaceSymbolIndex: workspaceSymbolIndex,
                           commands: commands,
                           snippets: snippets,
                           clipboardHistory: clipboardHistory,
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
        // Phase 50b — seed the Command Palette MRU from disk before
        // any palette opens so yesterday's "most recent" ordering
        // shows up on the very first ⌘⇧P press. The write-back
        // closure captures `prefs` weakly so a process exit during
        // an in-flight invoke doesn't keep the StateObject alive.
        commands.seedMRU(prefs.commandPaletteMRU)
        commands.onMRUChange = { [weak prefs] mru in
            prefs?.commandPaletteMRU = mru
        }

        CommandRegistration.refresh(registry: commands,
                                    workspace: workspace,
                                    prefs: prefs,
                                    findState: findState,
                                    clipboardHistory: clipboardHistory,
                                    fileIndex: fileIndex,
                                    workspaceSymbolIndex: workspaceSymbolIndex)
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

        // Phase 57 — kick off clipboard-history polling now that
        // the main window is up. Idempotent (the store guards
        // re-entry), so a SwiftUI re-bootstrap never spins a
        // second timer.
        clipboardHistory.start()

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
