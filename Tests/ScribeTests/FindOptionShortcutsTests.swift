//
//  FindOptionShortcutsTests.swift
//  Phase 49a — pure-data assertions for the shortcut catalog used by
//  the inline find bar and the Find-in-Files sidebar. Catches drift in
//  letter / modifier choices without spinning up a SwiftUI window.
//

import XCTest
@testable import Scribe

final class FindOptionShortcutsTests: XCTestCase {

    func test_matchCaseBindsToCommandOptionC() {
        XCTAssertEqual(FindOptionShortcuts.character(for: .matchCase), "c")
        let mods = FindOptionShortcuts.modifiers(for: .matchCase)
        XCTAssertTrue(mods.contains(.command), "match-case shortcut should require ⌘")
        XCTAssertTrue(mods.contains(.option),  "match-case shortcut should require ⌥")
        XCTAssertFalse(mods.contains(.shift),  "match-case shortcut should not require ⇧")
        XCTAssertFalse(mods.contains(.control), "match-case shortcut should not require ⌃")
    }

    func test_wholeWordBindsToCommandOptionW() {
        XCTAssertEqual(FindOptionShortcuts.character(for: .wholeWord), "w")
        let mods = FindOptionShortcuts.modifiers(for: .wholeWord)
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.option))
    }

    func test_regexBindsToCommandOptionR() {
        XCTAssertEqual(FindOptionShortcuts.character(for: .regex), "r")
        let mods = FindOptionShortcuts.modifiers(for: .regex)
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.option))
    }

    func test_helpSuffixRendersUppercaseShortcutGlyph() {
        // Tooltip suffix is concatenated onto the localized option
        // label, so it has to start with a leading space and use the
        // canonical macOS glyphs.
        XCTAssertEqual(FindOptionShortcuts.helpSuffix(for: .matchCase), " (⌘⌥C)")
        XCTAssertEqual(FindOptionShortcuts.helpSuffix(for: .wholeWord), " (⌘⌥W)")
        XCTAssertEqual(FindOptionShortcuts.helpSuffix(for: .regex),     " (⌘⌥R)")
    }

    func test_eachOptionUsesADistinctLetter() {
        // Sanity check: if a future option recycles a letter, ⌘⌥X
        // would silently collide. CaseIterable lets the test catch
        // that automatically as new options get added.
        let letters = FindOption.allCases.map { FindOptionShortcuts.character(for: $0) }
        XCTAssertEqual(Set(letters).count, letters.count, "FindOption shortcut letters must be unique, got \(letters)")
    }
}
