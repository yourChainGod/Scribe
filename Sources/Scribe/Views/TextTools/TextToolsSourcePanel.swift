//
//  TextToolsSourcePanel.swift
//  Phase 40 — top "Source" pane of the Column Merger sheet.
//
//  Phase 38 carried a 3-segment "Selection / Document / Scratch"
//  picker — querulous, since "scratch" really just means "the
//  user typed in the editable textarea." Phase 40 cuts the
//  picker entirely:
//
//   • On open, the sheet auto-fills the textarea: with the active
//     editor selection if one exists, else the whole document.
//   • Two header icon buttons let the user reload the textarea
//     from either source on demand: ⤓ document / ✚ selection.
//   • Anything the user types into the textarea is the source —
//     no implicit mode, no surprise overwrites.
//
//  The split-mode picker lives directly under the textarea so the
//  user can see the source text and the parsing rule together.
//

import SwiftUI
import UniformTypeIdentifiers

struct TextToolsSourcePanel: View {
    @ObservedObject var model: TextToolsModel
    @EnvironmentObject private var workspace: Workspace
    var showsSplitControls: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TextToolsEditorFrame(text: $model.inputText,
                                 minHeight: 96)

            if model.hasImportedSources {
                importedBlock
            }

            if showsSplitControls {
                splitControls
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            TextToolsPanelTitle("textTools.source.title", systemImage: "doc.text")
            Text(L10n.t("textTools.source.summary",
                        lineCount, byteCountString))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button {
                model.inputText = workspace.current?.text ?? ""
                model.syncTokensWithColumnCount()
            } label: {
                Image(systemName: "doc.text.below.ecg")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("textTools.source.useDocument"))
            .disabled(workspace.current == nil)

            Button {
                model.inputText = workspace.activeTextSelection
                model.syncTokensWithColumnCount()
            } label: {
                Image(systemName: "selection.pin.in.out")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("textTools.source.useSelection"))
            .disabled(workspace.activeTextSelection.isEmpty)

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

    private var lineCount: Int {
        guard !model.inputText.isEmpty else { return 0 }
        return model.inputText.components(separatedBy: "\n").count
    }

    private var byteCountString: String {
        ByteCountFormatter.string(fromByteCount: Int64(model.inputText.utf8.count),
                                  countStyle: .file)
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
                                     minHeight: 70)
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
                        model.syncTokensWithColumnCount()
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

    // MARK: Split controls

    private var splitControls: some View {
        HStack(spacing: 8) {
            Text("textTools.split.kind", bundle: .module)
                .font(.system(size: 11, weight: .medium))
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
            .frame(width: 150)
            splitOption
            Spacer()
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var splitOption: some View {
        switch model.splitMode {
        case .csv, .tsv, .pipe, .whitespace:
            EmptyView()
        case .delimiter:
            inlineField(label: "textTools.split.delimiterField",
                        text: $model.delimiter,
                        width: 100)
        case .regex:
            inlineField(label: "textTools.split.regexField",
                        text: $model.regexPattern,
                        width: 180)
        case .fixedWidth:
            inlineField(label: "textTools.split.widthsField",
                        text: $model.fixedWidths,
                        width: 130)
        }
    }

    private func inlineField(label: LocalizedStringKey,
                             text: Binding<String>,
                             width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(label, bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }
}
