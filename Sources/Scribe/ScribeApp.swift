//
//  ScribeApp.swift
//  Scribe — A native macOS text editor.
//

import SwiftUI
import AppKit

@main
struct ScribeApp: App {
    @StateObject private var workspace = Workspace()

    init() {
        // SwiftPM-built executables default to background activation policy.
        // Force regular UI app so the window actually appears in Dock + foreground.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(workspace)
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
            }
            CommandGroup(after: .saveItem) {
                Button("Save") { workspace.saveCurrent() }
                    .keyboardShortcut("s")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(workspace)
        }
    }
}
