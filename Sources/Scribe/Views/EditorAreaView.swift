//
//  EditorAreaView.swift
//  The big text canvas. Backed by ScintillaCodeEditor since Phase 1.7c.
//

import SwiftUI

struct EditorAreaView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var prefs: EditorPreferences
    @EnvironmentObject var findState: FindState

    var body: some View {
        if let doc = workspace.current {
            VStack(spacing: 0) {
                if findState.isVisible {
                    FindBar(state: findState)
                }
                ScintillaCodeEditor(doc: doc, prefs: prefs, findState: findState)
                    .id(doc.id)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            WelcomeView()
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Scribe")
                .font(.system(size: 28, weight: .light))
            Text("A native macOS text editor.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("New") { workspace.newDocument() }
                    .keyboardShortcut("n")
                Button("Open…") { workspace.openDocument() }
                    .keyboardShortcut("o")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
