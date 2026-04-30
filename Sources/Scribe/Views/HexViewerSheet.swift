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
}

struct HexViewerSheet: View {
    let request: HexViewerRequest
    let onClose: () -> Void

    var body: some View {
        let dump = HexView.dump(request.data)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("hexview.title", bundle: .module)
                    .font(.headline)
                Text(verbatim: request.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                    .textSelection(.enabled)
            }
            .frame(minWidth: 720, minHeight: 360)
            .background(Color(NSColor.textBackgroundColor))
            .border(Color.secondary.opacity(0.3))
        }
        .padding(20)
        .frame(width: 800, height: 520)
    }
}
