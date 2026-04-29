//
//  TextToolsWorkbench.swift
//  Phase 40 — host shell of the column merger sheet.
//
//  Phase 38 had three modes (columns / shuffle / transform) and a
//  HSplitView that placed Source on the left and the active mode
//  pane on the right (920×600). Phase 40 collapses the workbench
//  to a single mode — line shuffle and base/encoding transforms
//  live exclusively in the editor's right-click ▸ Transform
//  submenu — and reorganises the surface as a single vertical
//  flow that mirrors the data path:
//
//      ┌─ Source (textarea, split-mode) ─┐
//      │                                  │
//      ├─ Column palette (chip grid) ────┤
//      │                                  │
//      ├─ Token composer (chip bar) ─────┤
//      │                                  │
//      ├─ Live output ───────────────────┤
//      │                                  │
//      └─ Output buttons row ────────────┘
//
//  The whole stack lives inside a ScrollView so smaller windows
//  / many imported sources still degrade gracefully.
//

import SwiftUI

struct TextToolsWorkbench: View {
    @EnvironmentObject private var workspace: Workspace
    @StateObject private var model = TextToolsModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextToolsSourcePanel(model: model,
                                         showsSplitControls: true)
                    Divider()
                    TextToolsTokenComposer(model: model)
                    Divider()
                    TextToolsLiveOutput(model: model)
                }
                .padding(TextToolsMetrics.panelPadding)
            }
        }
        .frame(width: TextToolsMetrics.frameWidth,
               height: TextToolsMetrics.frameHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.seedInitialText(workspace: workspace)
        }
        .onChange(of: model.columnCount) { _, _ in
            model.syncTokensWithColumnCount()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tablecells")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("textTools.title", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                Text("textTools.subtitle", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                workspace.isTextToolsPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("common.cancel"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
