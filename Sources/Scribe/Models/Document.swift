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
    @Published var encoding: String.Encoding = .utf8
    @Published var lineEnding: LineEnding = .lf
    @Published var isDirty: Bool = false

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

enum LineEnding: String, CaseIterable, Identifiable {
    case lf = "Unix (LF)"
    case crlf = "Windows (CRLF)"
    case cr = "Classic Mac (CR)"
    var id: String { rawValue }
    var short: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }
}
