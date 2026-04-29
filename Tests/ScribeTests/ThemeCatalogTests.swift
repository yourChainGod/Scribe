//
//  ThemeCatalogTests.swift
//  Phase 15 — covers the ThemeID dispatch + EditorPreferences
//  persistence so a regression in either gets caught at test time.
//  Phase 39a — catalog rewritten around macOS-native presets;
//  legacy ID assertions migrate via EditorPreferences.legacyThemeAlias.
//

import XCTest
import AppKit
@testable import Scribe

@MainActor
final class ThemeCatalogTests: XCTestCase {

    // MARK: - ThemeID dispatch

    func test_themeID_resolveSelectsExpectedPalette() {
        let appearance = NSAppearance(named: .aqua)!
        XCTAssertEqual(
            ThemeID.daylight.resolve(appearance: appearance).background,
            Theme.daylight.background
        )
        XCTAssertEqual(
            ThemeID.graphiteLight.resolve(appearance: appearance).background,
            Theme.graphiteLight.background
        )
        XCTAssertEqual(
            ThemeID.sand.resolve(appearance: appearance).background,
            Theme.sand.background
        )
        XCTAssertEqual(
            ThemeID.inkwell.resolve(appearance: appearance).background,
            Theme.inkwell.background
        )
        XCTAssertEqual(
            ThemeID.graphiteDark.resolve(appearance: appearance).background,
            Theme.graphiteDark.background
        )
        XCTAssertEqual(
            ThemeID.midnight.resolve(appearance: appearance).background,
            Theme.midnight.background
        )
    }

    func test_themeID_systemFollowsAppearance() {
        let aqua = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!
        XCTAssertEqual(ThemeID.system.resolve(appearance: aqua).background,
                       Theme.daylight.background)
        XCTAssertEqual(ThemeID.system.resolve(appearance: dark).background,
                       Theme.inkwell.background)
    }

    func test_themeID_isDarkClassifies() {
        XCTAssertTrue(ThemeID.inkwell.isDark)
        XCTAssertTrue(ThemeID.graphiteDark.isDark)
        XCTAssertTrue(ThemeID.midnight.isDark)
        XCTAssertFalse(ThemeID.daylight.isDark)
        XCTAssertFalse(ThemeID.graphiteLight.isDark)
        XCTAssertFalse(ThemeID.sand.isDark)
    }

    func test_themeID_displayNamesAreUnique() {
        let names = ThemeID.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count,
                       "every theme entry needs a distinct display name")
    }

    func test_themeID_allCasesHaveDistinctPalettes() {
        let appearance = NSAppearance(named: .aqua)!
        // Every explicit theme should fingerprint distinctly across
        // the multi-colour key set so even themes with similar
        // backgrounds (e.g. two near-white lights) still register
        // as different palettes.
        let fingerprints: [[Int]] = ThemeID.allCases
            .filter { $0 != .system }
            .map {
                let t = $0.resolve(appearance: appearance)
                return [t.background, t.foreground, t.keyword, t.string, t.comment]
            }
        XCTAssertEqual(Set(fingerprints).count, fingerprints.count,
                       "every explicit theme should have a unique colour fingerprint")
    }

    // MARK: - EditorPreferences persistence

    func test_editorPreferences_themeIDPersistsAcrossInstances() {
        let suite = "scribe-theme-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
        }

        let first = EditorPreferences(defaults: defaults)
        XCTAssertEqual(first.uiThemeID, .system, "default falls back to system")

        first.uiThemeID = .midnight
        // Force the didSet to flush by accessing via a fresh instance.
        let reborn = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reborn.uiThemeID, .midnight)
    }

    func test_editorPreferences_themeIDFallsBackOnUnknownValue() {
        let suite = "scribe-theme-fallback-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("nonexistentTheme", forKey: "appearance.uiThemeID")

        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs.uiThemeID, .system,
                       "unknown raw value should round-trip to .system")
    }
}
