//
//  ThemeManager.swift
//  Single source of truth for editor + UI colours. Phase 1.8 shipped
//  one light theme and one dark theme (editor only); Phase 15 added a
//  catalog with a Settings picker; Phase 36 extended each Theme with
//  a parallel UI palette so the chrome (sidebar, status bar, command
//  palette, accent) can ride along instead of clinging to system
//  materials. Phase 39a (this file) replaces the third-party-derived
//  catalog (Solarized / Dracula / Monokai / GitHub) with six
//  macOS-native presets anchored on Apple system colours.
//
//  Editor colours are kept in a `Theme` value (Swift-side, RGB) and
//  converted to Scintilla's 0x00BBGGRR `sptr_t` form only at the
//  SCI_STYLESET* call site. Keeping the Theme abstract decouples
//  editor code from the bit-twiddling we have to do crossing into
//  ScintillaView.
//
//  The 11 `ui*` fields are *not* fed to Scintilla; they're consumed
//  by SwiftUI views via the `\.appTheme` environment (see AppTheme
//  + ThemeHost). The same Theme struct serves both layers because
//  every preset already had a defined UI vibe — keeping them on one
//  struct means a single source of truth per palette and lets
//  callers ignore whichever half they don't need.
//

import AppKit

/// One palette. Colours are in plain SwiftUI / NSColor RGB; the
/// `ScintillaCodeEditor` translates them into Scintilla's BGR-packed
/// `sptr_t` form when it pushes them into the view. The `ui*` fields
/// power the surrounding SwiftUI chrome via `\.appTheme`.
struct Theme: Sendable, Equatable {
    // MARK: Editor

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

    // MARK: UI chrome (Phase 36)

    /// Main window background — the area outside sidebars and editor
    /// (title bar fill, toolbar, empty-state backdrops).
    let uiWindowBackground: Int
    /// Sidebar background — File Tree / Search / Source Control panes.
    let uiSidebarBackground: Int
    /// Status bar / Find bar background.
    let uiBarBackground: Int
    /// Command palette / Quick Open floating panel background.
    let uiPanelBackground: Int
    /// Primary accent colour — selected items, focus rings, buttons.
    /// Replaces ad-hoc `Color.accentColor` calls.
    let uiAccent: Int
    /// Foreground colour drawn *on top of* uiAccent (selected row text,
    /// primary button label).
    let uiAccentText: Int
    /// Default text colour for chrome (file names, status segments).
    let uiPrimaryText: Int
    /// Secondary text — replaces `.foregroundStyle(.secondary)` where
    /// the colour is part of the theme rather than a SwiftUI semantic.
    let uiSecondaryText: Int
    /// Tertiary text — placeholders, disabled labels, faint metadata.
    let uiTertiaryText: Int
    /// Hairline separators between panes / list rows.
    let uiSeparator: Int
    /// Subtle row / list-item highlight (hover, non-focused selection).
    let uiSelection: Int

    // MARK: - Built-in catalog (Phase 39a — macOS-native palette)
    //
    // Six presets replacing the previous Solarized/Dracula/Monokai/
    // GitHub set. Three light + three dark, all anchored on Apple
    // system colours so the chrome reads as native to macOS rather
    // than ported from VS Code / Sublime. Syntax colours follow the
    // Xcode default editor palette so `.swift` / `.m` / `.cpp` files
    // look familiar to dev-tooling muscle memory.

    /// Daylight — default light theme. Paper white document, system
    /// blue accent, NSColor.controlBackgroundColor-style sidebar grey.
    /// Syntax: Xcode-light hues (purple keywords, red strings).
    static let daylight = Theme(
        background:          0xFFFFFF,
        foreground:          0x1D1D1F,
        caret:               0x007AFF,
        selectionBackground: 0xB4D5FE,
        marginBackground:    0xF5F5F7,
        marginForeground:    0x86868B,
        keyword:             0xAD3DA4,
        string:              0xD12F1B,
        comment:             0x707F8C,
        number:              0x272AD8,
        preprocessor:        0x78492A,
        type:                0x3900A0,
        identifier:          0x1D1D1F,
        uiWindowBackground:  0xECECEC,
        uiSidebarBackground: 0xF5F5F7,
        uiBarBackground:     0xF5F5F7,
        uiPanelBackground:   0xFFFFFF,
        uiAccent:            0x007AFF,
        uiAccentText:        0xFFFFFF,
        uiPrimaryText:       0x1D1D1F,
        uiSecondaryText:     0x6C6C70,
        uiTertiaryText:      0x8E8E93,
        uiSeparator:         0xD1D1D6,
        uiSelection:         0xE5E5EA
    )

    /// Graphite Light — neutral monochrome light theme. Subdued for
    /// long sessions. Accent is system graphite gray; syntax stays
    /// in monochrome bands so colour fatigue stays low.
    static let graphiteLight = Theme(
        background:          0xFAFAFA,
        foreground:          0x1A1A1A,
        caret:               0x404040,
        selectionBackground: 0xCFCFCF,
        marginBackground:    0xF0F0F0,
        marginForeground:    0x999999,
        keyword:             0x2E2E2E,
        string:              0x6E6E6E,
        comment:             0xA8A8A8,
        number:              0x4A4A4A,
        preprocessor:        0x707070,
        type:                0x383838,
        identifier:          0x1A1A1A,
        uiWindowBackground:  0xF0F0F0,
        uiSidebarBackground: 0xE8E8E8,
        uiBarBackground:     0xE8E8E8,
        uiPanelBackground:   0xFAFAFA,
        uiAccent:            0x636366,
        uiAccentText:        0xFFFFFF,
        uiPrimaryText:       0x1A1A1A,
        uiSecondaryText:     0x6E6E73,
        uiTertiaryText:      0x8E8E93,
        uiSeparator:         0xD0D0D0,
        uiSelection:         0xDFDFDF
    )

    /// Sand — warm cream-paper light theme. Reading-friendly, low
    /// contrast, terracotta accent. For prose / Markdown work.
    static let sand = Theme(
        background:          0xFBF7EC,
        foreground:          0x3C2F1E,
        caret:               0xC0392B,
        selectionBackground: 0xF5E6C2,
        marginBackground:    0xF6EFDD,
        marginForeground:    0xA89274,
        keyword:             0xC0392B,
        string:              0x8E6E2C,
        comment:             0xB59B7A,
        number:              0xA8632F,
        preprocessor:        0x6E5536,
        type:                0x814A1F,
        identifier:          0x3C2F1E,
        uiWindowBackground:  0xF6EFDD,
        uiSidebarBackground: 0xEEE3C8,
        uiBarBackground:     0xEEE3C8,
        uiPanelBackground:   0xFBF7EC,
        uiAccent:            0xB85F2E,
        uiAccentText:        0xFBF7EC,
        uiPrimaryText:       0x3C2F1E,
        uiSecondaryText:     0x6E5C42,
        uiTertiaryText:      0x9D8765,
        uiSeparator:         0xD9CBA3,
        uiSelection:         0xE6D9B0
    )

    /// Inkwell — default dark theme. Apple dark-mode base (#1D1D1F),
    /// system blue accent. Syntax follows Xcode dark default
    /// (pink keywords, red strings, teal types).
    static let inkwell = Theme(
        background:          0x1D1D1F,
        foreground:          0xF5F5F7,
        caret:               0x0A84FF,
        selectionBackground: 0x2D466E,
        marginBackground:    0x252526,
        marginForeground:    0x6E6E73,
        keyword:             0xFF7AB2,
        string:              0xFC6A5D,
        comment:             0x6C7986,
        number:              0xD0BF69,
        preprocessor:        0xFD8F3F,
        type:                0x9EF1DD,
        identifier:          0xF5F5F7,
        uiWindowBackground:  0x1D1D1F,
        uiSidebarBackground: 0x252527,
        uiBarBackground:     0x2C2C2E,
        uiPanelBackground:   0x2C2C2E,
        uiAccent:            0x0A84FF,
        uiAccentText:        0xFFFFFF,
        uiPrimaryText:       0xF5F5F7,
        uiSecondaryText:     0x9D9DA1,
        uiTertiaryText:      0x6E6E73,
        uiSeparator:         0x3A3A3C,
        uiSelection:         0x3A3A3C
    )

    /// Graphite Dark — neutral cool dark theme. Same monochrome
    /// philosophy as graphiteLight inverted; syntax stays in bands
    /// of gray with only contrast carrying meaning.
    static let graphiteDark = Theme(
        background:          0x1C1C1E,
        foreground:          0xE5E5EA,
        caret:               0xD1D1D6,
        selectionBackground: 0x3A3A3C,
        marginBackground:    0x222224,
        marginForeground:    0x6E6E73,
        keyword:             0xF2F2F7,
        string:              0xC7C7CC,
        comment:             0x636366,
        number:              0xD1D1D6,
        preprocessor:        0x8E8E93,
        type:                0xC7C7CC,
        identifier:          0xE5E5EA,
        uiWindowBackground:  0x1C1C1E,
        uiSidebarBackground: 0x232325,
        uiBarBackground:     0x2A2A2C,
        uiPanelBackground:   0x28282A,
        uiAccent:            0xAEAEB2,
        uiAccentText:        0x1C1C1E,
        uiPrimaryText:       0xE5E5EA,
        uiSecondaryText:     0xAEAEB2,
        uiTertiaryText:      0x8E8E93,
        uiSeparator:         0x3A3A3C,
        uiSelection:         0x2C2C2E
    )

    /// Midnight — deep blue-black dark theme with system purple
    /// accent. Cooler than Inkwell, with a richer syntax palette
    /// (purple/yellow/cyan/orange) for code-heavy sessions.
    static let midnight = Theme(
        background:          0x12121C,
        foreground:          0xE0E0F0,
        caret:               0xBF5AF2,
        selectionBackground: 0x2A2A4A,
        marginBackground:    0x1A1A28,
        marginForeground:    0x707090,
        keyword:             0xBF5AF2,
        string:              0xFFD60A,
        comment:             0x636388,
        number:              0xFF9F0A,
        preprocessor:        0xFF375F,
        type:                0x64D2FF,
        identifier:          0xE0E0F0,
        uiWindowBackground:  0x12121C,
        uiSidebarBackground: 0x18182A,
        uiBarBackground:     0x1A1A2C,
        uiPanelBackground:   0x1F1F30,
        uiAccent:            0xBF5AF2,
        uiAccentText:        0xFFFFFF,
        uiPrimaryText:       0xE0E0F0,
        uiSecondaryText:     0x9C9CB8,
        uiTertiaryText:      0x6E6E90,
        uiSeparator:         0x2A2A4A,
        uiSelection:         0x2A2A4A
    )

    /// Pick a theme based on the active appearance. Phase 15 also
    /// supports an explicit catalog lookup; this remains the
    /// "follow system" path used by ThemeID.system.
    /// Phase 39a — `.aqua` → `.daylight`, `.darkAqua` → `.inkwell`.
    static func resolved(for appearance: NSAppearance) -> Theme {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .inkwell : .daylight
    }
}

/// Phase 15 — user-selectable theme. `.system` keeps the original
/// "follow NSAppearance" behaviour; the rest pin a specific palette
/// regardless of the OS-wide light/dark preference.
///
/// Phase 39a — catalog reshuffled to macOS-native presets. Legacy
/// raw values (`lightDefault`, `darkDefault`, `solarizedLight`,
/// `solarizedDark`, `dracula`, `monokai`, `githubLight`) are migrated
/// to the closest new preset by `EditorPreferences.legacyThemeAlias`.
enum ThemeID: String, CaseIterable, Sendable, Identifiable {
    case system
    case daylight
    case graphiteLight
    case sand
    case inkwell
    case graphiteDark
    case midnight

    var id: String { rawValue }

    /// Human-readable label for menus / settings. Display names are
    /// intentionally not localized — theme names are proper nouns
    /// the user might recognize across platforms (Inkwell/Midnight
    /// read the same in both Chinese and English UIs).
    var displayName: String {
        switch self {
        case .system:        return "System (auto)"
        case .daylight:      return "Daylight"
        case .graphiteLight: return "Graphite Light"
        case .sand:          return "Sand"
        case .inkwell:       return "Inkwell"
        case .graphiteDark:  return "Graphite Dark"
        case .midnight:      return "Midnight"
        }
    }

    /// True for the variants that draw light text on a dark
    /// background. Lets surrounding chrome pick the right contrast
    /// for non-Scintilla widgets if it ever needs to.
    /// `@MainActor` because `.system` consults `NSApp` — Swift 6
    /// strict concurrency forbids that from a nonisolated context.
    /// All callers (theme menu, Scintilla coordinator) already run
    /// on the main actor, so this is a no-cost annotation.
    ///
    /// Note (Phase 39b): when a user overrides slot colours via
    /// `ThemeOverrides`, the resolved palette may visually diverge
    /// from this classification (e.g. they paint Daylight's window
    /// background black). `isDark` deliberately reflects the
    /// preset's *intent*, not the post-override pixel luminance.
    @MainActor
    var isDark: Bool {
        switch self {
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        case .inkwell, .graphiteDark, .midnight:
            return true
        case .daylight, .graphiteLight, .sand:
            return false
        }
    }

    /// Resolve to a concrete Theme. `appearance` is consulted only
    /// for `.system`; explicit choices ignore it.
    func resolve(appearance: NSAppearance) -> Theme {
        switch self {
        case .system:        return Theme.resolved(for: appearance)
        case .daylight:      return .daylight
        case .graphiteLight: return .graphiteLight
        case .sand:          return .sand
        case .inkwell:       return .inkwell
        case .graphiteDark:  return .graphiteDark
        case .midnight:      return .midnight
        }
    }
}
