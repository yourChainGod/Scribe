//
//  ThemeOverrides.swift
//  Phase 39b — sparse per-slot user overrides layered on top of a
//  built-in `Theme` preset. Lets a user pin individual colours of
//  any catalog theme (e.g. paint Daylight's accent red) without
//  having to fork or duplicate the entire palette.
//
//  Storage shape (deliberate):
//    – Sparse `[ThemeSlot: Int]` — missing keys defer to the base
//      preset, so future palette refreshes (e.g. shifting Inkwell's
//      default sidebar background) reach users who have only ever
//      overridden one or two slots.
//    – Per-theme `[ThemeID: ThemeOverrides]` map kept in
//      `EditorPreferences` so each preset has its own customization
//      slate. Switching from Daylight (red accent override) to
//      Inkwell shows Inkwell's native blue, not the red carried
//      over from another theme.
//
//  JSON encoding: at the persistence boundary we collapse the outer
//  map to `[String: ThemeOverrides]` because `JSONEncoder` rejects
//  enum-keyed dictionaries (SE-0250 covers Codable but JSON output
//  still requires String keys). String keys also let us survive
//  enum case removals — a future drop of `.midnight` won't crash
//  decode; the orphan key just goes ignored after one launch.
//

import Foundation

/// Phase 39b — slot category. Drives the Settings UI grouping into
/// Editor (13 syntax/document slots) vs UI Chrome (11 surrounding
/// surface slots), but the runtime resolution path doesn't care
/// about category — it iterates every slot regardless.
enum SlotCategory: String, Codable, Sendable, CaseIterable {
    case editor
    case ui
}

/// One overridable colour position in a `Theme`. RawValue matches
/// the `Theme` field name so the JSON key is stable across
/// renames and so `Theme.applying(_:)` can use a switch instead of
/// reflection.
///
/// Ordering matters for Settings UI — slots are listed in this
/// declaration order inside their category disclosure group.
enum ThemeSlot: String, CaseIterable, Codable, Sendable {
    // MARK: Editor (13)
    case background
    case foreground
    case caret
    case selectionBackground
    case marginBackground
    case marginForeground
    case keyword
    case string
    case comment
    case number
    case preprocessor
    case type
    case identifier

    // MARK: UI chrome (11)
    case uiWindowBackground
    case uiSidebarBackground
    case uiBarBackground
    case uiPanelBackground
    case uiAccent
    case uiAccentText
    case uiPrimaryText
    case uiSecondaryText
    case uiTertiaryText
    case uiSeparator
    case uiSelection

    /// Whether this slot affects Scintilla (editor) or the SwiftUI
    /// chrome (ui). Drives Settings UI grouping AND the "which
    /// theme map am I writing to?" routing — when
    /// `editorFollowsUITheme = false`, editor slots target the
    /// editor theme's override map, UI slots target the UI theme's.
    var category: SlotCategory {
        switch self {
        case .background, .foreground, .caret, .selectionBackground,
             .marginBackground, .marginForeground,
             .keyword, .string, .comment, .number,
             .preprocessor, .type, .identifier:
            return .editor
        case .uiWindowBackground, .uiSidebarBackground, .uiBarBackground,
             .uiPanelBackground, .uiAccent, .uiAccentText,
             .uiPrimaryText, .uiSecondaryText, .uiTertiaryText,
             .uiSeparator, .uiSelection:
            return .ui
        }
    }

    /// Localization key for the slot label shown in Settings.
    /// Matches strings written in `settings.appearance.slot.<rawValue>`
    /// across `en.lproj` / `zh-Hans.lproj`.
    var displayKey: String {
        "settings.appearance.slot.\(rawValue)"
    }

    /// Convenience: iterate slots in declaration order, filtered by
    /// category. Used by Settings UI to populate the two
    /// disclosure groups.
    static func slots(in category: SlotCategory) -> [ThemeSlot] {
        Self.allCases.filter { $0.category == category }
    }
}

/// Sparse per-theme override map. An empty `slots` value means "no
/// overrides" — the base Theme is returned untouched by
/// `Theme.applying(_:)`. Equality is structural so two override
/// maps with the same slots compare equal regardless of insertion
/// order.
struct ThemeOverrides: Codable, Equatable, Sendable {
    var slots: [ThemeSlot: Int]

    init(slots: [ThemeSlot: Int] = [:]) {
        self.slots = slots
    }

    /// True iff no slot is overridden. Used by callers to decide
    /// whether a per-theme map entry can be removed entirely (we
    /// keep the persistence map sparse as well — empty entries
    /// would clutter the JSON without providing meaning).
    var isEmpty: Bool { slots.isEmpty }
}

extension Theme {
    /// Return a copy with each non-nil slot in `overrides` swapped
    /// in. Empty `overrides` returns an identity copy.
    ///
    /// Implemented as an explicit per-field switch (not reflection)
    /// so adding a new slot to `Theme` triggers a compiler error
    /// if this method isn't updated — the safest place to forget
    /// would be otherwise invisible.
    func applying(_ overrides: ThemeOverrides) -> Theme {
        guard !overrides.isEmpty else { return self }

        func pick(_ slot: ThemeSlot, _ fallback: Int) -> Int {
            overrides.slots[slot] ?? fallback
        }

        return Theme(
            background:          pick(.background,          background),
            foreground:          pick(.foreground,          foreground),
            caret:               pick(.caret,               caret),
            selectionBackground: pick(.selectionBackground, selectionBackground),
            marginBackground:    pick(.marginBackground,    marginBackground),
            marginForeground:    pick(.marginForeground,    marginForeground),
            keyword:             pick(.keyword,             keyword),
            string:              pick(.string,              string),
            comment:             pick(.comment,             comment),
            number:              pick(.number,              number),
            preprocessor:        pick(.preprocessor,        preprocessor),
            type:                pick(.type,                type),
            identifier:          pick(.identifier,          identifier),
            uiWindowBackground:  pick(.uiWindowBackground,  uiWindowBackground),
            uiSidebarBackground: pick(.uiSidebarBackground, uiSidebarBackground),
            uiBarBackground:     pick(.uiBarBackground,     uiBarBackground),
            uiPanelBackground:   pick(.uiPanelBackground,   uiPanelBackground),
            uiAccent:            pick(.uiAccent,            uiAccent),
            uiAccentText:        pick(.uiAccentText,        uiAccentText),
            uiPrimaryText:       pick(.uiPrimaryText,       uiPrimaryText),
            uiSecondaryText:     pick(.uiSecondaryText,     uiSecondaryText),
            uiTertiaryText:      pick(.uiTertiaryText,      uiTertiaryText),
            uiSeparator:         pick(.uiSeparator,         uiSeparator),
            uiSelection:         pick(.uiSelection,         uiSelection)
        )
    }

    /// Read a single slot from this theme. Mirrors the
    /// `Theme.applying(_:)` switch so the Settings UI can ask
    /// "what's the *current* colour for this slot?" without having
    /// to know whether the value is overridden or base.
    func value(for slot: ThemeSlot) -> Int {
        switch slot {
        case .background:          return background
        case .foreground:          return foreground
        case .caret:               return caret
        case .selectionBackground: return selectionBackground
        case .marginBackground:    return marginBackground
        case .marginForeground:    return marginForeground
        case .keyword:             return keyword
        case .string:              return string
        case .comment:             return comment
        case .number:              return number
        case .preprocessor:        return preprocessor
        case .type:                return type
        case .identifier:          return identifier
        case .uiWindowBackground:  return uiWindowBackground
        case .uiSidebarBackground: return uiSidebarBackground
        case .uiBarBackground:     return uiBarBackground
        case .uiPanelBackground:   return uiPanelBackground
        case .uiAccent:            return uiAccent
        case .uiAccentText:        return uiAccentText
        case .uiPrimaryText:       return uiPrimaryText
        case .uiSecondaryText:     return uiSecondaryText
        case .uiTertiaryText:      return uiTertiaryText
        case .uiSeparator:         return uiSeparator
        case .uiSelection:         return uiSelection
        }
    }
}
