//
//  StatusBarView.swift
//  Bottom strip: language, encoding, line ending, cursor position.
//

import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 12) {
            if let doc = workspace.current {
                DocumentStatusItems(doc: doc)
            } else {
                Text("Ready")
            }
            Spacer()
            if let doc = workspace.current, doc.isDirty {
                Label("Modified", systemImage: "circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
    }

}

private struct DocumentStatusItems: View {
    @ObservedObject var doc: Document
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        languageMenu
        Divider().frame(height: 12)
        encodingMenu
        Divider().frame(height: 12)
        lineEndingMenu
        Divider().frame(height: 12)
        Text("Ln \(doc.cursorLine), Col \(doc.cursorColumn)")
            .monospacedDigit()
        Divider().frame(height: 12)
        Text("\(doc.text.count) chars")
    }

    private var languageMenu: some View {
        Menu {
            Section("Syntax Highlighting") {
                ForEach(LexerCatalog.all, id: \.lexillaName) { lex in
                    Button {
                        // nil ⇒ auto by extension; otherwise pin a specific lexer.
                        doc.lexerOverride = lex.lexillaName == LexerCatalog.descriptor(forExtension: doc.url?.pathExtension ?? "").lexillaName
                            ? nil
                            : lex.lexillaName
                    } label: {
                        if LexerCatalog.descriptor(for: doc).lexillaName == lex.lexillaName {
                            Label(lex.display, systemImage: "checkmark")
                        } else {
                            Text(lex.display)
                        }
                    }
                }
            }
            if doc.lexerOverride != nil {
                Divider()
                Button("Reset to Auto Detect") { doc.lexerOverride = nil }
            }
        } label: {
            Label(LexerCatalog.descriptor(for: doc).display,
                  systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var encodingMenu: some View {
        Menu {
            if doc.url != nil {
                Section("Reopen with Encoding") {
                    ForEach(TextEncoding.allCases) { enc in
                        Button(enc.displayName) { workspace.reopen(doc: doc, as: enc) }
                    }
                }
            }
            Section("Save with Encoding") {
                ForEach(TextEncoding.allCases) { enc in
                    Button {
                        workspace.setEncoding(of: doc, to: enc)
                    } label: {
                        if doc.encoding == enc {
                            Label(enc.displayName, systemImage: "checkmark")
                        } else {
                            Text(enc.displayName)
                        }
                    }
                }
            }
        } label: {
            Text(doc.encoding.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var lineEndingMenu: some View {
        Menu {
            ForEach(LineEnding.allCases) { ending in
                Button {
                    workspace.setLineEnding(of: doc, to: ending)
                } label: {
                    if doc.lineEnding == ending {
                        Label(ending.rawValue, systemImage: "checkmark")
                    } else {
                        Text(ending.rawValue)
                    }
                }
            }
        } label: {
            Text(doc.lineEnding.short)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
