//
//  EditorAreaView.swift
//  The big text canvas. Phase 0: SwiftUI TextEditor placeholder.
//  Phase 1 will replace this with a Scintilla-backed NSViewRepresentable.
//

import SwiftUI

struct EditorAreaView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var prefs: EditorPreferences

    /// Phase 1.7 hatch: launch with `SCRIBE_USE_SCINTILLA=1 swift run Scribe`
    /// to swap the legacy NSTextView-backed CodeEditor for the new
    /// Scintilla-backed `ScintillaCodeEditor`. Production code path is
    /// unaffected. Will be removed when the migration is complete.
    private var useScintilla: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SCRIBE_USE_SCINTILLA"] == "1"
        #else
        false
        #endif
    }

    var body: some View {
        if let doc = workspace.current {
            EditorTextView(doc: doc, prefs: prefs, useScintilla: useScintilla)
                .id(doc.id)
        } else {
            WelcomeView()
        }
    }
}

private struct EditorTextView: View {
    @ObservedObject var doc: Document
    @ObservedObject var prefs: EditorPreferences
    let useScintilla: Bool

    var body: some View {
        Group {
            if useScintilla {
                ScintillaCodeEditor(doc: doc, prefs: prefs)
            } else {
                CodeEditor(doc: doc, prefs: prefs)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
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
