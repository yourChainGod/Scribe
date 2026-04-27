//
//  ThemeManager.swift
//  Single source of truth for editor colours. Phase 1.8 ships one light
//  theme and one dark theme that follow NSAppearance; Phase 9 will let
//  users pick from a catalog and roll their own.
//
//  Colours are kept in a `Theme` value (Swift-side, RGB) and converted
//  to Scintilla's 0x00BBGGRR `sptr_t` form only at the SCI_STYLESET*
//  call site. Keeping the Theme abstract decouples editor code from the
//  bit-twiddling we have to do crossing into ScintillaView.
//

import AppKit

/// One palette. Colours are in plain SwiftUI / NSColor RGB; the
/// `ScintillaCodeEditor` translates them into Scintilla's BGR-packed
/// `sptr_t` form when it pushes them into the view.
struct Theme: Sendable {
    /// Document background.
    let background: Int
    /// Default text colour (also applied to STYLE_DEFAULT before the
    /// `SCI_STYLECLEARALL` propagation).
    let foreground: Int
    /// Caret colour.
    let caret: Int
    /// Selection background.
    let selectionBackground: Int
    /// Line-number margin background.
    let marginBackground: Int
    /// Line-number margin foreground.
    let marginForeground: Int

    // Per-token colours used by Lexilla's C/C++/JS/Swift styles. We pick
    // SCE_C_* values on purpose: they're shared by lmCPP across many
    // dialects (cpp, javascript, swift fallback in LexerCatalog).
    let keyword: Int
    let string: Int
    let comment: Int
    let number: Int
    let preprocessor: Int
    let type: Int
    let identifier: Int

    static let lightDefault = Theme(
        background: 0xFFFFFF,
        foreground: 0x1F1F1F,
        caret: 0x1F1F1F,
        selectionBackground: 0xADD6FF,
        marginBackground: 0xF5F5F5,
        marginForeground: 0x9A9A9A,
        keyword:      0x0000FF,
        string:       0xA31515,
        comment:      0x008000,
        number:       0x098658,
        preprocessor: 0x808080,
        type:         0x267F99,
        identifier:   0x1F1F1F
    )

    static let darkDefault = Theme(
        background: 0x1E1E1E,
        foreground: 0xD4D4D4,
        caret: 0xD4D4D4,
        selectionBackground: 0x264F78,
        marginBackground: 0x252526,
        marginForeground: 0x858585,
        keyword:      0x569CD6,
        string:       0xCE9178,
        comment:      0x6A9955,
        number:       0xB5CEA8,
        preprocessor: 0xC586C0,
        type:         0x4EC9B0,
        identifier:   0xD4D4D4
    )

    /// Pick a theme based on the active appearance. Phase 9 turns this
    /// into a catalog lookup driven by user preference.
    static func resolved(for appearance: NSAppearance) -> Theme {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .darkDefault : .lightDefault
    }
}
