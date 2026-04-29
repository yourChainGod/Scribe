//
//  AppTheme.swift
//  Phase 36 — single resolved-theme value the SwiftUI view tree
//  reads via `\.appTheme`. Pairs the editor `Theme` (Scintilla
//  styles) with the chrome `Theme` (UI palette) so callers can
//  ask one environment key whether they're tinting the sidebar or
//  driving Scintilla.
//
//  ThemeHost (Views/ThemeHost.swift) computes this on every change
//  to `EditorPreferences.uiThemeID / editorThemeID /
//  editorFollowsUITheme` plus `NSApp.effectiveAppearance`, then
//  pushes it down via `.environment(\.appTheme, …)`.
//

import SwiftUI

/// 0xRRGGBB → SwiftUI `Color`. Same byte order `Theme` uses.
/// Lives here (not inside a single view file) because every chrome
/// surface that consumes `appTheme` needs it.
extension Color {
    init(rgb: Int) {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8)  & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Resolved theme bundle: what every SwiftUI surface sees once
/// `ThemeHost` has done its work. `editor` carries the full Theme
/// (Scintilla relies on its non-`ui` fields); `ui` carries the
/// Theme whose `ui*` fields drive chrome. They may be the *same*
/// Theme value when the user kept "editor follows UI theme" on,
/// or two different presets when they decoupled.
///
/// `isDarkUI` is precomputed because views frequently want to pick
/// a contrasting overlay (e.g. a slightly lighter selection on a
/// dark sidebar) without re-running the appearance lookup.
struct AppTheme: Equatable, Sendable {
    let editor: Theme
    let ui: Theme
    let isDarkUI: Bool

    /// Bootstrap value used before `ThemeHost` injects the real one.
    /// Daylight (the Phase 39a default light preset) keeps
    /// SettingsView previews and any out-of-tree renders (Xcode
    /// previews, snapshot tests) from blowing up.
    static let placeholder = AppTheme(
        editor: .daylight,
        ui: .daylight,
        isDarkUI: false
    )
}

/// Environment plumbing. Default value is the light placeholder so
/// any View read before `ThemeHost` mounts still gets sane chrome.
private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppTheme = .placeholder
}

extension EnvironmentValues {
    /// Active resolved theme. Read via `@Environment(\.appTheme)`.
    var appTheme: AppTheme {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }
}

/// Convenience accessors so call sites read clean:
///   `theme.sidebarBackground` instead of `Color(rgb: theme.ui.uiSidebarBackground)`.
/// The shorthand always reads from the *UI* half — editor-side
/// Scintilla colours go through SCI_STYLESET* and never touch
/// SwiftUI Color.
extension AppTheme {
    /// Main window background (areas outside sidebar + editor).
    var windowBackground: Color   { Color(rgb: ui.uiWindowBackground) }
    /// Sidebar background — File Tree / Search / Source Control panes.
    var sidebarBackground: Color  { Color(rgb: ui.uiSidebarBackground) }
    /// Status bar / Find bar background.
    var barBackground: Color      { Color(rgb: ui.uiBarBackground) }
    /// Floating panel background (Command palette / Quick Open).
    var panelBackground: Color    { Color(rgb: ui.uiPanelBackground) }
    /// Primary accent — selected items, focus rings, primary buttons.
    var accent: Color             { Color(rgb: ui.uiAccent) }
    /// Foreground colour drawn on top of `accent`.
    var accentText: Color         { Color(rgb: ui.uiAccentText) }
    /// Default text colour for chrome (file names, status segments).
    var primaryText: Color        { Color(rgb: ui.uiPrimaryText) }
    /// Secondary text — captions, metadata.
    var secondaryText: Color      { Color(rgb: ui.uiSecondaryText) }
    /// Tertiary text — placeholders, disabled labels, faint hints.
    var tertiaryText: Color       { Color(rgb: ui.uiTertiaryText) }
    /// Hairline separators between panes / list rows.
    var separator: Color          { Color(rgb: ui.uiSeparator) }
    /// Subtle row / list-item highlight (hover, non-focused selection).
    var selection: Color          { Color(rgb: ui.uiSelection) }
}
