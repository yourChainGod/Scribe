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

    // MARK: - Phase 15 catalog

    /// Solarized Light by Ethan Schoonover. Carefully muted hues
    /// designed to keep contrast comfortable on warm-toned displays.
    static let solarizedLight = Theme(
        background: 0xFDF6E3,        // base3
        foreground: 0x657B83,        // base00
        caret: 0x586E75,             // base01
        selectionBackground: 0xEEE8D5,   // base2
        marginBackground: 0xEEE8D5,
        marginForeground: 0x93A1A1,  // base1
        keyword:      0x859900,      // green
        string:       0x2AA198,      // cyan
        comment:      0x93A1A1,      // base1 (muted)
        number:       0xD33682,      // magenta
        preprocessor: 0xCB4B16,      // orange
        type:         0xB58900,      // yellow
        identifier:   0x657B83
    )

    /// Solarized Dark — same hues, inverted base layer.
    static let solarizedDark = Theme(
        background: 0x002B36,        // base03
        foreground: 0x839496,        // base0
        caret: 0x93A1A1,             // base1
        selectionBackground: 0x073642,   // base02
        marginBackground: 0x073642,
        marginForeground: 0x586E75,  // base01
        keyword:      0x859900,
        string:       0x2AA198,
        comment:      0x586E75,
        number:       0xD33682,
        preprocessor: 0xCB4B16,
        type:         0xB58900,
        identifier:   0x839496
    )

    /// Dracula by Zeno Rocha — popular high-contrast dark theme with
    /// a purple-leaning UI accent.
    static let dracula = Theme(
        background: 0x282A36,
        foreground: 0xF8F8F2,
        caret: 0xF8F8F2,
        selectionBackground: 0x44475A,
        marginBackground: 0x21222C,
        marginForeground: 0x6272A4,
        keyword:      0xFF79C6,      // pink
        string:       0xF1FA8C,      // yellow
        comment:      0x6272A4,
        number:       0xBD93F9,      // purple
        preprocessor: 0xFF79C6,
        type:         0x8BE9FD,      // cyan
        identifier:   0xF8F8F2
    )

    /// Monokai — Sublime / TextMate's classic dark theme.
    static let monokai = Theme(
        background: 0x272822,
        foreground: 0xF8F8F2,
        caret: 0xF8F8F0,
        selectionBackground: 0x49483E,
        marginBackground: 0x1E1F1C,
        marginForeground: 0x90908A,
        keyword:      0xF92672,      // pink
        string:       0xE6DB74,      // yellow
        comment:      0x75715E,      // muted brown
        number:       0xAE81FF,      // purple
        preprocessor: 0xF92672,
        type:         0x66D9EF,      // cyan
        identifier:   0xF8F8F2
    )

    /// GitHub Light — close to GitHub.com's syntax highlighter.
    static let githubLight = Theme(
        background: 0xFFFFFF,
        foreground: 0x24292E,
        caret: 0x24292E,
        selectionBackground: 0xC8E1FF,
        marginBackground: 0xF6F8FA,
        marginForeground: 0x959DA5,
        keyword:      0xD73A49,      // red
        string:       0x032F62,      // navy
        comment:      0x6A737D,      // grey
        number:       0x005CC5,      // blue
        preprocessor: 0x6F42C1,      // purple
        type:         0x6F42C1,
        identifier:   0x24292E
    )

    /// Pick a theme based on the active appearance. Phase 15 also
    /// supports an explicit catalog lookup; this remains the
    /// "follow system" path used by ThemeID.system.
    static func resolved(for appearance: NSAppearance) -> Theme {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .darkDefault : .lightDefault
    }
}

/// Phase 15 — user-selectable theme. `.system` keeps the original
/// "follow NSAppearance" behaviour; the rest pin a specific palette
/// regardless of the OS-wide light/dark preference.
enum ThemeID: String, CaseIterable, Sendable, Identifiable {
    case system
    case lightDefault
    case darkDefault
    case solarizedLight
    case solarizedDark
    case dracula
    case monokai
    case githubLight

    var id: String { rawValue }

    /// Human-readable label for menus / settings.
    var displayName: String {
        switch self {
        case .system:          return "System (auto)"
        case .lightDefault:    return "Scribe Light"
        case .darkDefault:     return "Scribe Dark"
        case .solarizedLight:  return "Solarized Light"
        case .solarizedDark:   return "Solarized Dark"
        case .dracula:         return "Dracula"
        case .monokai:         return "Monokai"
        case .githubLight:     return "GitHub Light"
        }
    }

    /// True for the variants that draw light text on a dark
    /// background. Lets surrounding chrome pick the right contrast
    /// for non-Scintilla widgets if it ever needs to.
    var isDark: Bool {
        switch self {
        case .system:          return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        case .darkDefault, .solarizedDark, .dracula, .monokai:
            return true
        case .lightDefault, .solarizedLight, .githubLight:
            return false
        }
    }

    /// Resolve to a concrete Theme. `appearance` is consulted only
    /// for `.system`; explicit choices ignore it.
    func resolve(appearance: NSAppearance) -> Theme {
        switch self {
        case .system:          return Theme.resolved(for: appearance)
        case .lightDefault:    return .lightDefault
        case .darkDefault:     return .darkDefault
        case .solarizedLight:  return .solarizedLight
        case .solarizedDark:   return .solarizedDark
        case .dracula:         return .dracula
        case .monokai:         return .monokai
        case .githubLight:     return .githubLight
        }
    }
}
