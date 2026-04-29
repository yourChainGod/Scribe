//
//  TextToolsLiveOutput.swift
//  Phase 40c — live result + output buttons cluster.
//
//  Renders a *truncated* preview of the current ColumnRecipe to
//  keep big inputs interactive. The preview cap (20 rows) lives
//  on the model as `outputPreviewLineLimit`. The Copy / New Tab /
//  Replace Selection / Replace Document buttons all still reach
//  for the full `model.columnResult` — only the visible textarea
//  uses `columnResultPreview`.
//

import SwiftUI

struct TextToolsLiveOutput: View {
    @ObservedObject var model: TextToolsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            TextToolsEditorFrame(text: .constant(model.columnResultPreview),
                                 minHeight: TextToolsMetrics.resultMinHeight,
                                 editable: false)
            if isTruncated {
                truncationFooter
            }
            TextToolsOutputButtons(result: model.columnResult)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextToolsPanelTitle("textTools.live.title", systemImage: "bolt.horizontal")
            Spacer()
            Text(L10n.t("textTools.live.summary",
                        previewLineCount,
                        totalLineCount,
                        formattedByteSize))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Inline footer that shows up only when the preview is a
    /// strict subset of the full output. Reassures the user that
    /// "the rest" is real and will go through Copy / Replace, not
    /// dropped on the floor.
    private var truncationFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(L10n.t("textTools.live.truncated",
                        totalLineCount - previewLineCount))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var previewLineCount: Int {
        min(totalLineCount, model.outputPreviewLineLimit)
    }

    private var totalLineCount: Int {
        model.totalRowCount
    }

    private var isTruncated: Bool {
        totalLineCount > model.outputPreviewLineLimit
    }

    private var formattedByteSize: String {
        // Estimate full-result byte size cheaply by inflating the
        // preview's per-row average over the total row count.
        let preview = model.columnResultPreview
        guard !preview.isEmpty else { return "0 B" }
        let previewBytes = preview.utf8.count
        guard previewLineCount > 0 else { return "0 B" }
        let perRow = Double(previewBytes) / Double(previewLineCount)
        let estimated = Int64(perRow * Double(totalLineCount))
        return ByteCountFormatter.string(fromByteCount: max(0, estimated),
                                         countStyle: .file)
    }
}
