//
//  TextToolsToken.swift
//  Phase 40 — Token Composer data model.
//
//  The redesigned merger replaces the old "selectedColumns +
//  columnOrder + prefix + suffix + joinDelimiter" tuple with a
//  single ordered list of `ColumnToken`s. Each token is either a
//  reference to a parsed column ({1}, {2}…) or a literal string
//  (", ", " - ", "\n"…). The list maps 1:1 onto the existing
//  ColumnRecipePart pipeline in Models/TextOperations.swift, so
//  rendering reuses ColumnRecipe.render(table:) untouched.
//
//  IDs are persistent — SwiftUI ForEach + drag-and-drop need a
//  stable identifier per chip across re-renders so reordering and
//  inline-edit don't lose focus or animation.
//

import Foundation

enum ColumnToken: Identifiable, Equatable {
    case column(id: UUID, index: Int)
    case literal(id: UUID, text: String)

    var id: UUID {
        switch self {
        case .column(let id, _), .literal(let id, _):
            return id
        }
    }

    var asRecipePart: ColumnRecipePart {
        switch self {
        case .column(_, let index): .column(index)
        case .literal(_, let text): .literal(text)
        }
    }

    var isColumn: Bool {
        if case .column = self { return true }
        return false
    }

    var isLiteral: Bool {
        if case .literal = self { return true }
        return false
    }

    var literalText: String? {
        if case .literal(_, let text) = self { return text }
        return nil
    }

    var columnIndex: Int? {
        if case .column(_, let index) = self { return index }
        return nil
    }

    static func column(_ index: Int) -> ColumnToken {
        .column(id: UUID(), index: index)
    }

    static func literal(_ text: String) -> ColumnToken {
        .literal(id: UUID(), text: text)
    }
}

/// Drag source identifier — distinguishes "new column from palette"
/// from "existing token being repositioned". Encoded as a string
/// payload through NSItemProvider, matching the pattern used by
/// TextToolsColumnRowDropDelegate in Phase 38.
enum TokenDragSource: Equatable {
    case palette(columnIndex: Int)
    case composer(tokenID: UUID)

    var serialized: String {
        switch self {
        case .palette(let index):
            return "palette:\(index)"
        case .composer(let id):
            return "composer:\(id.uuidString)"
        }
    }

    init?(serialized raw: String) {
        if let value = raw.dropPrefix("palette:"),
           let index = Int(value) {
            self = .palette(columnIndex: index)
            return
        }
        if let value = raw.dropPrefix("composer:"),
           let id = UUID(uuidString: String(value)) {
            self = .composer(tokenID: id)
            return
        }
        return nil
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        guard hasPrefix(prefix) else { return nil }
        return self[index(startIndex, offsetBy: prefix.count)...]
    }
}

/// Default seed used when the composer is empty and a non-zero
/// columnCount is available. Produces `{1}, {2}, …, {n}` so the
/// user lands on a sensible starting point instead of a blank
/// canvas.
enum ColumnTokenSeed {
    static func defaultTokens(columnCount: Int,
                              separator: String = ", ") -> [ColumnToken] {
        guard columnCount > 0 else { return [] }
        var tokens: [ColumnToken] = []
        for index in 0..<columnCount {
            if index > 0, !separator.isEmpty {
                tokens.append(.literal(separator))
            }
            tokens.append(.column(index))
        }
        return tokens
    }
}
