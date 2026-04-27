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

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SCRIBE_DEBUG_LOG"] == "1" {
            try? Data("ScribeApp.init: env SCRIBE_AUTO_OPEN=\(ProcessInfo.processInfo.environment["SCRIBE_AUTO_OPEN"] ?? "<nil>")\n".utf8)
                .write(to: URL(fileURLWithPath: "/tmp/scribe_debug.log"))
        }
        #endif

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
        DispatchQueue.main.async {
            for url in autoOpen {
                ws.openFile(at: url)
            }
        }

        _prefs = StateObject(wrappedValue: preferences)
        _workspace = StateObject(wrappedValue: ws)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(workspace)
                .environmentObject(prefs)
                .frame(minWidth: 900, minHeight: 600)
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
                RecentFilesMenu(prefs: prefs, workspace: workspace)
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
            #if DEBUG
            CommandGroup(after: .windowList) {
                Divider()
                ScintillaProbeMenuItem()
            }
            #endif
        }

        Settings {
            SettingsView()
                .environmentObject(prefs)
        }

        #if DEBUG
        // Phase 1.7 — debug window for visually confirming ScintillaView
        // renders. Open via Window > Show Scintilla Probe (⌘⇧⌥P) or remove
        // along with ScintillaProbeMenuItem once CodeEditor is migrated.
        Window("Scintilla Probe", id: ScintillaProbeMenuItem.windowID) {
            ScintillaProbeView()
                .frame(minWidth: 600, minHeight: 400)
        }
        #endif
    }
}

#if DEBUG
/// Bridges `@Environment(\.openWindow)` (only available inside Views) into
/// the `commands` block of `ScribeApp`. Removed alongside the probe scene.
private struct ScintillaProbeMenuItem: View {
    static let windowID = "scintilla-probe"
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Scintilla Probe") {
            openWindow(id: Self.windowID)
        }
        .keyboardShortcut("p", modifiers: [.command, .shift, .option])
    }
}
#endif

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
