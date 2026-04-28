//
//  StatusBarView.swift
//  Bottom strip: language, encoding, line ending, cursor position.
//

import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            if let doc = workspace.current {
                DocumentStatusItems(doc: doc)
            } else {
                Text("Ready")
            }
            Spacer()
            if let doc = workspace.current, doc.isDirty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text("Modified")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }
}

/// Hairline vertical separator at the height the status bar uses.
/// Replaces SwiftUI `Divider` because Divider's auto-coloured fill
/// is heavier than the surrounding status text — the hairline
/// reads as a quiet beat between menu items, not a hard wall.
private struct StatusBarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.6))
            .frame(width: 1, height: 11)
    }
}

private struct DocumentStatusItems: View {
    @ObservedObject var doc: Document
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        languageMenu
        StatusBarSeparator()
        encodingMenu
        StatusBarSeparator()
        lineEndingMenu
        StatusBarSeparator()
        Text("Ln \(doc.cursorLine), Col \(doc.cursorColumn)")
            .monospacedDigit()
        StatusBarSeparator()
        Text("\(doc.text.count) chars")
            .monospacedDigit()
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
