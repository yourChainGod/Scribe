//
//  TextToolsWorkbench.swift
//  Phase 38 — host shell of the split / merge / shuffle / transform
//  workbench sheet. Owns the shared TextToolsModel and routes to the
//  three mode panes (Columns / Shuffle / Transform) below the mode
//  picker. The 1002-line monolith from Phase 37 is now broken into
//  six focused files under Sources/Scribe/Views/TextTools/.
//

import SwiftUI

struct TextToolsWorkbench: View {
    @EnvironmentObject private var workspace: Workspace
    @StateObject private var model = TextToolsModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modePicker
            Divider()
            modeBody
        }
        .frame(width: TextToolsMetrics.frameWidth,
               height: TextToolsMetrics.frameHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.mode = workspace.textToolsMode
            model.seedInitialText(workspace: workspace)
        }
        .onChange(of: model.mode) { _, mode in
            workspace.textToolsMode = mode
        }
        .onChange(of: workspace.textToolsMode) { _, mode in
            model.mode = mode
        }
        .onChange(of: model.columnCount) { _, count in
            model.syncColumnState(columnCount: count)
        }
    }

    // MARK: Header

    /// Compact 40pt header — single row with title, subtitle, and a
    /// close button. The Phase 37 header used a 30pt accent icon and
    /// stacked title/subtitle, which felt heavy for what is, at the
    /// end of the day, a utilities sheet.
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

    // MARK: Mode picker

    private var modePicker: some View {
        HStack {
            Picker("", selection: $model.mode) {
                Text("textTools.mode.columns", bundle: .module).tag(TextToolsMode.columns)
                Text("textTools.mode.shuffle", bundle: .module).tag(TextToolsMode.shuffle)
                Text("textTools.mode.transform", bundle: .module).tag(TextToolsMode.transform)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Mode body

    @ViewBuilder
    private var modeBody: some View {
        HSplitView {
            TextToolsSourcePanel(model: model,
                                 showsSplitControls: model.mode == .columns)
                .frame(minWidth: 320, idealWidth: 380)

            switch model.mode {
            case .columns:
                TextToolsColumnsMode(model: model)
                    .frame(minWidth: 480, idealWidth: 540)
            case .shuffle:
                TextToolsShuffleMode(model: model)
                    .frame(minWidth: 360, idealWidth: 420)
            case .transform:
                TextToolsTransformMode(model: model)
                    .frame(minWidth: 360, idealWidth: 420)
            }
        }
    }
}
