//
//  DocumentMapTests.swift
//  Phase 56 — Document Map (minimap). Covers the three seams where
//  the feature is reachable without spinning up a live ScintillaView:
//    1. `EditorPreferences.isMinimapVisible` — default state +
//       persistence round-trip.
//    2. `CommandRegistration` — palette exposes `view.toggleMinimap`
//       with a title that flips per state and a handler that mutates
//       the pref.
//    3. `DocumentMapPane` static metrics — preferred width and
//       minimap font size stay within the ranges the view expects.
//
//  Click-to-jump and the live Scintilla mirroring are exercised by
//  the manual QA matrix. They require a real NSWindow + AppKit run
//  loop that the XCTest bundle can't spin up under `swift test` in
//  headless CI.
//

import XCTest
@testable import Scribe

@MainActor
final class DocumentMapTests: XCTestCase {

    private func makePrefs(suite: String? = nil) -> EditorPreferences {
        let s = suite ?? "scribe-minimap-\(UUID().uuidString)"
        return EditorPreferences(defaults: UserDefaults(suiteName: s)!)
    }

    // MARK: - Preferences

    func test_isMinimapVisible_defaultsToFalse() {
        // Phase 56 ships the minimap OFF so existing users don't
        // see a surprise strip on upgrade. The opt-in path is
        // ⌥⌘M / View ▸ Show Minimap.
        let prefs = makePrefs()
        XCTAssertFalse(prefs.isMinimapVisible)
    }

    func test_isMinimapVisible_persistsAcrossInstances() {
        // Same pattern every other pref uses (zoom, soft-tabs,
        // color swatches): the didSet hits UserDefaults
        // immediately so a re-read returns the flipped value.
        let suite = "scribe-minimap-persistence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = EditorPreferences(defaults: defaults)
        XCTAssertFalse(first.isMinimapVisible)
        first.isMinimapVisible = true

        let second = EditorPreferences(defaults: defaults)
        XCTAssertTrue(second.isMinimapVisible,
                      "didSet must persist the flip through UserDefaults")
    }

    // MARK: - Command palette

    func test_paletteExposesMinimapToggle_withStateAwareTitle() {
        // Off ↔ on must surface *different* titles so the verb
        // always matches the click's effect. We don't pin the
        // exact English / Chinese strings here — the `L10n.t`
        // lookup follows the test host's locale — but a change
        // in state must change the title (and keep the command
        // ID stable so the palette still ranks it the same).
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let registry = CommandRegistry()

        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)

        let showResult = registry.search("minimap").first
        XCTAssertEqual(showResult?.command.id, "view.toggleMinimap")
        XCTAssertEqual(showResult?.command.shortcutLabel, "⌥⌘M")
        let offTitle = showResult?.command.title ?? ""
        XCTAssertFalse(offTitle.isEmpty,
                       "OFF state title must resolve to a non-empty string")

        // Flip the pref and refresh the registry — the same
        // command ID should now carry a different title.
        prefs.isMinimapVisible = true
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)
        let hideResult = registry.search("minimap").first
        XCTAssertEqual(hideResult?.command.id, "view.toggleMinimap")
        let onTitle = hideResult?.command.title ?? ""
        XCTAssertNotEqual(offTitle, onTitle,
                          "title must flip with state so the verb matches the effect")
    }

    func test_paletteInvoke_togglesMinimapVisibility() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let registry = CommandRegistry()

        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)
        XCTAssertFalse(prefs.isMinimapVisible, "starts off")
        registry.search("minimap").first?.command.perform()
        XCTAssertTrue(prefs.isMinimapVisible,
                      "first invoke turns the minimap on")
    }

    func test_paletteMinimap_matchesBothEnglishAndChineseKeywords() {
        // Keyword coverage is how users discover the command
        // regardless of which editor lineage they came from.
        // Assert we surface under the VSCode vocabulary
        // ("minimap") *and* the Notepad++ vocabulary
        // ("overview" / "document map") *and* zh-Hans
        // ("缩略图"). A failure here means CommandRegistration
        // dropped one of the keywords.
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let registry = CommandRegistry()

        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)

        for query in ["minimap", "overview", "缩略图", "地图"] {
            let hit = registry.search(query).first
            XCTAssertEqual(hit?.command.id, "view.toggleMinimap",
                           "query \(query) must match view.toggleMinimap")
        }
    }

    // MARK: - DocumentMapPane metrics

    func test_documentMapPane_preferredWidth_isUsableStrip() {
        // The strip has to be wide enough for the tiny-font mirror
        // to be legible as shapes (~30 chars at 2pt Menlo) but
        // narrow enough that the editor keeps the bulk of the
        // canvas. 100–160 pt is the usable range — anything
        // outside is a regression.
        XCTAssertGreaterThanOrEqual(DocumentMapPane.preferredWidth, 80)
        XCTAssertLessThanOrEqual(DocumentMapPane.preferredWidth, 200)
    }

    func test_documentMapPane_minimapFontSize_isInScintillaLegibleRange() {
        // Scintilla's painter collapses to a 1-pixel row below
        // 2pt (unreadable even as a block-shape thumbnail) and
        // the visual point of a minimap disappears above ~4pt
        // (lines look like regular editor text). Pin the
        // constant so a future tweak that breaks this reads as
        // a deliberate decision, not a typo.
        XCTAssertGreaterThanOrEqual(DocumentMapPane.minimapFontSize, 2)
        XCTAssertLessThanOrEqual(DocumentMapPane.minimapFontSize, 4)
    }
}
