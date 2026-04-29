//
//  TextToolsCommon.swift
//  Phase 38 — shared visual primitives for the Text Tools workbench:
//  panel header, result preview, output button row, framed code-style
//  text editor. Each mode (Columns / Shuffle / Transform) reuses the
//  same building blocks so the three tabs feel like one tool, not
//  three independent screens.
//

import AppKit
import SwiftUI

enum TextToolsMetrics {
    /// Phase 40 — single-column layout. The Phase 38 dual-pane
    /// (920×600) made sense for three modes; with the merger as
    /// the only surface, a 720pt-wide vertical flow reads better
    /// (source → palette → composer → output) and gives chips
    /// more horizontal breathing room when the table has many
    /// columns.
    static let frameWidth: CGFloat = 720
    static let frameHeight: CGFloat = 620
    static let panelPadding: CGFloat = 16
    static let panelRadius: CGFloat = 8
    static let resultMinHeight: CGFloat = 130
}

/// Section header inside a panel (e.g. "Source", "Result"). Lives in
/// the leading edge of every mode panel; the trailing slot is filled
/// with mode-specific accessory content.
struct TextToolsPanelTitle: View {
    let titleKey: LocalizedStringKey
    let systemImage: String

    init(_ titleKey: LocalizedStringKey, systemImage: String) {
        self.titleKey = titleKey
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(titleKey, bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}

/// Monospaced text editor with the same rounded-frame chrome the
/// workbench uses everywhere. `editable=false` swaps in a read-only
/// .constant binding, which is the right behaviour for the result
/// surfaces — users should copy / replace, not type into the result.
struct TextToolsEditorFrame: View {
    @Binding var text: String
    var minHeight: CGFloat = 120
    var editable: Bool = true

    var body: some View {
        Group {
            if editable {
                TextEditor(text: $text)
            } else {
                TextEditor(text: .constant(text))
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(minHeight: minHeight)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        }
    }
}

/// Trailing button cluster: Copy / New Tab / Replace Selection /
/// Replace Document. Lives at the bottom of every mode pane. Pulled
/// out so all three modes pass exactly the same `result` and stay
/// behaviourally consistent.
struct TextToolsOutputButtons: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var findState: FindState
    let result: String

    var body: some View {
        HStack(spacing: 8) {
            Button {
                copyToClipboard(result)
            } label: {
                Label(L10n.t("textTools.output.copy"),
                      systemImage: "doc.on.doc")
            }
            .disabled(result.isEmpty)

            Button {
                openResultInNewTab(result)
            } label: {
                Label(L10n.t("textTools.output.newTab"),
                      systemImage: "plus.square.on.square")
            }
            .disabled(result.isEmpty)

            Button {
                replaceCurrentSelection(with: result)
            } label: {
                Label(L10n.t("textTools.output.replaceSelection"),
                      systemImage: "text.cursor")
            }
            .disabled(workspace.activeTextSelection.isEmpty || result.isEmpty)

            Spacer()

            Button {
                replaceCurrentDocument(with: result)
            } label: {
                Label(L10n.t("textTools.output.replaceDocument"),
                      systemImage: "doc.text")
            }
            .buttonStyle(.borderedProminent)
            .disabled(workspace.current == nil || result.isEmpty)
        }
        .controlSize(.small)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func openResultInNewTab(_ text: String) {
        let doc = Document(title: L10n.t("textTools.output.resultTabTitle"),
                           text: text)
        doc.isDirty = true
        workspace.documents.append(doc)
        workspace.selectedID = doc.id
        workspace.isTextToolsPresented = false
    }

    private func replaceCurrentSelection(with text: String) {
        findState.commands.send(.replaceSelectionText(text))
        workspace.isTextToolsPresented = false
    }

    private func replaceCurrentDocument(with text: String) {
        guard let doc = workspace.current else { return }
        doc.text = text
        doc.isDirty = true
        workspace.isTextToolsPresented = false
    }
}

/// Subtle pill-shaped warning the columns mode shows when the
/// imported sources have a different row count from the primary
/// source. Visual signal only — the join still runs, missing cells
/// just render empty.
struct TextToolsRowMismatchBadge: View {
    let primary: Int
    let imported: Int

    var body: some View {
        Text(L10n.t("textTools.source.rowMismatch", primary, imported))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.13),
                        in: Capsule(style: .continuous))
            .help(L10n.t("textTools.source.rowMismatch.help"))
    }
}
