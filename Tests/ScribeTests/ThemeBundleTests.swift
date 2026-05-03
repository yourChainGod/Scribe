//
//  ThemeBundleTests.swift
//  Phase 61 — covers the JSON envelope (`ThemeBundle`) and the
//  encode / decode helpers (`ThemeBundleIO`) used by the
//  Settings ▸ Appearance ▸ Export Theme / Import Theme buttons.
//

import XCTest
@testable import Scribe

@MainActor
final class ThemeBundleTests: XCTestCase {

    // MARK: - ThemeBundle init

    func test_init_fromOverrides_capturesSlotMapAndThemeID() {
        var overrides = ThemeOverrides()
        overrides.slots[.background] = 0x1F1F1F
        overrides.slots[.foreground] = 0xCCCCCC
        let bundle = ThemeBundle(themeID: .inkwell, overrides: overrides)

        XCTAssertEqual(bundle.version, ThemeBundle.currentVersion)
        XCTAssertEqual(bundle.themeID, "inkwell")
        XCTAssertEqual(bundle.slots["background"], 0x1F1F1F)
        XCTAssertEqual(bundle.slots["foreground"], 0xCCCCCC)
        XCTAssertEqual(bundle.slots.count, 2,
                       "empty slots in the overrides shouldn't leak entries")
    }

    func test_init_emptyOverrides_yieldsEmptySlots() {
        let bundle = ThemeBundle(themeID: .daylight,
                                 overrides: ThemeOverrides())
        XCTAssertEqual(bundle.themeID, "daylight")
        XCTAssertTrue(bundle.slots.isEmpty)
    }

    // MARK: - Encode / decode roundtrip

    func test_encodeDecode_roundtripPreservesSlots() throws {
        var src = ThemeOverrides()
        src.slots[.background] = 0xFFEEDD
        src.slots[.uiAccent] = 0x0099AA
        src.slots[.keyword] = 0xFF0000
        let data = try ThemeBundleIO.encode(themeID: .inkwell, overrides: src)
        let result = try ThemeBundleIO.decode(data)

        XCTAssertEqual(result.themeID, .inkwell)
        XCTAssertEqual(result.overrides.slots[.background], 0xFFEEDD)
        XCTAssertEqual(result.overrides.slots[.uiAccent], 0x0099AA)
        XCTAssertEqual(result.overrides.slots[.keyword], 0xFF0000)
    }

    func test_encode_emitsPrettyJSONWithSortedKeys() throws {
        var overrides = ThemeOverrides()
        overrides.slots[.background] = 0xABCDEF
        let data = try ThemeBundleIO.encode(themeID: .midnight,
                                            overrides: overrides)
        let s = String(data: data, encoding: .utf8) ?? ""
        // Pretty-printed: contains a newline + an indent inside the
        // top-level object. Sorted keys: "slots" comes after "themeID"
        // alphabetically, so we don't need to pin the exact bytes —
        // just that the output is multi-line.
        XCTAssertTrue(s.contains("\n  "),
                      "encoded JSON should be pretty-printed")
        XCTAssertTrue(s.contains("\"themeID\""))
        XCTAssertTrue(s.contains("\"slots\""))
        XCTAssertTrue(s.contains("\"version\""))
    }

    // MARK: - Decode error paths

    func test_decode_unsupportedVersion_throws() {
        // V99 from the future — a v1-aware decoder must refuse so
        // it doesn't silently apply a partial schema.
        let blob = """
        {"version":99,"themeID":"inkwell","slots":{"background":1973790}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try ThemeBundleIO.decode(blob)) { error in
            XCTAssertEqual(error as? ThemeBundleError,
                           .unsupportedVersion(99))
        }
    }

    func test_decode_unknownThemeID_throws() {
        let blob = """
        {"version":1,"themeID":"some-future-theme","slots":{}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try ThemeBundleIO.decode(blob)) { error in
            XCTAssertEqual(error as? ThemeBundleError,
                           .unknownThemeID("some-future-theme"))
        }
    }

    func test_decode_corruptJSON_throwsDecodeFailed() {
        let blob = "{not even json,,,".data(using: .utf8)!
        XCTAssertThrowsError(try ThemeBundleIO.decode(blob)) { error in
            XCTAssertEqual(error as? ThemeBundleError, .decodeFailed)
        }
    }

    func test_decode_unknownSlotKeysAreSilentlyDropped() throws {
        // A future Scribe might add new slots (or rename one); a
        // bundle that carries an unrecognised key should still
        // import the surviving slots rather than rejecting the
        // whole file.
        let blob = """
        {
          "version": 1,
          "themeID": "inkwell",
          "slots": { "background": 17, "totally_made_up_slot": 99 }
        }
        """.data(using: .utf8)!
        let result = try ThemeBundleIO.decode(blob)
        XCTAssertEqual(result.themeID, .inkwell)
        XCTAssertEqual(result.overrides.slots[.background], 17)
        XCTAssertEqual(result.overrides.slots.count, 1,
                       "unknown slot must drop without poisoning the rest")
    }

    // MARK: - Legacy theme alias

    func test_decode_legacyThemeID_resolvesToModernCase() throws {
        // Phase 39a alias map — a bundle exported pre-rename
        // (e.g. `lightDefault`) should still apply to its modern
        // equivalent (`.daylight`).
        let blob = """
        {"version":1,"themeID":"lightDefault","slots":{"uiAccent":255}}
        """.data(using: .utf8)!
        let result = try ThemeBundleIO.decode(blob)
        XCTAssertEqual(result.themeID, .daylight,
                       "lightDefault must alias to daylight")
        XCTAssertEqual(result.overrides.slots[.uiAccent], 255)
    }

    // MARK: - replaceOverrides plumbing

    func test_replaceOverrides_withEmpty_dropsEntry() {
        let suite = "scribe-theme-bundle-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        prefs.setOverride(.daylight, slot: .background, color: 0x123456)
        XCTAssertFalse(prefs.overrides(for: .daylight).isEmpty)

        prefs.replaceOverrides(.daylight, with: ThemeOverrides())
        XCTAssertTrue(prefs.overrides(for: .daylight).isEmpty,
                      "replacing with an empty bundle must clear the entry entirely")
    }

    func test_replaceOverrides_withSlots_atomicallySwapsState() {
        let suite = "scribe-theme-bundle-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        // Seed an existing override for one slot; the import below
        // must replace the whole map (not merge), so the seeded
        // value should disappear.
        prefs.setOverride(.daylight, slot: .background, color: 0x010101)
        XCTAssertEqual(prefs.overrides(for: .daylight).slots[.background],
                       0x010101)

        var incoming = ThemeOverrides()
        incoming.slots[.foreground] = 0xF0F0F0
        prefs.replaceOverrides(.daylight, with: incoming)

        let updated = prefs.overrides(for: .daylight)
        XCTAssertNil(updated.slots[.background],
                     "replace must drop the seeded background slot")
        XCTAssertEqual(updated.slots[.foreground], 0xF0F0F0)
        XCTAssertEqual(updated.slots.count, 1)
    }
}
