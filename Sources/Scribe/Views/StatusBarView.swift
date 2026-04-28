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
                Text("status.ready", bundle: .module)
            }
            Spacer()
            // Phase 34b — large-file load banner. Sits on the right
            // before the dirty marker so a user reading "modified"
            // alongside a still-loading doc gets the priority cue
            // (loading = the bytes aren't your edit yet) first.
            if let doc = workspace.current,
               doc.isLargeFile,
               doc.loadProgress >= 0,
               doc.loadProgress < 1 {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7, anchor: .center)
                        .frame(width: 12, height: 12)
                    Text("status.largeFileLoading", bundle: .module)
                        .foregroundStyle(.secondary)
                }
            } else if let doc = workspace.current, doc.isDirty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text("status.modified", bundle: .module)
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
        Text(L10n.t("status.lineCol", doc.cursorLine, doc.cursorColumn))
            .monospacedDigit()
        StatusBarSeparator()
        Text(L10n.t("status.charCount", doc.text.count))
            .monospacedDigit()
    }

    private var languageMenu: some View {
        Menu {
            Section {
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
            } header: {
                Text("status.menu.syntax", bundle: .module)
            }
            if doc.lexerOverride != nil {
                Divider()
                Button {
                    doc.lexerOverride = nil
                } label: {
                    Text("status.menu.resetAuto", bundle: .module)
                }
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
                Section {
                    ForEach(TextEncoding.allCases) { enc in
                        Button(enc.displayName) { workspace.reopen(doc: doc, as: enc) }
                    }
                } header: {
                    Text("status.menu.reopenEncoding", bundle: .module)
                }
            }
            Section {
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
            } header: {
                Text("status.menu.saveEncoding", bundle: .module)
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
