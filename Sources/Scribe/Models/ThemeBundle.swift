//
//  ThemeBundle.swift
//  Phase 61 — JSON serialisation envelope around a single theme's
//  custom slot overrides. Lets users share / back up / restore the
//  Style Configurator state via plain `.scribetheme` files.
//
//  Format
//
//    { "version": 1,
//      "themeID":  "inkwell",
//      "slots":    { "background": 1973790, "foreground": 16119285, ... } }
//
//  * `version` is a forward-compat marker; we bump it whenever the
//    schema changes shape (e.g. if Phase 62 adds per-lexer slots).
//    Decoders refuse versions newer than they understand instead of
//    silently dropping fields.
//  * `themeID` is the catalog preset the overrides target. Imports
//    re-route through `EditorPreferences.legacyThemeAlias` so a
//    stored `lightDefault` blob still applies to its modern
//    equivalent (`.daylight`).
//  * `slots` keys are the raw values of `ThemeSlot` (matching the
//    persisted-defaults format), and the integer values are the
//    same RGB hex `Theme` already stores. Reusing both the key
//    and value formats means the on-disk and in-memory shapes
//    only differ at the wrapper level.
//

import Foundation

/// Versioned envelope serialised into `.scribetheme` files.
struct ThemeBundle: Codable, Equatable, Sendable {
    /// Bumped on every schema change. Phase 61 ships v1.
    static let currentVersion = 1

    let version: Int
    /// Theme preset the slots target. Plain `String` instead of
    /// `ThemeID.rawValue` so a future enum change doesn't break
    /// the JSON shape; the import path resolves the alias map
    /// before applying.
    let themeID: String
    /// Slot → packed RGB hex. Same convention `Theme` uses.
    let slots: [String: Int]

    /// Convenience init that snapshots the current overrides for
    /// a given preset. Pulls from `EditorPreferences` so the
    /// caller doesn't have to know about the `[ThemeSlot: Int]`
    /// shape the prefs store internally.
    init(themeID: ThemeID,
         overrides: ThemeOverrides) {
        self.version = Self.currentVersion
        self.themeID = themeID.rawValue
        self.slots = Dictionary(
            uniqueKeysWithValues: overrides.slots.map { ($0.key.rawValue, $0.value) }
        )
    }

    /// Memberwise init for tests and the decoder path.
    init(version: Int,
         themeID: String,
         slots: [String: Int]) {
        self.version = version
        self.themeID = themeID
        self.slots = slots
    }
}

enum ThemeBundleError: Error, Equatable {
    case unsupportedVersion(Int)
    case unknownThemeID(String)
    case decodeFailed
}

enum ThemeBundleIO {

    /// Serialise the user's overrides for `themeID` into JSON
    /// bytes ready to write to disk. Pretty-printed (sortedKeys
    /// + .prettyPrinted) so the resulting file is human-diff-able
    /// and stable enough for git review.
    static func encode(themeID: ThemeID,
                       overrides: ThemeOverrides) throws -> Data {
        let bundle = ThemeBundle(themeID: themeID, overrides: overrides)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    /// Decode `.scribetheme` JSON → `(ThemeID, ThemeOverrides)`.
    /// Returns the resolved enum case (after walking the
    /// legacy-theme alias map) and a clean overrides map ready to
    /// hand to `EditorPreferences.setOverride`.
    static func decode(_ data: Data) throws -> (themeID: ThemeID,
                                                overrides: ThemeOverrides) {
        let bundle: ThemeBundle
        do {
            bundle = try JSONDecoder().decode(ThemeBundle.self, from: data)
        } catch {
            throw ThemeBundleError.decodeFailed
        }
        guard bundle.version <= ThemeBundle.currentVersion else {
            throw ThemeBundleError.unsupportedVersion(bundle.version)
        }
        guard let themeID = resolveThemeID(bundle.themeID) else {
            throw ThemeBundleError.unknownThemeID(bundle.themeID)
        }
        // Drop unknown slot strings rather than rejecting the
        // whole file — a slot we shipped under one name and then
        // renamed should still partially apply.
        var resolved = ThemeOverrides()
        for (rawKey, color) in bundle.slots {
            guard let slot = ThemeSlot(rawValue: rawKey) else { continue }
            resolved.slots[slot] = color
        }
        return (themeID, resolved)
    }

    // MARK: - Internals

    /// Re-implemented locally so this module doesn't reach into
    /// `EditorPreferences.legacyThemeAlias` (which is `private`
    /// to that file). Mirrors the rule: try the modern enum case
    /// first, fall back to the alias map for renamed presets.
    private static func resolveThemeID(_ raw: String) -> ThemeID? {
        if let direct = ThemeID(rawValue: raw) { return direct }
        // Phase 39a alias map. Re-stating it here means a future
        // alias addition has to update both copies — which we
        // intentionally accept so this module stays self-contained.
        switch raw {
        case "lightDefault":   return .daylight
        case "darkDefault":    return .inkwell
        case "solarizedLight": return .sand
        case "solarizedDark":  return .midnight
        case "dracula":        return .midnight
        case "monokai":        return .inkwell
        case "githubLight":    return .daylight
        default:               return nil
        }
    }
}
