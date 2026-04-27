//
//  ThemeCatalogTests.swift
//  Phase 15 — covers the ThemeID dispatch + EditorPreferences
//  persistence so a regression in either gets caught at test time.
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
            ThemeID.solarizedDark.resolve(appearance: appearance).background,
            Theme.solarizedDark.background
        )
        XCTAssertEqual(
            ThemeID.dracula.resolve(appearance: appearance).background,
            Theme.dracula.background
        )
        XCTAssertEqual(
            ThemeID.monokai.resolve(appearance: appearance).background,
            Theme.monokai.background
        )
        XCTAssertEqual(
            ThemeID.githubLight.resolve(appearance: appearance).background,
            Theme.githubLight.background
        )
    }

    func test_themeID_systemFollowsAppearance() {
        let aqua = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!
        XCTAssertEqual(ThemeID.system.resolve(appearance: aqua).background,
                       Theme.lightDefault.background)
        XCTAssertEqual(ThemeID.system.resolve(appearance: dark).background,
                       Theme.darkDefault.background)
    }

    func test_themeID_isDarkClassifies() {
        XCTAssertTrue(ThemeID.dracula.isDark)
        XCTAssertTrue(ThemeID.solarizedDark.isDark)
        XCTAssertTrue(ThemeID.monokai.isDark)
        XCTAssertTrue(ThemeID.darkDefault.isDark)
        XCTAssertFalse(ThemeID.lightDefault.isDark)
        XCTAssertFalse(ThemeID.solarizedLight.isDark)
        XCTAssertFalse(ThemeID.githubLight.isDark)
    }

    func test_themeID_displayNamesAreUnique() {
        let names = ThemeID.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count,
                       "every theme entry needs a distinct display name")
    }

    func test_themeID_allCasesHaveDistinctPalettes() {
        let appearance = NSAppearance(named: .aqua)!
        // Two light themes can share a pure-white background (Scribe
        // Light + GitHub Light both use #FFFFFF), so identity is
        // measured against a multi-colour fingerprint instead.
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
        XCTAssertEqual(first.themeID, .system, "default falls back to system")

        first.themeID = .dracula
        // Force the didSet to flush by accessing via a fresh instance.
        let reborn = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reborn.themeID, .dracula)
    }

    func test_editorPreferences_themeIDFallsBackOnUnknownValue() {
        let suite = "scribe-theme-fallback-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("nonexistentTheme", forKey: "editor.themeID")

        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs.themeID, .system,
                       "unknown raw value should round-trip to .system")
    }
}
