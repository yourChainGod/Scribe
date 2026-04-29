//
//  TextToolsModel.swift
//  Phase 38 — shared state for the Text Tools workbench. All
//  @Published fields used to live as @State on the monolithic
//  TextToolsWorkbench; pulling them into one ObservableObject lets
//  each mode view (Columns / Shuffle / Transform) read and write
//  through bindings without re-routing through the host view.
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared enums / value types

enum TextToolsSourceScope: String {
    case selection
    case document
    case manual
}

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

enum TextToolsTransformPreset: String, CaseIterable, Identifiable {
    case urlEncode
    case urlDecode
    case base64Encode
    case base64Decode
    case htmlEscape
    case htmlUnescape
    case jsonEscape
    case jsonUnescape
    case binaryToDecimal
    case decimalToBinary
    case octalToDecimal
    case decimalToOctal
    case hexToDecimal
    case decimalToHex

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .urlEncode: "transform.url.encode"
        case .urlDecode: "transform.url.decode"
        case .base64Encode: "transform.base64.encode"
        case .base64Decode: "transform.base64.decode"
        case .htmlEscape: "transform.html.escape"
        case .htmlUnescape: "transform.html.unescape"
        case .jsonEscape: "transform.json.escape"
        case .jsonUnescape: "transform.json.unescape"
        case .binaryToDecimal: "transform.base.binaryToDecimal"
        case .decimalToBinary: "transform.base.decimalToBinary"
        case .octalToDecimal: "transform.base.octalToDecimal"
        case .decimalToOctal: "transform.base.decimalToOctal"
        case .hexToDecimal: "transform.base.hexToDecimal"
        case .decimalToHex: "transform.base.decimalToHex"
        }
    }

    var action: TextTransformAction {
        switch self {
        case .urlEncode: .urlEncode
        case .urlDecode: .urlDecode
        case .base64Encode: .base64Encode
        case .base64Decode: .base64Decode
        case .htmlEscape: .htmlEscape
        case .htmlUnescape: .htmlUnescape
        case .jsonEscape: .jsonStringEscape
        case .jsonUnescape: .jsonStringUnescape
        case .binaryToDecimal: .convertBase(fromBase: 2, toBase: 10)
        case .decimalToBinary: .convertBase(fromBase: 10, toBase: 2)
        case .octalToDecimal: .convertBase(fromBase: 8, toBase: 10)
        case .decimalToOctal: .convertBase(fromBase: 10, toBase: 8)
        case .hexToDecimal: .convertBase(fromBase: 16, toBase: 10)
        case .decimalToHex: .convertBase(fromBase: 10, toBase: 16)
        }
    }
}

struct TextToolsImportedSource: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let text: String
}

// MARK: - Model

@MainActor
final class TextToolsModel: ObservableObject {
    // Mode + source
    @Published var mode: TextToolsMode = .columns
    @Published var sourceScope: TextToolsSourceScope = .document
    @Published var inputText = ""
    @Published var importedText = ""
    @Published var importedSources: [TextToolsImportedSource] = []
    @Published var includeImportedText = false
    @Published var importedJoinMode: TextToolsImportedJoinMode = .rows
    @Published var keyColumnText = "1"

    // Columns mode
    @Published var splitMode: TextToolsSplitMode = .csv
    @Published var delimiter = ","
    @Published var regexPattern = "\\s+"
    @Published var fixedWidths = "8, 12"
    @Published var joinDelimiter = ", "
    @Published var prefixText = ""
    @Published var suffixText = ""
    @Published var missingCellPlaceholder = ""
    @Published var selectedColumns: Set<Int> = []
    @Published var columnOrder: [Int] = []
    @Published var draggingColumn: Int?

    // Shuffle mode
    @Published var preserveFirstLine = true
    @Published var preserveBlankLinePositions = true
    @Published var shuffleSeed = "37"

    // Transform mode
    @Published var transformPreset: TextToolsTransformPreset = .urlEncode

    let previewRowLimit = 80

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

    var orderedSelectedColumns: [Int] {
        columnOrder.filter { selectedColumns.contains($0) }
    }

    // MARK: Recipes / results

    var columnRecipeParts: [ColumnRecipePart] {
        guard !orderedSelectedColumns.isEmpty else { return [] }
        var parts: [ColumnRecipePart] = []
        if !prefixText.isEmpty { parts.append(.literal(prefixText)) }
        for (offset, index) in orderedSelectedColumns.enumerated() {
            if offset > 0, !joinDelimiter.isEmpty {
                parts.append(.literal(joinDelimiter))
            }
            parts.append(.column(index))
        }
        if !suffixText.isEmpty { parts.append(.literal(suffixText)) }
        return parts
    }

    var columnResult: String {
        guard !orderedSelectedColumns.isEmpty else { return "" }
        return ColumnRecipe(parts: columnRecipeParts,
                            missingCellPlaceholder: missingCellPlaceholder)
            .render(table: table)
    }

    var shuffleResult: String {
        TextLineShuffler.shuffle(sourceText,
                                 seed: UInt64(shuffleSeed) ?? 37,
                                 preserveFirstLine: preserveFirstLine,
                                 preserveBlankLinePositions: preserveBlankLinePositions)
    }

    var transformResult: String {
        (try? transformPreset.action.apply(to: sourceText)) ?? ""
    }

    var transformErrorKey: String? {
        do {
            _ = try transformPreset.action.apply(to: sourceText)
            return nil
        } catch let error as TextTransformError {
            return error.messageKey
        } catch {
            return "transform.error.generic"
        }
    }

    // MARK: Helpers

    func sample(forColumn index: Int) -> String {
        table.rows.first { row in
            row.indices.contains(index) && !row[index].isEmpty
        }?[index] ?? ""
    }

    func seedInitialText(workspace: Workspace, force: Bool = false) {
        if inputText.isEmpty, !workspace.activeTextSelection.isEmpty {
            sourceScope = .selection
        }
        applySourceScope(workspace: workspace, force: force)
        syncColumnState(columnCount: columnCount)
    }

    func applySourceScope(workspace: Workspace, force: Bool = false) {
        guard force || inputText.isEmpty else { return }
        switch sourceScope {
        case .selection:
            inputText = workspace.activeTextSelection
        case .document:
            inputText = workspace.current?.text ?? ""
        case .manual:
            if force { inputText = "" }
        }
    }

    func syncColumnState(columnCount: Int) {
        let valid = Set(0..<columnCount)
        columnOrder = columnOrder.filter { valid.contains($0) }
        for index in 0..<columnCount where !columnOrder.contains(index) {
            columnOrder.append(index)
        }
        selectedColumns = selectedColumns.intersection(valid)
        if selectedColumns.isEmpty, columnCount > 0 {
            selectedColumns = valid
        }
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
            syncColumnState(columnCount: columnCount)
        }
    }

    func currentResult() -> String {
        switch mode {
        case .columns: return columnResult
        case .shuffle: return shuffleResult
        case .transform: return transformResult
        }
    }
}
