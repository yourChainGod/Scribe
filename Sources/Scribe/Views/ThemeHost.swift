//
//  ThemeHost.swift
//  Phase 36 — `ViewModifier` that turns `EditorPreferences` (the
//  three theme keys: `uiThemeID`, `editorThemeID`,
//  `editorFollowsUITheme`) plus the active `NSAppearance` into a
//  resolved `AppTheme`, then pushes it into `\.appTheme` so the
//  whole subtree can read one env key.
//
//  Mounted once at the SwiftUI root in `ScribeApp.body` via
//  `.themed(prefs:)`. Re-runs whenever any of:
//    – prefs.uiThemeID           (Settings picker)
//    – prefs.editorThemeID       (Settings picker)
//    – prefs.editorFollowsUITheme (Settings toggle)
//    – `\.colorScheme`           (system Light/Dark flip)
//  changes, by virtue of `@ObservedObject` + `@Environment` causing
//  SwiftUI to re-evaluate `body`.
//

import SwiftUI
import AppKit

/// Computes the resolved `AppTheme` from prefs + system appearance
/// and injects it into the environment. The body reads
/// `colorScheme` not because we use the value directly, but because
/// touching it makes SwiftUI re-run this view when macOS flips
/// Light/Dark — which is what `.system` themes need to repaint.
@MainActor
struct ThemedModifier: ViewModifier {
    @ObservedObject var prefs: EditorPreferences
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(\.appTheme, resolved)
    }

    /// Re-resolved on every body invocation. `colorScheme` is read
    /// (then discarded) so the env edge propagates and SwiftUI
    /// invalidates this modifier on a Light/Dark flip; the actual
    /// appearance lookup goes through `NSApp.effectiveAppearance`
    /// because that's what `ThemeID.resolve(appearance:)` consumes
    /// and matches what Scintilla's KVO observer sees.
    ///
    /// Phase 39b — after the base `Theme` is resolved we layer the
    /// user's per-theme `ThemeOverrides` on top via
    /// `Theme.applying(_:)`. The merge runs at *both* the UI and
    /// editor resolution points because `editorFollowsUITheme = false`
    /// can target two different theme IDs. `Coordinator+Theme`
    /// performs the same merge on its KVO-driven repaint path.
    private var resolved: AppTheme {
        _ = colorScheme
        let appearance = NSApp.effectiveAppearance
        let uiBase = prefs.uiThemeID.resolve(appearance: appearance)
        let uiTheme = uiBase.applying(prefs.overrides(for: prefs.uiThemeID))

        let editorID = prefs.effectiveEditorThemeID
        let editorBase = editorID.resolve(appearance: appearance)
        let editorTheme = editorBase.applying(prefs.overrides(for: editorID))

        return AppTheme(
            editor: editorTheme,
            ui: uiTheme,
            isDarkUI: prefs.uiThemeID.isDark
        )
    }
}

extension View {
    /// Install the resolved-theme env value. Mount once at the
    /// SwiftUI root (e.g. `MainWindow().themed(prefs: prefs)`).
    @MainActor
    func themed(prefs: EditorPreferences) -> some View {
        modifier(ThemedModifier(prefs: prefs))
    }
}
