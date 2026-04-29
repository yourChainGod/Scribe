//
//  ThemePreferencesTests.swift
//  Phase 36 — covers the dual-theme model that replaces the
//  single `editor.themeID` key. Three behaviours we have to keep
//  honest as future phases pile on:
//    1. Migration: a user upgrading from <Phase 36 keeps the
//       theme they previously picked, as the global UI theme
//       (and the editor follows by default).
//    2. `effectiveEditorThemeID` honours the follow toggle.
//    3. Each new key persists across instances — picking a theme
//       once survives the next launch.
//  Phase 39a — the third-party-derived presets (Solarized /
//  Dracula / Monokai / GitHub) were retired. Legacy raw values
//  now resolve via `EditorPreferences.legacyThemeAlias` to the
//  closest macOS-native counterpart, regardless of which key
//  (`editor.themeID`, `appearance.uiThemeID`, or
//  `appearance.editorThemeID`) carries them.
//

import XCTest
@testable import Scribe

@MainActor
final class ThemePreferencesTests: XCTestCase {

    // MARK: - Defaults

    func test_defaults_systemForBothThemesAndFollowEnabled() {
        let suite = "scribe-theme-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs.uiThemeID, .system)
        XCTAssertEqual(prefs.editorThemeID, .system)
        XCTAssertTrue(prefs.editorFollowsUITheme,
                      "First launch should keep editor synced with UI theme")
        XCTAssertEqual(prefs.effectiveEditorThemeID, .system)
    }

    // MARK: - Migration from Phase 15 single-key model

    func test_migration_legacyEditorThemeIDPopulatesBothNewKeys() {
        let suite = "scribe-theme-migrate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Simulate a Phase 15 install: only the legacy key is set,
        // and it points at a theme retired in Phase 39a (Dracula
        // → Midnight via legacyThemeAlias).
        defaults.set("dracula", forKey: "editor.themeID")

        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs.uiThemeID, .midnight,
                       "Legacy Dracula should migrate to Midnight as the new global UI theme")
        XCTAssertEqual(prefs.editorThemeID, .midnight,
                       "Legacy Dracula should also seed the editor-specific slot")
        XCTAssertTrue(prefs.editorFollowsUITheme,
                      "Default to coupled so the user's previous look keeps appearing as one theme")
    }

    func test_migration_newKeysWinOverLegacyWhenBothPresent() {
        // Once Phase 36 has written its own keys the legacy key is
        // ignored — otherwise downgrading and re-upgrading would
        // overwrite the user's later choice. Phase 39a — both raw
        // values now come from the retired catalog and migrate
        // independently (Monokai → Inkwell wins as the explicit
        // uiThemeID pick).
        let suite = "scribe-theme-newkey-wins-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("dracula", forKey: "editor.themeID")
        defaults.set("monokai", forKey: "appearance.uiThemeID")

        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs.uiThemeID, .inkwell,
                       "Monokai stored under the new key wins and migrates to Inkwell")
    }

    // MARK: - Phase 39a legacy alias coverage

    func test_migration_phase39LegacyAliasMaps() {
        // Each retired raw value should land on its documented
        // Phase 39a counterpart. One round-trip per mapping so a
        // future drift in the alias dict is caught immediately.
        let mappings: [(String, ThemeID)] = [
            ("lightDefault",   .daylight),
            ("darkDefault",    .inkwell),
            ("solarizedLight", .sand),
            ("solarizedDark",  .midnight),
            ("dracula",        .midnight),
            ("monokai",        .inkwell),
            ("githubLight",    .daylight)
        ]

        for (raw, expected) in mappings {
            let suite = "scribe-theme-39a-alias-\(raw)-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(raw, forKey: "appearance.uiThemeID")

            let prefs = EditorPreferences(defaults: defaults)
            XCTAssertEqual(prefs.uiThemeID, expected,
                           "Legacy raw '\(raw)' must migrate to .\(expected.rawValue)")
        }
    }

    // MARK: - Effective resolution

    func test_effectiveEditorThemeID_followsUIWhenToggleOn() {
        let suite = "scribe-theme-effective-on-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = EditorPreferences(defaults: defaults)
        prefs.editorFollowsUITheme = true
        prefs.uiThemeID = .daylight
        prefs.editorThemeID = .midnight

        XCTAssertEqual(prefs.effectiveEditorThemeID, .daylight,
                       "When following, the editor must read uiThemeID")
    }

    func test_effectiveEditorThemeID_decoupleWhenToggleOff() {
        let suite = "scribe-theme-effective-off-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = EditorPreferences(defaults: defaults)
        prefs.editorFollowsUITheme = false
        prefs.uiThemeID = .daylight
        prefs.editorThemeID = .midnight

        XCTAssertEqual(prefs.effectiveEditorThemeID, .midnight,
                       "When decoupled, the editor must read editorThemeID")
    }

    // MARK: - Persistence round-trips

    func test_persistence_uiThemeIDSurvivesReinit() {
        let suite = "scribe-theme-persist-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = EditorPreferences(defaults: defaults)
        first.uiThemeID = .midnight

        let reborn = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reborn.uiThemeID, .midnight)
    }

    func test_persistence_editorThemeIDSurvivesReinit() {
        let suite = "scribe-theme-persist-editor-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = EditorPreferences(defaults: defaults)
        first.editorThemeID = .inkwell

        let reborn = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reborn.editorThemeID, .inkwell)
    }

    func test_persistence_editorFollowsUIThemeSurvivesReinit() {
        let suite = "scribe-theme-persist-follow-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = EditorPreferences(defaults: defaults)
        first.editorFollowsUITheme = false

        let reborn = EditorPreferences(defaults: defaults)
        XCTAssertFalse(reborn.editorFollowsUITheme,
                       "Toggling off must persist across launches — otherwise users would silently re-couple after restart")
    }

    // MARK: - Theme.ui* fields are populated for every preset

    func test_uiPalette_everyThemeHasNonZeroFields() {
        // Sanity check that each Theme constant got the Phase 36
        // ui* slots filled. A zero accent across the board would
        // mean a constructor was committed with `0x000000`
        // placeholders — readable on dark, invisible on light.
        let appearance = NSAppearance(named: .aqua)!
        for id in ThemeID.allCases {
            let theme = id.resolve(appearance: appearance)
            XCTAssertGreaterThan(theme.uiAccent, 0,
                                 "\(id.rawValue) has uiAccent == 0 — palette likely incomplete")
            XCTAssertGreaterThan(theme.uiSidebarBackground, 0,
                                 "\(id.rawValue) has uiSidebarBackground == 0")
            XCTAssertGreaterThan(theme.uiPrimaryText, 0,
                                 "\(id.rawValue) has uiPrimaryText == 0")
        }
    }
}
