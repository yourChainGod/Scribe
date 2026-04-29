//
//  TextToolsModel.swift
//  Phase 40 — single-mode "Column Merger" model.
//
//  The Phase 38 model carried state for three modes (columns /
//  shuffle / transform). Phase 40 collapses the workbench down to
//  the merger only — line shuffle and base / encoding transforms
//  already live in the editor's right-click ▸ Transform submenu,
//  so duplicating them here was redundant. The redesigned UI is a
//  Token Composer: a horizontal bar of draggable chips where
//  every chip is either a `.column(idx)` reference or a `.literal
//  (text)` snippet. The chip list maps 1:1 onto the existing
//  ColumnRecipePart pipeline, so rendering still goes through
//  ColumnRecipe.render(table:).
//
//  Removed fields (vs Phase 38):
//    mode, preserveFirstLine, preserveBlankLinePositions,
//    shuffleSeed, transformPreset, selectedColumns, columnOrder,
//    draggingColumn, prefixText, suffixText, joinDelimiter
//
//  New field:
//    tokens: [ColumnToken] — drives the entire output
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared enums / value types

enum TextToolsSplitMode: String, CaseIterable, Identifiable {
    case csv
    case tsv
    case pipe
    case delimiter
    case whitespace
    case regex
    case fixedWidth
    var id: String { rawValue }
}

enum TextToolsImportedJoinMode: String {
    case rows
    case key
}

struct TextToolsImportedSource: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let text: String
}

// MARK: - Model

@MainActor
final class TextToolsModel: ObservableObject {
    // Source
    @Published var inputText = ""
    @Published var importedText = ""
    @Published var importedSources: [TextToolsImportedSource] = []
    @Published var includeImportedText = false
    @Published var importedJoinMode: TextToolsImportedJoinMode = .rows
    @Published var keyColumnText = "1"

    // Split
    @Published var splitMode: TextToolsSplitMode = .csv
    @Published var delimiter = ","
    @Published var regexPattern = "\\s+"
    @Published var fixedWidths = "8, 12"

    // Token composer (replaces selectedColumns / columnOrder /
    // prefix / suffix / joinDelimiter from Phase 38).
    @Published var tokens: [ColumnToken] = []
    @Published var missingCellPlaceholder = ""

    /// Ephemeral drag-source identity for the cross-container DnD
    /// between palette and composer. Mirrors the `draggingColumn`
    /// pattern from Phase 38's column row reorder.
    @Published var draggingTokenSource: TokenDragSource?

    /// True while the user is actively editing a literal chip's
    /// inline TextField. Prevents `syncTokensWithColumnCount` from
    /// stomping on a half-typed value if the columnCount happens to
    /// shift mid-edit (rare, but cheap to guard).
    @Published var editingLiteralID: UUID?

    let previewRowLimit = 80

    /// Phase 40c — cap for the live output preview. Big files
    /// (10k+ rows) used to re-render the entire ColumnRecipe on
    /// every keystroke; SwiftUI's TextEditor would also choke on
    /// the resulting megabyte-sized string. Now the preview is
    /// truncated to the first N rows, while Copy / New Tab /
    /// Replace Selection / Replace Document still operate on the
    /// full rendering. 20 rows is enough to verify the template
    /// is doing what the user expects.
    let outputPreviewLineLimit = 20

    // MARK: Source resolution

    var sourceText: String {
        if includeImportedText, hasImportedSources {
            return ([inputText] + importedSources.map(\.text) + [importedText])
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        return inputText
    }

    var hasImportedSources: Bool {
        !importedText.isEmpty || !importedSources.isEmpty
    }

    // MARK: Split / table

    var splitStrategy: TextSplitStrategy {
        switch splitMode {
        case .csv: return .quotedDelimiter(",")
        case .tsv: return .delimiter("\t")
        case .pipe: return .delimiter("|")
        case .delimiter: return .delimiter(delimiter)
        case .whitespace: return .whitespace
        case .regex: return .regularExpression(regexPattern)
        case .fixedWidth: return .fixedWidths(parsedFixedWidths)
        }
    }

    var parsedFixedWidths: [Int] {
        fixedWidths
            .split { $0 == "," || $0 == " " || $0 == "\t" }
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
    }

    var primaryTable: TextTable {
        TextTableSplitter.split(inputText, strategy: splitStrategy)
    }

    var importedTables: [TextTable] {
        let fileTables = importedSources.map {
            TextTableSplitter.split($0.text, strategy: splitStrategy)
        }
        if !importedText.isEmpty {
            return fileTables + [TextTableSplitter.split(importedText, strategy: splitStrategy)]
        }
        return fileTables
    }

    var importedTable: TextTable {
        TextTable.mergeByRow(importedTables)
    }

    var importedRowMismatch: Bool {
        includeImportedText
            && hasImportedSources
            && importedJoinMode == .rows
            && primaryTable.rowCount != importedTable.rowCount
    }

    var table: TextTable {
        if includeImportedText, hasImportedSources {
            switch importedJoinMode {
            case .rows:
                return TextTable.mergeByRow([primaryTable] + importedTables)
            case .key:
                return TextTable.mergeByKey(primary: primaryTable,
                                            imported: importedTables,
                                            keyColumn: keyColumnIndex)
            }
        }
        return primaryTable
    }

    var keyColumnIndex: Int {
        let trimmed = keyColumnText.trimmingCharacters(in: .whitespacesAndNewlines)
        return max(0, (Int(trimmed) ?? 1) - 1)
    }

    var columnCount: Int {
        table.columnCount
    }

    // MARK: Recipe / result

    var recipeParts: [ColumnRecipePart] {
        tokens.map(\.asRecipePart)
    }

    /// Full rendering — used by Copy / Replace Document / etc.
    /// Costs O(rows × tokens). Computed lazily; consumers should
    /// only invoke this on user action, not in `body`.
    var columnResult: String {
        guard tokens.contains(where: { $0.isColumn }) else { return "" }
        return ColumnRecipe(parts: recipeParts,
                            missingCellPlaceholder: missingCellPlaceholder)
            .render(table: table)
    }

    /// Truncated rendering — used by the live preview surface to
    /// cap re-render cost on large inputs. Slices the parsed
    /// table down to the first `outputPreviewLineLimit` rows
    /// before piping through ColumnRecipe.
    var columnResultPreview: String {
        guard tokens.contains(where: { $0.isColumn }) else { return "" }
        let full = table
        let truncated = TextTable(rows: Array(full.rows.prefix(outputPreviewLineLimit)))
        return ColumnRecipe(parts: recipeParts,
                            missingCellPlaceholder: missingCellPlaceholder)
            .render(table: truncated)
    }

    /// Total row count of the parsed table — for the "showing X of
    /// Y" header. Cheap (just a count). Kept separate from the
    /// preview string so the header doesn't have to reach into
    /// columnResult.
    var totalRowCount: Int {
        table.rowCount
    }

    // MARK: Helpers

    func sample(forColumn index: Int) -> String {
        table.rows.first { row in
            row.indices.contains(index) && !row[index].isEmpty
        }?[index] ?? ""
    }

    /// Append a column token; auto-prepend a default ", " separator
    /// if the composer already has content. This is the single-click
    /// "add to template" path from the palette.
    func appendColumn(_ index: Int, separator: String = ", ") {
        if !tokens.isEmpty, !separator.isEmpty {
            tokens.append(.literal(separator))
        }
        tokens.append(.column(index))
    }

    /// Insert a column token at a precise position — used by the
    /// drag-and-drop path. No auto-separator; the user picked the
    /// position so they own the surrounding text.
    func insertColumn(_ index: Int, at position: Int) {
        let clamped = min(max(0, position), tokens.count)
        tokens.insert(.column(index), at: clamped)
    }

    /// Reorder an existing token (by id) to a new index.
    func moveToken(id: UUID, to position: Int) {
        guard let from = tokens.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, position), tokens.count)
        tokens.move(fromOffsets: IndexSet(integer: from),
                    toOffset: target > from ? target + 1 : target)
    }

    func removeToken(id: UUID) {
        tokens.removeAll { $0.id == id }
    }

    func updateLiteral(id: UUID, text: String) {
        guard let idx = tokens.firstIndex(where: { $0.id == id }) else { return }
        tokens[idx] = .literal(id: id, text: text)
    }

    /// Append a fresh empty literal — invoked by "+ 文本" button.
    /// Returns the new token's id so the view can immediately focus
    /// the inline TextField.
    @discardableResult
    func appendEmptyLiteral() -> UUID {
        let token = ColumnToken.literal("")
        tokens.append(token)
        return token.id
    }

    func clearTokens() {
        tokens.removeAll()
    }

    /// Refill composer with all columns + ", " separators —
    /// triggered by "全部加入" button. Always overwrites; the button
    /// label communicates that intent.
    func reseedAllColumns(separator: String = ", ") {
        tokens = ColumnTokenSeed.defaultTokens(columnCount: columnCount,
                                               separator: separator)
    }

    /// Called whenever columnCount may have changed (split-mode
    /// switch, source edit, imported-source toggle…). Two jobs:
    ///   1. Drop column tokens whose index is now out of range.
    ///   2. If the composer is empty and we have columns, seed a
    ///      sensible default so the user sees output immediately.
    func syncTokensWithColumnCount() {
        let count = columnCount
        let valid = 0..<count
        tokens.removeAll { token in
            if case .column(_, let index) = token, !valid.contains(index) {
                return true
            }
            return false
        }
        if tokens.isEmpty, count > 0 {
            tokens = ColumnTokenSeed.defaultTokens(columnCount: count)
        }
    }

    /// Auto-seed the source textarea on workbench open. The Phase
    /// 38 model exposed a Selection / Document / Scratch picker;
    /// Phase 40 collapsed that into one textarea with two header
    /// reload buttons. The picker is gone, but the smart-default
    /// behaviour stays: prefer the active selection if there is
    /// one (the user almost certainly opened the sheet to operate
    /// on it), otherwise fall back to the current document.
    func seedInitialText(workspace: Workspace) {
        guard inputText.isEmpty else { return }
        if !workspace.activeTextSelection.isEmpty {
            inputText = workspace.activeTextSelection
        } else {
            inputText = workspace.current?.text ?? ""
        }
        syncTokensWithColumnCount()
    }

    func importTextFromDisk() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            let sources = panel.urls.compactMap { url -> TextToolsImportedSource? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return TextToolsImportedSource(name: url.lastPathComponent,
                                               text: TextFormatDetector.decode(data: data).text)
            }
            importedSources.append(contentsOf: sources)
            includeImportedText = true
            syncTokensWithColumnCount()
        }
    }

    func currentResult() -> String {
        columnResult
    }
}
