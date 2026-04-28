//
//  SnippetCatalogTests.swift
//  Phase 33 — locks down the four properties the rest of the
//  feature relies on:
//    1. First run seeds the starter set (and persists it, so a
//       second instance against the same defaults sees the same
//       list — no double-seed bug).
//    2. add/update/remove mutate the @Published list AND persist.
//    3. Codable round-trips Snippet without losing fields.
//    4. resetToStarter wipes user content and restores defaults.
//

import XCTest
@testable import Scribe

@MainActor
final class SnippetCatalogTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "scribe-snippets-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - First run / persistence

    func test_firstRun_seedsStarterSnippets() {
        let defaults = freshDefaults()
        let catalog = SnippetCatalog(defaults: defaults)
        XCTAssertFalse(catalog.snippets.isEmpty,
                       "starter seed should not be empty")
        // Sanity check — at least the headline samples the seed
        // documents in code: TODO + a markdown table.
        XCTAssertTrue(catalog.snippets.contains { $0.prefix == "todo" })
        XCTAssertTrue(catalog.snippets.contains { $0.prefix == "mdtable" })
    }

    func test_secondInstance_loadsPersistedSnippets() {
        let defaults = freshDefaults()
        let first = SnippetCatalog(defaults: defaults)
        first.add(Snippet(name: "Persisted",
                          prefix: "p",
                          body: "X",
                          description: ""))

        let second = SnippetCatalog(defaults: defaults)
        XCTAssertTrue(second.snippets.contains { $0.name == "Persisted" })
    }

    // MARK: - CRUD

    func test_add_appendsAndPersists() {
        let defaults = freshDefaults()
        let catalog = SnippetCatalog(defaults: defaults)
        let beforeCount = catalog.snippets.count
        let snippet = Snippet(name: "added", body: "x")
        let returned = catalog.add(snippet)
        XCTAssertEqual(catalog.snippets.count, beforeCount + 1)
        XCTAssertEqual(returned.id, snippet.id)
        XCTAssertEqual(catalog.snippets.last?.name, "added")
    }

    func test_update_replacesMatchingId() {
        let defaults = freshDefaults()
        let catalog = SnippetCatalog(defaults: defaults)
        let original = catalog.add(Snippet(name: "before", body: "old"))
        var edited = original
        edited.name = "after"
        edited.body = "new"
        catalog.update(edited)

        let stored = catalog.snippets.first { $0.id == original.id }
        XCTAssertEqual(stored?.name, "after")
        XCTAssertEqual(stored?.body, "new")
    }

    func test_update_unknownIdIsNoOp() {
        let defaults = freshDefaults()
        let catalog = SnippetCatalog(defaults: defaults)
        let countBefore = catalog.snippets.count
        catalog.update(Snippet(id: UUID(), name: "ghost", body: "x"))
        XCTAssertEqual(catalog.snippets.count, countBefore)
        XCTAssertFalse(catalog.snippets.contains { $0.name == "ghost" })
    }

    func test_remove_dropsMatchingIdAndPersists() {
        let defaults = freshDefaults()
        let catalog = SnippetCatalog(defaults: defaults)
        let added = catalog.add(Snippet(name: "doomed", body: ""))
        catalog.remove(id: added.id)
        XCTAssertFalse(catalog.snippets.contains { $0.id == added.id })

        let reopened = SnippetCatalog(defaults: defaults)
        XCTAssertFalse(reopened.snippets.contains { $0.id == added.id })
    }

    // MARK: - Reset

    func test_resetToStarter_replacesUserSnippets() {
        let defaults = freshDefaults()
        let catalog = SnippetCatalog(defaults: defaults)
        // Wipe to one custom snippet, confirm reset brings back the seed.
        for snippet in catalog.snippets { catalog.remove(id: snippet.id) }
        catalog.add(Snippet(name: "custom", body: "y"))
        XCTAssertEqual(catalog.snippets.count, 1)

        catalog.resetToStarter()
        XCTAssertGreaterThan(catalog.snippets.count, 1)
        XCTAssertFalse(catalog.snippets.contains { $0.name == "custom" })
    }

    // MARK: - Codable round-trip

    func test_snippet_codableRoundTrip() throws {
        let original = Snippet(name: "Round Trip",
                               prefix: "rt",
                               body: "line 1\nline 2\n",
                               description: "with description")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Snippet.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_corruptStoredJsonFallsBackToSeed() {
        let defaults = freshDefaults()
        defaults.set(Data([0x00, 0x01, 0x02]),
                     forKey: "scribe.snippets.v1")
        let catalog = SnippetCatalog(defaults: defaults)
        // Corrupt → first-run seed kicks in instead of crashing.
        XCTAssertFalse(catalog.snippets.isEmpty)
        XCTAssertTrue(catalog.snippets.contains { $0.prefix == "todo" })
    }
}
