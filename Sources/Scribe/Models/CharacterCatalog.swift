//
//  CharacterCatalog.swift
//  Phase 59 — catalogue of special characters the writer / math
//  author reaches for most often. Grouped by semantic bucket so the
//  picker can render them as collapsible sections:
//
//    * Greek lowercase + uppercase (α–ω / Α–Ω) — used in math &
//      physics prose, LaTeX-style macro replacements.
//    * Math symbols — relational / set / calculus glyphs that are
//      painful to type from macOS's input source alone.
//    * Arrows — left / right / up / down / diagonal. The "Copy
//      a Unicode arrow" question is the #1 reason writers open a
//      character viewer.
//    * Punctuation — em / en dashes, curly quotes, ellipsis,
//      section markers. The "smart quote" substitutes macOS does
//      automatically don't reach all fields (Scintilla disables
//      them), so we expose them here for deliberate insertion.
//    * Currency — the set people actually write in 2026 ($ € £ ¥
//      ₽ ₩ ₺ ₹ …). Skips historical / niche currencies to keep
//      the picker scrollable.
//
//  Every entry carries a stable `name` so the filter-by-text
//  input matches "alpha" ↔ α without the user having to type the
//  glyph. English-only for V1 — zh-Hans aliases ride on top of
//  the name via CJK substring search that's still substring-ok
//  against e.g. "右箭头" if the user types those characters.
//

import Foundation

/// One selectable glyph with its human-readable name. The name is
/// both the accessibility label (so VoiceOver reads "Greek Small
/// Letter Alpha" instead of silent α) and the fuzzy-filter search
/// key the picker matches against.
struct SpecialCharacter: Identifiable, Hashable, Sendable {
    /// UUID keeps SwiftUI lists stable across refreshes even when
    /// two glyphs happen to have the same `value` (this won't
    /// happen in V1's catalog but we shouldn't assume uniqueness).
    let id: UUID
    let value: String
    let name: String

    init(_ value: String,
         _ name: String,
         id: UUID = UUID()) {
        self.id = id
        self.value = value
        self.name = name
    }
}

/// A named bucket of glyphs the picker renders as one collapsible
/// section. The `titleKey` is a Localizable.strings key so the
/// section headers translate alongside the rest of Scribe's UI.
struct CharacterCategory: Identifiable, Hashable, Sendable {
    /// Bucket identity uses the stable `titleKey` so SwiftUI's
    /// diffing doesn't churn when we add new categories.
    var id: String { titleKey }
    let titleKey: String
    let characters: [SpecialCharacter]
}

enum CharacterCatalog {

    // MARK: - Greek

    /// Greek lowercase α β γ … ω. Ordered in the canonical Greek
    /// alphabet sequence so math / physics readers can find a
    /// letter by position the same way they'd scan a textbook.
    /// Stigma / digamma / sampi are omitted — V1 sticks to the
    /// 24 letters every high-school Greek font ships.
    static let greekLower: CharacterCategory = CharacterCategory(
        titleKey: "character.category.greekLower",
        characters: [
            SpecialCharacter("α", "alpha"),
            SpecialCharacter("β", "beta"),
            SpecialCharacter("γ", "gamma"),
            SpecialCharacter("δ", "delta"),
            SpecialCharacter("ε", "epsilon"),
            SpecialCharacter("ζ", "zeta"),
            SpecialCharacter("η", "eta"),
            SpecialCharacter("θ", "theta"),
            SpecialCharacter("ι", "iota"),
            SpecialCharacter("κ", "kappa"),
            SpecialCharacter("λ", "lambda"),
            SpecialCharacter("μ", "mu"),
            SpecialCharacter("ν", "nu"),
            SpecialCharacter("ξ", "xi"),
            SpecialCharacter("ο", "omicron"),
            SpecialCharacter("π", "pi"),
            SpecialCharacter("ρ", "rho"),
            SpecialCharacter("σ", "sigma"),
            SpecialCharacter("τ", "tau"),
            SpecialCharacter("υ", "upsilon"),
            SpecialCharacter("φ", "phi"),
            SpecialCharacter("χ", "chi"),
            SpecialCharacter("ψ", "psi"),
            SpecialCharacter("ω", "omega")
        ]
    )

    /// Greek uppercase Α Β Γ … Ω. Same order as `greekLower`.
    static let greekUpper: CharacterCategory = CharacterCategory(
        titleKey: "character.category.greekUpper",
        characters: [
            SpecialCharacter("Α", "Alpha"),
            SpecialCharacter("Β", "Beta"),
            SpecialCharacter("Γ", "Gamma"),
            SpecialCharacter("Δ", "Delta"),
            SpecialCharacter("Ε", "Epsilon"),
            SpecialCharacter("Ζ", "Zeta"),
            SpecialCharacter("Η", "Eta"),
            SpecialCharacter("Θ", "Theta"),
            SpecialCharacter("Ι", "Iota"),
            SpecialCharacter("Κ", "Kappa"),
            SpecialCharacter("Λ", "Lambda"),
            SpecialCharacter("Μ", "Mu"),
            SpecialCharacter("Ν", "Nu"),
            SpecialCharacter("Ξ", "Xi"),
            SpecialCharacter("Ο", "Omicron"),
            SpecialCharacter("Π", "Pi"),
            SpecialCharacter("Ρ", "Rho"),
            SpecialCharacter("Σ", "Sigma"),
            SpecialCharacter("Τ", "Tau"),
            SpecialCharacter("Υ", "Upsilon"),
            SpecialCharacter("Φ", "Phi"),
            SpecialCharacter("Χ", "Chi"),
            SpecialCharacter("Ψ", "Psi"),
            SpecialCharacter("Ω", "Omega")
        ]
    )

    // MARK: - Math

    /// Relational / set / calculus glyphs. The ordering walks
    /// "relations → inequality → set → logic → calculus → misc"
    /// so a reader skimming top-to-bottom finds groups clustered.
    static let math: CharacterCategory = CharacterCategory(
        titleKey: "character.category.math",
        characters: [
            SpecialCharacter("≠", "not equal"),
            SpecialCharacter("≈", "almost equal"),
            SpecialCharacter("≡", "identical to"),
            SpecialCharacter("≜", "equal by definition"),
            SpecialCharacter("≤", "less than or equal"),
            SpecialCharacter("≥", "greater than or equal"),
            SpecialCharacter("≪", "much less than"),
            SpecialCharacter("≫", "much greater than"),
            SpecialCharacter("±", "plus-minus"),
            SpecialCharacter("∓", "minus-plus"),
            SpecialCharacter("×", "multiplication"),
            SpecialCharacter("÷", "division"),
            SpecialCharacter("·", "middle dot"),
            SpecialCharacter("∈", "element of"),
            SpecialCharacter("∉", "not element of"),
            SpecialCharacter("⊂", "subset of"),
            SpecialCharacter("⊆", "subset or equal"),
            SpecialCharacter("⊃", "superset of"),
            SpecialCharacter("⊇", "superset or equal"),
            SpecialCharacter("∪", "union"),
            SpecialCharacter("∩", "intersection"),
            SpecialCharacter("∅", "empty set"),
            SpecialCharacter("∀", "for all"),
            SpecialCharacter("∃", "there exists"),
            SpecialCharacter("∄", "not exists"),
            SpecialCharacter("∧", "logical and"),
            SpecialCharacter("∨", "logical or"),
            SpecialCharacter("¬", "not"),
            SpecialCharacter("∞", "infinity"),
            SpecialCharacter("√", "square root"),
            SpecialCharacter("∛", "cube root"),
            SpecialCharacter("∑", "sum"),
            SpecialCharacter("∏", "product"),
            SpecialCharacter("∫", "integral"),
            SpecialCharacter("∂", "partial"),
            SpecialCharacter("∇", "nabla"),
            SpecialCharacter("°", "degree"),
            SpecialCharacter("′", "prime"),
            SpecialCharacter("″", "double prime"),
            SpecialCharacter("ℝ", "real numbers"),
            SpecialCharacter("ℕ", "natural numbers"),
            SpecialCharacter("ℤ", "integers"),
            SpecialCharacter("ℚ", "rational numbers"),
            SpecialCharacter("ℂ", "complex numbers")
        ]
    )

    // MARK: - Arrows

    static let arrows: CharacterCategory = CharacterCategory(
        titleKey: "character.category.arrows",
        characters: [
            SpecialCharacter("←", "left arrow"),
            SpecialCharacter("→", "right arrow"),
            SpecialCharacter("↑", "up arrow"),
            SpecialCharacter("↓", "down arrow"),
            SpecialCharacter("↔", "left-right arrow"),
            SpecialCharacter("↕", "up-down arrow"),
            SpecialCharacter("↖", "up-left arrow"),
            SpecialCharacter("↗", "up-right arrow"),
            SpecialCharacter("↘", "down-right arrow"),
            SpecialCharacter("↙", "down-left arrow"),
            SpecialCharacter("⇐", "left double arrow"),
            SpecialCharacter("⇒", "right double arrow"),
            SpecialCharacter("⇑", "up double arrow"),
            SpecialCharacter("⇓", "down double arrow"),
            SpecialCharacter("⇔", "left-right double arrow"),
            SpecialCharacter("⇕", "up-down double arrow"),
            SpecialCharacter("↦", "maps to"),
            SpecialCharacter("⇌", "reversible reaction"),
            SpecialCharacter("↪", "right hook arrow"),
            SpecialCharacter("↩", "left hook arrow"),
            SpecialCharacter("⤴", "arrow up then right"),
            SpecialCharacter("⤵", "arrow down then right"),
            SpecialCharacter("⟵", "long left arrow"),
            SpecialCharacter("⟶", "long right arrow"),
            SpecialCharacter("⟷", "long left-right arrow"),
            SpecialCharacter("⟸", "long left double arrow"),
            SpecialCharacter("⟹", "long right double arrow"),
            SpecialCharacter("⟺", "long left-right double arrow")
        ]
    )

    // MARK: - Punctuation

    static let punctuation: CharacterCategory = CharacterCategory(
        titleKey: "character.category.punctuation",
        characters: [
            SpecialCharacter("–", "en dash"),
            SpecialCharacter("—", "em dash"),
            SpecialCharacter("…", "ellipsis"),
            SpecialCharacter("•", "bullet"),
            SpecialCharacter("·", "middle dot"),
            SpecialCharacter("‘", "left single quote"),
            SpecialCharacter("’", "right single quote"),
            SpecialCharacter("“", "left double quote"),
            SpecialCharacter("”", "right double quote"),
            SpecialCharacter("«", "left guillemet"),
            SpecialCharacter("»", "right guillemet"),
            SpecialCharacter("‹", "single left guillemet"),
            SpecialCharacter("›", "single right guillemet"),
            SpecialCharacter("§", "section"),
            SpecialCharacter("¶", "pilcrow"),
            SpecialCharacter("†", "dagger"),
            SpecialCharacter("‡", "double dagger"),
            SpecialCharacter("©", "copyright"),
            SpecialCharacter("®", "registered"),
            SpecialCharacter("™", "trademark"),
            SpecialCharacter("°", "degree"),
            SpecialCharacter("№", "numero")
        ]
    )

    // MARK: - Currency

    static let currency: CharacterCategory = CharacterCategory(
        titleKey: "character.category.currency",
        characters: [
            SpecialCharacter("$", "dollar"),
            SpecialCharacter("€", "euro"),
            SpecialCharacter("£", "pound"),
            SpecialCharacter("¥", "yen"),
            SpecialCharacter("₽", "ruble"),
            SpecialCharacter("₩", "won"),
            SpecialCharacter("₺", "lira"),
            SpecialCharacter("₹", "rupee"),
            SpecialCharacter("₿", "bitcoin"),
            SpecialCharacter("¢", "cent"),
            SpecialCharacter("¤", "generic currency")
        ]
    )

    // MARK: - Aggregate

    /// All categories in rendering order. The picker scrolls
    /// through these top-to-bottom, so the first bucket is what
    /// the user sees without scrolling.
    static let all: [CharacterCategory] = [
        greekLower,
        greekUpper,
        math,
        arrows,
        punctuation,
        currency
    ]

    // MARK: - Search

    /// Case-insensitive substring filter against a character's
    /// `name`. Characters inside the query itself also match,
    /// so a user who pastes "α" in the search box sees the Greek
    /// alpha row — same trick that makes Emoji picker usable.
    /// Returns `all` verbatim on an empty query.
    static func filter(_ query: String,
                       in source: [CharacterCategory] = all) -> [CharacterCategory] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return source }
        let needle = trimmed.lowercased()
        var out: [CharacterCategory] = []
        for category in source {
            let hits = category.characters.filter { ch in
                ch.name.lowercased().contains(needle)
                    || ch.value.contains(trimmed)
            }
            if !hits.isEmpty {
                out.append(CharacterCategory(titleKey: category.titleKey,
                                             characters: hits))
            }
        }
        return out
    }
}
