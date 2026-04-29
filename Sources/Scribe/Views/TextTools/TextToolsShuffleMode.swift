//
//  TextToolsShuffleMode.swift
//  Phase 38 — right-hand operation pane for the "Shuffle" mode of
//  the Text Tools workbench. Two checkboxes (preserve first line /
//  preserve blank line positions) plus a deterministic seed input,
//  then the shared result + output cluster.
//

import SwiftUI

struct TextToolsShuffleMode: View {
    @ObservedObject var model: TextToolsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextToolsPanelTitle("textTools.shuffle.title", systemImage: "shuffle")

            Toggle(isOn: $model.preserveFirstLine) {
                Text("textTools.shuffle.preserveFirstLine", bundle: .module)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $model.preserveBlankLinePositions) {
                Text("textTools.shuffle.preserveBlankLines", bundle: .module)
            }
            .toggleStyle(.checkbox)

            seedRow

            Divider()
                .padding(.vertical, 2)

            TextToolsResultPanel(result: model.shuffleResult)
            TextToolsOutputButtons(result: model.shuffleResult)
        }
        .padding(TextToolsMetrics.panelPadding)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var seedRow: some View {
        HStack(spacing: 8) {
            LabeledContent {
                TextField("", text: $model.shuffleSeed)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            } label: {
                Text("textTools.shuffle.seed", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Button {
                model.shuffleSeed = String(UInt64.random(in: 1...UInt64.max))
            } label: {
                Image(systemName: "die.face.5")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("textTools.shuffle.randomSeed"))
            Spacer()
        }
    }
}
