//
//  StatusBarView.swift
//  Bottom strip: language, encoding, line ending, cursor position.
//

import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var workspace: Workspace
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        HStack(spacing: 10) {
            if let doc = workspace.current {
                DocumentStatusItems(doc: doc)
            } else {
                Text("status.ready", bundle: .module)
            }
            Spacer()
            // Phase 34b/c — large-file load + save banner. Sits on the
            // right before the dirty marker so a user reading
            // "modified" alongside a still-streaming doc gets the
            // priority cue (in-flight bytes aren't your edit yet)
            // first. We render save before load because save fully
            // gates user input (no chunk acks during ⌘S), whereas
            // load is followed by a normal editing window.
            if let doc = workspace.current,
               doc.isLargeFile,
               doc.saveProgress >= 0 {
                StatusBarIndicator {
                    ProgressView(value: max(0, min(1, doc.saveProgress)))
                        .controlSize(.small)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text("status.largeFileSaving", bundle: .module)
                }
            } else if let doc = workspace.current,
                      doc.isLargeFile,
                      doc.loadProgress >= 0,
                      doc.loadProgress < 1 {
                StatusBarIndicator {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7, anchor: .center)
                        .frame(width: 12, height: 12)
                    Text("status.largeFileLoading", bundle: .module)
                }
            } else if let doc = workspace.current, doc.isDirty {
                StatusBarIndicator {
                    Circle()
                        .fill(appTheme.accent)
                        .frame(width: 6, height: 6)
                    Text("status.modified", bundle: .module)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(appTheme.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(appTheme.barBackground)
    }
}

private struct StatusBarIndicator<Content: View>: View {
    let content: Content
    @Environment(\.appTheme) private var appTheme

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 5) {
            content
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(appTheme.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(appTheme.secondaryText.opacity(0.10))
        )
    }
}

/// Hairline vertical separator at the height the status bar uses.
/// Replaces SwiftUI `Divider` because Divider's auto-coloured fill
/// is heavier than the surrounding status text — the hairline
/// reads as a quiet beat between menu items, not a hard wall.
private struct StatusBarSeparator: View {
    @Environment(\.appTheme) private var appTheme
    var body: some View {
        Rectangle()
            .fill(appTheme.separator.opacity(0.6))
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
        // Phase 34c — large-file documents have an empty `doc.text`
        // (the bytes live on the C++ side via SCI_SETDOCPOINTER), so
        // a literal `doc.text.count` would always read "0 chars" and
        // mislead the user. Instead surface the on-disk file size in
        // a human-readable form; that's the number a user opening a
        // multi-GB log actually wants confirmed.
        if doc.isLargeFile, let url = doc.url {
            Text(largeFileSizeLabel(for: url))
                .monospacedDigit()
        } else {
            Text(L10n.t("status.charCount", doc.text.count))
                .monospacedDigit()
        }
    }

    /// Render `url`'s on-disk size as e.g. "128 MB" / "1.5 GB". We
    /// stat() once per body redraw — cheap by every yardstick (a
    /// single resourceValues call) and avoids piping the value
    /// through Document state for what is fundamentally derived
    /// data. Falls back to the i18n "large" label if the stat fails.
    private func largeFileSizeLabel(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey])
            .fileSize) ?? 0
        if size == 0 {
            return L10n.t("status.largeFile")
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
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
