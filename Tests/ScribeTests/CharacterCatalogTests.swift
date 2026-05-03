//
//  CharacterCatalogTests.swift
//  Phase 59 — pins the special-character catalog + filter rule.
//  The visual grid itself (CharacterPanelSheet) is exercised
//  manually; the data layer below is everything that could silently
//  regress on a locale / sort / filter change.
//

import XCTest
@testable import Scribe

@MainActor
final class CharacterCatalogTests: XCTestCase {

    // MARK: - Catalog shape

    func test_catalog_allCategoriesAreNonEmpty() {
        // A bucket with zero entries would render a blank section
        // header in the sheet — worse than leaving it out entirely.
        for category in CharacterCatalog.all {
            XCTAssertFalse(category.characters.isEmpty,
                           "\(category.titleKey) shouldn't be empty")
        }
    }

    func test_catalog_greekAlphabetsAreComplete() {
        // 24 canonical letters each — Greek stigma / digamma /
        // sampi live outside our scope.
        XCTAssertEqual(CharacterCatalog.greekLower.characters.count, 24)
        XCTAssertEqual(CharacterCatalog.greekUpper.characters.count, 24)
        // Alpha / Omega bookend both lists.
        XCTAssertEqual(CharacterCatalog.greekLower.characters.first?.value, "α")
        XCTAssertEqual(CharacterCatalog.greekLower.characters.last?.value, "ω")
        XCTAssertEqual(CharacterCatalog.greekUpper.characters.first?.value, "Α")
        XCTAssertEqual(CharacterCatalog.greekUpper.characters.last?.value, "Ω")
    }

    func test_catalog_noDuplicateValuesWithinACategory() {
        // Within a bucket, each glyph shows up once. Cross-bucket
        // duplicates (e.g. "·" in math AND punctuation) are fine
        // because users reach each bucket through different
        // mental paths.
        for category in CharacterCatalog.all {
            let values = category.characters.map(\.value)
            XCTAssertEqual(values.count, Set(values).count,
                           "duplicate glyph inside \(category.titleKey)")
        }
    }

    func test_catalog_namesAreUniqueWithinCategory() {
        // Unique names keep the search result list unambiguous
        // (otherwise typing "sigma" could match two rows that
        // look identical to the user).
        for category in CharacterCatalog.all {
            let names = category.characters.map(\.name)
            XCTAssertEqual(names.count, Set(names).count,
                           "duplicate name inside \(category.titleKey)")
        }
    }

    // MARK: - Filter behaviour

    func test_filter_emptyQuery_returnsEntireCatalog() {
        // No filter text ⇒ render every category verbatim. A
        // stricter behaviour (hide all until the user types) would
        // force discovery through search only; the picker leans
        // on browsability.
        let result = CharacterCatalog.filter("")
        XCTAssertEqual(result.count, CharacterCatalog.all.count)
        XCTAssertEqual(result.map(\.titleKey),
                       CharacterCatalog.all.map(\.titleKey))
    }

    func test_filter_whitespaceQuery_treatedAsEmpty() {
        // Autofill / accidental space keys shouldn't collapse the
        // grid — same rule Phase 58's no-match overlay uses.
        let result = CharacterCatalog.filter("   \t  ")
        XCTAssertEqual(result.count, CharacterCatalog.all.count)
    }

    func test_filter_byName_caseInsensitive() {
        let result = CharacterCatalog.filter("ALPHA")
        let flatNames = result.flatMap { $0.characters }.map(\.name)
        XCTAssertTrue(flatNames.contains("alpha"),
                      "search should match lowercase name regardless of case")
    }

    func test_filter_byGlyph_matchesDirectPaste() {
        // User pastes the glyph into the search field — this is
        // the Emoji Viewer muscle memory: "paste what you have,
        // see the row that matches".
        let result = CharacterCatalog.filter("α")
        let flatValues = result.flatMap { $0.characters }.map(\.value)
        XCTAssertEqual(flatValues, ["α"],
                       "pasting α should yield exactly the alpha row")
    }

    func test_filter_noMatches_yieldsEmpty() {
        let result = CharacterCatalog.filter("no-such-character")
        XCTAssertTrue(result.isEmpty,
                      "unmatched query should drop every section")
    }

    func test_filter_partialMatch_keepsOnlyMatchingRowsInSection() {
        // "arrow" matches every entry in the Arrows section whose
        // name contains "arrow" — not every Arrows row qualifies
        // (e.g. "maps to", "reversible reaction" are arrows that
        // don't carry the word in their description). The catalog's
        // intent is that the Arrows section is the *only* surviving
        // bucket, and at minimum the cardinal-direction rows ride
        // through.
        let result = CharacterCatalog.filter("arrow")
        XCTAssertEqual(result.count, 1,
                       "only the Arrows section should survive an 'arrow' query")
        XCTAssertEqual(result.first?.titleKey,
                       "character.category.arrows")
        let names = result.first?.characters.map(\.name) ?? []
        for cardinal in ["left arrow", "right arrow", "up arrow", "down arrow"] {
            XCTAssertTrue(names.contains(cardinal),
                          "cardinal-direction row '\(cardinal)' must survive")
        }
    }

    // MARK: - Palette registration

    func test_palette_registersInsertCharacterCommand() {
        let suite = "scribe-character-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        // Seed a doc so the perform guard lets through.
        let doc = Document(title: "scratch.txt", text: "")
        workspace.documents = [doc]
        workspace.selectedID = doc.id

        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)
        // Look up by ID rather than title-search — the title resolves
        // through `L10n.t` and therefore varies with the test host's
        // locale (en gives "Insert Special Character", zh-Hans gives
        // "插入特殊字符"). Pinning the ID avoids the locale flake.
        guard let cmd = registry.commands.first(where: { $0.id == "edit.insertCharacter" }) else {
            return XCTFail("edit.insertCharacter command should be registered")
        }
        XCTAssertEqual(cmd.shortcutLabel, "⌥⌘C")

        XCTAssertFalse(workspace.isCharacterPanelPresented)
        cmd.perform()
        XCTAssertTrue(workspace.isCharacterPanelPresented,
                      "invoking the palette entry must raise the sheet")
    }

    func test_palette_insertCharacter_keywordsAreReachable() {
        // The palette uses a fuzzy ranker, so an unrelated command
        // may outrank ours on a single short keyword (e.g. "arrow"
        // also fuzzy-matches "view.zoomOut"). What we actually care
        // about is that the entry shows up *anywhere* in the
        // result list — the user only sees the top 8 in the panel,
        // but the keyword routing makes the entry findable.
        let suite = "scribe-character-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "scratch.txt", text: "")
        workspace.documents = [doc]
        workspace.selectedID = doc.id

        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)
        // Each query below must be a substring of one of the
        // keywords we registered ("greek", "glyph", "unicode",
        // "希腊", "数学"). The fuzzy ranker may rank an unrelated
        // command higher on a single short string, but the entry
        // must at least *appear* in the result list.
        for query in ["greek", "glyph", "unicode", "希腊", "数学"] {
            let ids = registry.search(query).map(\.command.id)
            XCTAssertTrue(ids.contains("edit.insertCharacter"),
                          "query '\(query)' must surface edit.insertCharacter; got \(ids)")
        }
    }
}
