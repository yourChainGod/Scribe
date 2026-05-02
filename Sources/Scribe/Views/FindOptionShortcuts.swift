//
//  FindOptionShortcuts.swift
//  Phase 49a — keyboard parity with VS Code for the inline find bar
//  and the Find-in-Files sidebar. Both surfaces render the same three
//  toggles (`Aa` / `ab|` / `.*`); centralizing the bindings here keeps
//  the two callsites in lock-step and lets unit tests assert the
//  letter + modifier set without spinning up SwiftUI.
//

import SwiftUI

/// The three boolean toggles surfaced by every find-mode chrome:
/// match-case, whole-word, and regex. Used as the ID for shortcut /
/// tooltip lookups so the call sites only have to reference the option
/// once.
enum FindOption: CaseIterable {
    case matchCase
    case wholeWord
    case regex
}

/// Static shortcut catalog for `FindOption`. VS Code on macOS binds
/// these to ⌘⌥C / ⌘⌥W / ⌘⌥R; we mirror those so users with the muscle
/// memory don't have to relearn anything.
enum FindOptionShortcuts {
    /// `KeyEquivalent` consumed by `View.keyboardShortcut`.
    static func keyEquivalent(for option: FindOption) -> KeyEquivalent {
        switch option {
        case .matchCase: return "c"
        case .wholeWord: return "w"
        case .regex:     return "r"
        }
    }

    /// Modifier set is `[.command, .option]` for every option. Kept as
    /// a function (not a constant) so future per-option overrides
    /// don't have to refactor the call sites.
    static func modifiers(for option: FindOption) -> EventModifiers {
        [.command, .option]
    }

    /// Plain `Character` accessor so `XCTestCase` files don't need to
    /// import SwiftUI just to reach `KeyEquivalent.character`.
    static func character(for option: FindOption) -> Character {
        keyEquivalent(for: option).character
    }

    /// Visual suffix appended after the localized option label inside
    /// `.help(_:)` tooltips. Renders as e.g. ` (⌘⌥C)`. The leading
    /// space is intentional — call sites concatenate this onto an
    /// already-localized string.
    static func helpSuffix(for option: FindOption) -> String {
        let letter = String(character(for: option)).uppercased()
        return " (⌘⌥\(letter))"
    }
}

extension View {
    /// Sugar for `keyboardShortcut(.., modifiers:)` that pulls both
    /// values from `FindOptionShortcuts`. Keeps callsites readable:
    /// `optionToggle(...).findOptionShortcut(for: .matchCase)`.
    @MainActor
    func findOptionShortcut(for option: FindOption) -> some View {
        keyboardShortcut(
            FindOptionShortcuts.keyEquivalent(for: option),
            modifiers: FindOptionShortcuts.modifiers(for: option)
        )
    }
}
