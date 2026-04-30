//
//  ThemeOverridesTests.swift
//  Phase 39b — covers the per-theme override layer: the
//  `ThemeOverrides` struct, `Theme.applying(_:)` merge,
//  EditorPreferences mutation helpers, persistence (including
//  legacy alias migration of the outer JSON keys), and the
//  subscript-mutation footgun guard.
//

import XCTest
@testable import Scribe

@MainActor
final class ThemeOverridesTests: XCTestCase {

    // MARK: - Theme.applying

    func test_applying_emptyOverridesReturnsIdentity() {
        let theme = Theme.daylight
        let result = theme.applying(ThemeOverrides())
        XCTAssertEqual(theme, result,
                       "Empty overrides must short-circuit and return the base palette unchanged.")
    }

    func test_applying_singleSlotSwapsThatSlotOnly() {
        let theme = Theme.inkwell
        let red = 0xFF0000
        let overrides = ThemeOverrides(slots: [.uiAccent: red])
        let result = theme.applying(overrides)

        XCTAssertEqual(result.uiAccent, red,
                       "Overridden slot must carry the new colour.")
        // Sample a couple of unrelated slots to make sure the
        // applying() switch isn't accidentally broadcasting.
        XCTAssertEqual(result.background, theme.background)
        XCTAssertEqual(result.foreground, theme.foreground)
        XCTAssertEqual(result.uiSidebarBackground, theme.uiSidebarBackground)
    }

    func test_applying_doesNotMutateBase() {
        let baseAccent = Theme.daylight.uiAccent
        let overrides = ThemeOverrides(slots: [.uiAccent: 0x00FF00])
        _ = Theme.daylight.applying(overrides)

        XCTAssertEqual(Theme.daylight.uiAccent, baseAccent,
                       "applying() must return a new value; the static catalog entry stays pristine.")
    }

    func test_applying_coversEverySlot() {
        // Override every slot with an arbitrary distinguishable
        // value; every read on the result should match.
        let theme = Theme.daylight
        var slots: [ThemeSlot: Int] = [:]
        for (idx, slot) in ThemeSlot.allCases.enumerated() {
            slots[slot] = 0x010000 + idx   // unique per slot
        }
        let result = theme.applying(ThemeOverrides(slots: slots))
        for slot in ThemeSlot.allCases {
            XCTAssertEqual(result.value(for: slot), slots[slot],
                           "applying() forgot to swap slot \(slot.rawValue) — likely missing case in the constructor switch.")
        }
    }

    // MARK: - Codable round-trip

    func test_codable_roundTripPreservesSparseMap() throws {
        let original = ThemeOverrides(slots: [
            .background: 0x111111,
            .uiAccent:   0xFF00FF
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThemeOverrides.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_codable_roundTripPreservesEmpty() throws {
        let original = ThemeOverrides()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThemeOverrides.self, from: data)
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - EditorPreferences helpers

    func test_setOverride_persistsViaPublishedDidSet() {
        let suite = "scribe-ovr-set-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = EditorPreferences(defaults: defaults)
        prefs.setOverride(.midnight, slot: .uiAccent, color: 0xFF0000)

        let reborn = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reborn.overrides(for: .midnight).slots[.uiAccent], 0xFF0000,
                       "setOverride must round-trip through UserDefaults JSON storage.")
    }

    func test_clearOverride_returnsSlotToBaseColour() {
        let suite = "scribe-ovr-clear-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = EditorPreferences(defaults: defaults)
        prefs.setOverride(.daylight, slot: .uiAccent, color: 0xFF0000)
        XCTAssertEqual(prefs.overrides(for: .daylight).slots[.uiAccent], 0xFF0000)

        prefs.clearOverride(.daylight, slot: .uiAccent)
        XCTAssertNil(prefs.overrides(for: .daylight).slots[.uiAccent],
                     "clearOverride must remove the slot from the sparse map (NOT pin it to the base value).")
        XCTAssertTrue(prefs.overrides(for: .daylight).isEmpty,
                      "Last override removed → entry collapsed to empty (and dropped from outer map).")
    }

    func test_perThemeIsolation() {
        let suite = "scribe-ovr-isolate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = EditorPreferences(defaults: defaults)
        prefs.setOverride(.midnight, slot: .uiAccent, color: 0xFF0000)

        XCTAssertEqual(prefs.overrides(for: .midnight).slots[.uiAccent], 0xFF0000)
        XCTAssertNil(prefs.overrides(for: .daylight).slots[.uiAccent],
                     "Customizing Midnight must not bleed into Daylight's override map.")
        XCTAssertNil(prefs.overrides(for: .inkwell).slots[.uiAccent])
    }

    func test_clearAllOverrides_dropsEntireThemeEntry() {
        let suite = "scribe-ovr-clearall-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = EditorPreferences(defaults: defaults)
        prefs.setOverride(.inkwell, slot: .uiAccent, color: 0x00FF00)
        prefs.setOverride(.inkwell, slot: .background, color: 0x000000)
        XCTAssertEqual(prefs.overrides(for: .inkwell).slots.count, 2)

        prefs.clearAllOverrides(.inkwell)
        XCTAssertTrue(prefs.overrides(for: .inkwell).isEmpty)
    }

    // MARK: - Persistence resilience

    func test_persistence_legacyAliasOnOuterKeysMigrates() throws {
        // Simulate a stored blob written by a hypothetical
        // pre-Phase-39 build that knew about Dracula. After load
        // the override should resurface under .midnight (Dracula's
        // Phase 39a alias target).
        let suite = "scribe-ovr-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let stored: [String: ThemeOverrides] = [
            "dracula": ThemeOverrides(slots: [.uiAccent: 0xABCDEF])
        ]
        let blob = try JSONEncoder().encode(stored)
        defaults.set(blob, forKey: "appearance.themeOverrides")

        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs.overrides(for: .midnight).slots[.uiAccent], 0xABCDEF,
                       "Legacy outer key 'dracula' must collapse onto .midnight per legacyThemeAlias.")
        XCTAssertNil(prefs.themeOverrides[ThemeID(rawValue: "dracula") ?? .system]?.slots[.uiAccent],
                     "There should be no entry under a synthetic legacy key after load.")
    }

    func test_persistence_corruptBlobFailsSilentlyToEmpty() {
        let suite = "scribe-ovr-corrupt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]),
                     forKey: "appearance.themeOverrides")

        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertTrue(prefs.themeOverrides.isEmpty,
                      "Corrupt blob must not crash init; we land on an empty map.")
    }

    // MARK: - Subscript mutation behaviour

    func test_subscriptMutation_alsoPersistsViaSetterWriteback() {
        // Optional-chain subscript assignment on a struct-valued
        // dictionary IS a setter call on the outer property — Swift
        // expands `prefs.themeOverrides[k]?.slots[s] = v` into a
        // get-mutate-set sequence that ends with an assignment to
        // `prefs.themeOverrides`, firing `@Published.didSet` and
        // running `persistThemeOverrides()`.
        //
        // We document `setOverride/clearOverride` as the canonical
        // write path for clarity (and so the helpers can grow guards
        // like collision checks), but call sites that go through the
        // raw subscript still get persistence — verify that here so
        // future contributors don't add a misleading "guard" against
        // a footgun that never existed.
        let suite = "scribe-ovr-subscript-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = EditorPreferences(defaults: defaults)
        prefs.setOverride(.daylight, slot: .uiAccent, color: 0x111111)
        prefs.themeOverrides[.daylight]?.slots[.uiAccent] = 0x222222

        let reborn = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reborn.overrides(for: .daylight).slots[.uiAccent], 0x222222,
                       "Subscript mutation through @Published must persist — Swift's get-mutate-set expansion does fire the property setter.")
    }
}
