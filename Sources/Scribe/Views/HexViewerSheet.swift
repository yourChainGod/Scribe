//
//  HexViewerSheet.swift
//  Phase 44 — Read-only hex dump of the current document. Displays
//  the classic three-column xxd-style layout (offset / hex / ASCII)
//  in a monospaced scrollable view.
//
//  The sheet doesn't reach into Scintilla — it captures `doc.text`
//  as UTF-8 bytes at open time and re-derives only when the user
//  asks (re-open). This keeps the path immune to mid-frame edit
//  races.
//

import SwiftUI

struct HexViewerRequest: Identifiable, Equatable {
    let id: UUID
    let title: String
    let data: Data

    init(title: String, data: Data, id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.data = data
    }

    @MainActor
    static func currentDocument(workspace: Workspace,
                                selectionTitleFormat: String = L10n.t("hexview.selectionTitle")) -> HexViewerRequest? {
        guard let doc = workspace.current else { return nil }
        let selection = workspace.activeTextSelection
        let source = selection.isEmpty ? doc.text : selection
        let title = selection.isEmpty
            ? doc.title
            : String(format: selectionTitleFormat, doc.title)
        return HexViewerRequest(title: title, data: Data(source.utf8))
    }
}

struct HexViewerSheet: View {
    let request: HexViewerRequest
    let onClose: () -> Void
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        let dump = HexView.dump(request.data)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("hexview.title", bundle: .module)
                    .font(.headline)
                    .foregroundStyle(appTheme.primaryText)
                Text(verbatim: request.title)
                    .font(.subheadline)
                    .foregroundStyle(appTheme.secondaryText)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Text("button.close", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 16) {
                Text(L10n.t("hexview.size", dump.originalByteCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(appTheme.secondaryText)
                if dump.truncated {
                    Text(L10n.t("hexview.truncated", dump.dumpedByteCount))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: dump.text.isEmpty ? "(empty)" : dump.text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(0)
                    .padding(8)
                    .foregroundStyle(appTheme.primaryText)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 720, minHeight: 360)
            .background(appTheme.codeSurface)
            .border(appTheme.chromeBorder)
        }
        .padding(20)
        .frame(width: 800, height: 520)
        .background(appTheme.windowBackground)
    }
}
