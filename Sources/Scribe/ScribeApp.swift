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
        // SwiftPM-built executables default to background activation policy.
        // Force regular UI app so the window actually appears in Dock + foreground.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        // Build prefs first, then inject into Workspace. Both are reference
        // types, so the Workspace keeps a stable reference even though
        // SwiftUI may invoke this initializer repeatedly.
        let preferences = EditorPreferences()
        _prefs = StateObject(wrappedValue: preferences)
        _workspace = StateObject(wrappedValue: Workspace(prefs: preferences))
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
        .handlesExternalEvents(matching: ["*"])
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
