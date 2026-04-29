//
//  TextToolsSourcePanel.swift
//  Phase 38 — left-hand "Source" panel of the Text Tools workbench.
//  Owns the scope picker, the source text editor, and the imported-
//  files merge controls. Reused by every mode (columns / shuffle /
//  transform); columns mode appends its split-mode picker below by
//  setting `showsSplitControls=true` so the user can see the parsing
//  rule and the source text in the same place.
//

import SwiftUI
import UniformTypeIdentifiers

struct TextToolsSourcePanel: View {
    @ObservedObject var model: TextToolsModel
    @EnvironmentObject private var workspace: Workspace
    var showsSplitControls: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            scopePicker

            TextToolsEditorFrame(text: $model.inputText,
                                 minHeight: 180)

            if model.hasImportedSources {
                importedBlock
            }

            if showsSplitControls {
                splitControls
            }
        }
        .padding(TextToolsMetrics.panelPadding)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            TextToolsPanelTitle("textTools.source.title", systemImage: "doc.text")
            Spacer()
            Button {
                model.seedInitialText(workspace: workspace, force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("textTools.source.refresh"))

            Button {
                model.importTextFromDisk()
            } label: {
                Image(systemName: "doc.badge.plus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("textTools.source.import.help"))
        }
    }

    // MARK: Scope

    private var scopePicker: some View {
        Picker("", selection: $model.sourceScope) {
            Text("textTools.source.selection", bundle: .module).tag(TextToolsSourceScope.selection)
            Text("textTools.source.document", bundle: .module).tag(TextToolsSourceScope.document)
            Text("textTools.source.manual", bundle: .module).tag(TextToolsSourceScope.manual)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: model.sourceScope) { _, _ in
            model.applySourceScope(workspace: workspace, force: true)
        }
    }

    // MARK: Imported sources

    private var importedBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: $model.includeImportedText) {
                    Text("textTools.source.includeImported", bundle: .module)
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                Spacer()
                if model.importedRowMismatch {
                    TextToolsRowMismatchBadge(primary: model.primaryTable.rowCount,
                                              imported: model.importedTable.rowCount)
                }
            }

            if model.includeImportedText {
                joinControls
            }

            if !model.importedSources.isEmpty {
                importedSourceList
            }

            if !model.importedText.isEmpty {
                TextToolsEditorFrame(text: $model.importedText,
                                     minHeight: 80)
            }
        }
    }

    private var joinControls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.importedJoinMode) {
                Text("textTools.source.joinByRow", bundle: .module).tag(TextToolsImportedJoinMode.rows)
                Text("textTools.source.joinByKey", bundle: .module).tag(TextToolsImportedJoinMode.key)
            }
            .pickerStyle(.segmented)
            .frame(width: 176)

            if model.importedJoinMode == .key {
                LabeledContent {
                    TextField("", text: $model.keyColumnText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 54)
                } label: {
                    Text("textTools.source.keyColumn", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .controlSize(.small)
    }

    private var importedSourceList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.importedSources) { source in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(source.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(L10n.t("textTools.source.rows",
                                TextTableSplitter.split(source.text, strategy: model.splitStrategy).rowCount))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button {
                        model.importedSources.removeAll { $0.id == source.id }
                        model.includeImportedText = model.hasImportedSources
                        model.syncColumnState(columnCount: model.columnCount)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("common.close"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    // MARK: Split controls (columns mode only)

    private var splitControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("textTools.split.kind", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.splitMode) {
                    Text("textTools.split.csv", bundle: .module).tag(TextToolsSplitMode.csv)
                    Text("textTools.split.tsv", bundle: .module).tag(TextToolsSplitMode.tsv)
                    Text("textTools.split.pipe", bundle: .module).tag(TextToolsSplitMode.pipe)
                    Text("textTools.split.delimiter", bundle: .module).tag(TextToolsSplitMode.delimiter)
                    Text("textTools.split.whitespace", bundle: .module).tag(TextToolsSplitMode.whitespace)
                    Text("textTools.split.regex", bundle: .module).tag(TextToolsSplitMode.regex)
                    Text("textTools.split.fixedWidth", bundle: .module).tag(TextToolsSplitMode.fixedWidth)
                }
                .labelsHidden()
                .frame(width: 170)
                Spacer()
            }
            splitOption
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var splitOption: some View {
        switch model.splitMode {
        case .csv, .tsv, .pipe, .whitespace:
            EmptyView()
        case .delimiter:
            inlineField(label: "textTools.split.delimiterField",
                        text: $model.delimiter,
                        width: 140)
        case .regex:
            inlineField(label: "textTools.split.regexField",
                        text: $model.regexPattern,
                        width: 220)
        case .fixedWidth:
            inlineField(label: "textTools.split.widthsField",
                        text: $model.fixedWidths,
                        width: 170)
        }
    }

    private func inlineField(label: LocalizedStringKey,
                             text: Binding<String>,
                             width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(label, bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }
}
