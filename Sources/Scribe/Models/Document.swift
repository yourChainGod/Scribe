//
//  Document.swift
//  Represents one tab — text content + metadata.
//

import Foundation
import SwiftUI

@MainActor
final class Document: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var text: String
    @Published var url: URL?
    @Published var encoding: TextEncoding = .utf8
    @Published var lineEnding: LineEnding = .lf
    @Published var isDirty: Bool = false
    @Published var cursorLine: Int = 1
    @Published var cursorColumn: Int = 1
    /// User-chosen Lexilla lexer name. When set, takes precedence over the
    /// extension-based detection in `LexerCatalog`. `nil` ⇒ auto.
    @Published var lexerOverride: String?
    /// 1-based line the editor should scroll/select on next presentation.
    /// Set by Workspace.openFile(at:line:) — read by ScintillaCodeEditor
    /// during makeNSView / updateNSView and cleared after consumption.
    @Published var pendingScrollLine: Int? = nil

    init(title: String = "Untitled", text: String = "", url: URL? = nil) {
        self.title = title
        self.text = text
        self.url = url
    }

    var displayTitle: String {
        (isDirty ? "● " : "") + title
    }

    var languageGuess: String {
        guard let url else { return "txt" }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "txt" : ext
    }
}
