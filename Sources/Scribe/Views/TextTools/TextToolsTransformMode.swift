//
//  TextToolsTransformMode.swift
//  Phase 38 — right-hand operation pane for the "Transform" mode
//  of the Text Tools workbench. A preset picker (URL / Base64 /
//  HTML / JSON / base conversions), an inline error banner if the
//  preset throws on the current source, then the shared result +
//  output cluster.
//

import SwiftUI

struct TextToolsTransformMode: View {
    @ObservedObject var model: TextToolsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextToolsPanelTitle("textTools.transform.title", systemImage: "wand.and.stars")

            LabeledContent {
                Picker("", selection: $model.transformPreset) {
                    ForEach(TextToolsTransformPreset.allCases) { preset in
                        Text(preset.titleKey, bundle: .module).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            } label: {
                Text("textTools.transform.operation", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let errorKey = model.transformErrorKey {
                Label {
                    Text(LocalizedStringKey(errorKey), bundle: .module)
                        .font(.system(size: 12))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .background(Color.red.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Divider()
                .padding(.vertical, 2)

            TextToolsResultPanel(result: model.transformResult)
            TextToolsOutputButtons(result: model.transformResult)
        }
        .padding(TextToolsMetrics.panelPadding)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
