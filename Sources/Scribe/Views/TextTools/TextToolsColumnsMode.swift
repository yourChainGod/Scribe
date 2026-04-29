//
//  TextToolsColumnsMode.swift
//  Phase 38b — vertical column-row list redesign.
//
//  The Phase 38a horizontal chip strip suffered from compression:
//  three chips with sample text quickly hid the rest, drag-reorder
//  was non-obvious, and selection/order shared one capsule. This
//  rewrite uses the more familiar vertical row pattern:
//
//      ≡  ☑  第 1 列   sample data…
//      ≡  ☐  第 2 列   sample data…
//
//  ≡   = drag handle (whole row drags to reorder)
//  ☑/☐ = include / exclude this column in the recipe
//  Below the list sits a compact one-row recipe (前缀 / 列间 /
//  后缀 / 缺失) that answers the user's "do I add something to
//  each row?" question in plain language. Below that lives the
//  preview table (now narrower per cell so 5–6 columns fit), then
//  the result + output cluster.
//

import SwiftUI
import UniformTypeIdentifiers

struct TextToolsColumnsMode: View {
    @ObservedObject var model: TextToolsModel
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            columnList
            recipeRow
            previewSection
            resultSection
            TextToolsOutputButtons(result: model.columnResult)
        }
        .padding(TextToolsMetrics.panelPadding)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Column list

    private var columnList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextToolsPanelTitle("textTools.columns.title", systemImage: "list.bullet.indent")
                Spacer()
                Text(L10n.t("textTools.columns.summary",
                            model.selectedColumns.count,
                            model.columnCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if model.columnCount > 0 {
                    Button {
                        toggleAll()
                    } label: {
                        Text(allSelected
                             ? L10n.t("textTools.columns.deselectAll")
                             : L10n.t("textTools.columns.selectAll"))
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }
            }

            if model.columnCount == 0 {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.columnOrder, id: \.self) { index in
                            columnRow(for: index)
                                .onDrag {
                                    model.draggingColumn = index
                                    return NSItemProvider(object: "\(index)" as NSString)
                                }
                                .onDrop(of: [UTType.text],
                                        delegate: TextToolsColumnRowDropDelegate(
                                            target: index,
                                            order: $model.columnOrder,
                                            draggingColumn: $model.draggingColumn))
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "tablecells.badge.ellipsis")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                Text("textTools.columns.empty", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 16)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func columnRow(for index: Int) -> some View {
        let selected = model.selectedColumns.contains(index)
        let position = (model.columnOrder.firstIndex(of: index) ?? 0) + 1
        let dragging = model.draggingColumn == index

        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Toggle(isOn: Binding(
                get: { selected },
                set: { isOn in
                    if isOn { model.selectedColumns.insert(index) }
                    else { model.selectedColumns.remove(index) }
                }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text(L10n.t("textTools.column.position",
                        position,
                        index + 1))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 96, alignment: .leading)

            Text(model.sample(forColumn: index).isEmpty
                 ? L10n.t("textTools.column.noSample")
                 : model.sample(forColumn: index))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(model.sample(forColumn: index).isEmpty
                                 ? Color.secondary.opacity(0.5)
                                 : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground(selected: selected, dragging: dragging))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.30) : Color.clear,
                        lineWidth: 1)
        }
        .contentShape(Rectangle())
        .opacity(dragging ? 0.45 : 1)
        .help(L10n.t("textTools.columns.dragHelp"))
        .accessibilityLabel(L10n.t("textTools.accessibility.columnToggle", index + 1))
    }

    private func rowBackground(selected: Bool, dragging: Bool) -> Color {
        if dragging { return Color.accentColor.opacity(0.10) }
        if selected { return Color.accentColor.opacity(0.08) }
        return Color.primary.opacity(0.04)
    }

    private var allSelected: Bool {
        model.columnCount > 0 && model.selectedColumns.count == model.columnCount
    }

    private func toggleAll() {
        if allSelected {
            model.selectedColumns.removeAll()
        } else {
            model.selectedColumns = Set(0..<model.columnCount)
        }
    }

    // MARK: Recipe row

    private var recipeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("textTools.recipe.title", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.importedRowMismatch {
                    TextToolsRowMismatchBadge(primary: model.primaryTable.rowCount,
                                              imported: model.importedTable.rowCount)
                }
            }
            HStack(spacing: 10) {
                recipeField("textTools.recipe.prefix", text: $model.prefixText, placeholder: "")
                recipeField("textTools.recipe.between", text: $model.joinDelimiter, placeholder: ", ")
                recipeField("textTools.recipe.suffix", text: $model.suffixText, placeholder: "")
                recipeField("textTools.recipe.missing", text: $model.missingCellPlaceholder, placeholder: "")
            }
            recipeTemplate
        }
    }

    private func recipeField(_ key: LocalizedStringKey,
                             text: Binding<String>,
                             placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key, bundle: .module)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
    }

    /// Inline preview of the row template the recipe will produce
    /// — gives the user a one-glance answer to "what does my row
    /// look like?" without scrolling to the result panel.
    private var recipeTemplate: some View {
        HStack(spacing: 4) {
            Text("textTools.recipe.template", bundle: .module)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(templateString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Spacer()
        }
    }

    private var templateString: String {
        let cols = model.orderedSelectedColumns
        if cols.isEmpty { return L10n.t("textTools.recipe.template.empty") }
        let between = model.joinDelimiter.isEmpty ? "" : model.joinDelimiter
        let body = cols.enumerated()
            .map { offset, idx in
                let label = "{\(idx + 1)}"
                return offset == 0 ? label : between + label
            }
            .joined()
        return model.prefixText + body + model.suffixText
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("textTools.preview.title", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.table.rowCount > 0 {
                    Text(L10n.t("textTools.preview.summary",
                                min(model.table.rowCount, model.previewRowLimit),
                                model.table.rowCount))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            previewTable
                .frame(minHeight: 110, maxHeight: 150)
        }
    }

    private var previewTable: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 1) {
                    rowHeaderCell("#", isHeader: true)
                    ForEach(0..<max(model.columnCount, 1), id: \.self) { col in
                        tableCell(col < model.columnCount
                                  ? L10n.t("textTools.column.short", col + 1)
                                  : L10n.t("textTools.column.empty"),
                                  isHeader: true,
                                  selected: model.selectedColumns.contains(col))
                    }
                }
                ForEach(Array(model.table.rows.prefix(model.previewRowLimit).enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 1) {
                        rowHeaderCell("\(rowIndex + 1)")
                        ForEach(0..<max(model.columnCount, 1), id: \.self) { col in
                            tableCell(row.indices.contains(col) ? row[col] : "",
                                      selected: model.selectedColumns.contains(col))
                        }
                    }
                }
            }
            .padding(1)
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func tableCell(_ text: String,
                           isHeader: Bool = false,
                           selected: Bool = false) -> some View {
        let bg: Color = {
            if isHeader { return selected ? Color.accentColor.opacity(0.18) : Color.accentColor.opacity(0.10) }
            if selected { return Color.accentColor.opacity(0.05) }
            return Color(nsColor: .textBackgroundColor)
        }()
        return Text(text.isEmpty ? " " : text)
            .font(.system(size: 11, weight: isHeader ? .semibold : .regular, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: 84, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(bg)
    }

    private func rowHeaderCell(_ text: String, isHeader: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: isHeader ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 32, alignment: .trailing)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isHeader ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
    }

    // MARK: Result

    private var resultSection: some View {
        TextToolsResultPanel(result: model.columnResult)
    }
}

/// Drop delegate for the vertical column row list. Same semantics
/// as the old chip-strip delegate but anchored to a vertical list,
/// which is what users expect for "drag to reorder rows."
struct TextToolsColumnRowDropDelegate: DropDelegate {
    let target: Int
    @Binding var order: [Int]
    @Binding var draggingColumn: Int?

    func dropEntered(info: DropInfo) {
        guard let draggingColumn,
              draggingColumn != target,
              let from = order.firstIndex(of: draggingColumn),
              let to = order.firstIndex(of: target) else { return }

        withAnimation(.easeOut(duration: 0.12)) {
            order.move(fromOffsets: IndexSet(integer: from),
                       toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingColumn = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
