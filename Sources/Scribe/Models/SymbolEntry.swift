//
//  SymbolEntry.swift
//  Phase 7 — symbol model behind the Outline sidebar. One entry per
//  user-visible thing: function, class, struct, heading, …
//
//  We deliberately keep the model thin and language-agnostic — every
//  language's regex parser maps its own syntax onto this small enum,
//  so the OutlineSidebar view doesn't have to special-case anything.
//

import Foundation
import SwiftUI

/// What kind of symbol this entry represents. The icon + tint mapping
/// is centralised here so adding a new language only adds rows to the
/// switch in SymbolParserCatalog.
enum SymbolKind: String, Sendable {
    case function
    case method
    case classDecl
    case structDecl
    case enumDecl
    case protocolDecl
    case extensionDecl
    case typealiasDecl
    case property
    case heading        // Markdown / restructured text
    case test           // function whose name pattern marks it as a test

    /// SF Symbol name. Picked from the curated set so dark mode + tinting
    /// look consistent in both ScribeApp.app and Settings preview.
    var icon: String {
        switch self {
        case .function:      "function"
        case .method:        "f.cursive"
        case .classDecl:     "c.square"
        case .structDecl:    "square.stack.3d.up"
        case .enumDecl:      "list.bullet.rectangle"
        case .protocolDecl:  "p.square"
        case .extensionDecl: "puzzlepiece.extension"
        case .typealiasDecl: "arrow.left.arrow.right.square"
        case .property:      "p.circle"
        case .heading:       "number"
        case .test:          "checkmark.seal"
        }
    }

    /// Human-readable label, e.g. for ⌘P @symbol subtitles or
    /// VoiceOver descriptions. Lowercase by convention so it composes
    /// with "function · line 42"-style strings without an extra format
    /// step on the caller's side.
    var label: String {
        switch self {
        case .function:      "function"
        case .method:        "method"
        case .classDecl:     "class"
        case .structDecl:    "struct"
        case .enumDecl:      "enum"
        case .protocolDecl:  "protocol"
        case .extensionDecl: "extension"
        case .typealiasDecl: "typealias"
        case .property:      "property"
        case .heading:       "heading"
        case .test:          "test"
        }
    }

    /// Tint colour. Aligned with the icon palette VSCode + JetBrains
    /// IDEs use so users coming from those tools have the muscle memory.
    var tint: Color {
        switch self {
        case .function, .method:    .purple
        case .classDecl:            .blue
        case .structDecl:           .indigo
        case .enumDecl:             .orange
        case .protocolDecl:         .pink
        case .extensionDecl:        .teal
        case .typealiasDecl:        .gray
        case .property:             .cyan
        case .heading:              .green
        case .test:                 .green
        }
    }
}

/// One entry in the outline. `name` is what gets rendered; `lineNumber`
/// is 1-based to match the rest of Scribe (Scintilla, status bar, find
/// results all use 1-based lines).
struct SymbolEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: SymbolKind
    let name: String
    let lineNumber: Int
    /// Logical nesting depth. Markdown uses heading level (1..6);
    /// brace-balanced languages (Swift/JS/Rust/Go/C) get one level
    /// per unclosed `{` thanks to scanLines' brace tracker.
    /// Mutated by scanLines after the rule emits the entry, hence
    /// `var` rather than `let`.
    var depth: Int

    init(id: UUID = UUID(),
         kind: SymbolKind,
         name: String,
         lineNumber: Int,
         depth: Int = 0) {
        self.id = id
        self.kind = kind
        self.name = name
        self.lineNumber = lineNumber
        self.depth = depth
    }

    static func == (lhs: SymbolEntry, rhs: SymbolEntry) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
