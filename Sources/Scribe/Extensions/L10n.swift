//
//  L10n.swift
//  Localisation helper for code paths that produce plain `String`
//  values (not SwiftUI `Text` views, which already pick up
//  `LocalizedStringKey` via `bundle: .module` directly).
//
//  Phase 27 — replaces every hand-rolled NSLocalizedString call so
//  the lookup site stays terse and we can swap the underlying
//  mechanism (e.g. switch to xcstrings) in one place later.
//
//  Conventions
//    • Keys are dotted, semantic ("tab.untitled", not "Untitled").
//    • The `value:` parameter is left nil so a missing key surfaces
//      as the key itself in the UI — visible, easy to grep for.
//    • Variadic-args overload formats with the `String(format:)`
//      machinery, identical to NSLocalizedString chaining.
//

import Foundation

enum L10n {
    /// Look up `key` in `Bundle.module/Localizable.strings`. Falls
    /// back to the key itself when no translation is found, so a
    /// missing entry is loud rather than silent.
    static func t(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Look up `key` and apply `String(format:)` with `args`. Useful
    /// for status-bar style strings like "Ln %lld, Col %lld".
    static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = Bundle.module.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, arguments: args)
    }
}
