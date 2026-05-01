//
//  CommandGroupedSearchTests.swift
//  Phase 46d — verifies `CommandRegistry.grouped(for:)` returns the
//  right section layout for the three palette modes:
//    1. empty query  ⇒ one section per category, fixed order
//    2. non-empty query ⇒ single anonymous section
//    3. prefix route active (@, :, >) ⇒ single anonymous section
//
//  Together with `CommandShortcutLabelTests` and
//  `CommandRegistrationTests` these lock the data contract the
//  Command Palette SwiftUI view consumes.
//

import XCTest
@testable import Scribe

@MainActor
final class CommandGroupedSearchTests: XCTestCase {

    private func makePrefs() -> EditorPreferences {
        let suite = "scribe-grouped-\(UUID().uuidString)"
        return EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    private func makeRegistry() -> (CommandRegistry, Workspace, EditorPreferences) {
        let prefs = makePrefs()
        let ws = Workspace(prefs: prefs, openInitialUntitled: false)
        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: ws,
                                    prefs: prefs)
        return (registry, ws, prefs)
    }

    // MARK: - empty query

    func test_groupedForEmptyQuery_splitsByCategory() {
        let (registry, _, _) = makeRegistry()
        let sections = registry.grouped(for: "")
        XCTAssertGreaterThanOrEqual(sections.count, 2,
                                    "empty query should produce multiple category sections")
        // All section ids should be CategorySection rawValues, not "all".
        for section in sections {
            XCTAssertNotEqual(section.id, "all",
                              "empty-query sections should use category ids, not the flat fallback")
            XCTAssertFalse(section.title.isEmpty,
                           "category sections need a header title to render")
        }
    }

    func test_groupedForEmptyQuery_preservesFixedSectionOrder() {
        let (registry, _, _) = makeRegistry()
        let sections = registry.grouped(for: "")
        // Match the enum declaration order: File ▸ View ▸ Text ▸ Tabs
        // ▸ Encoding ▸ Line Ending ▸ Syntax ▸ Other. Only a subset
        // shows up for a fresh workspace (no current doc ⇒ no tab /
        // encoding / lineEnding / lexer entries), so filter the
        // expected ordering to the ids actually present and diff
        // against the real sequence.
        let expectedOrder = CommandRegistry.CategorySection.allCases.map(\.rawValue)
        let actualOrder = sections.map(\.id)
        // actualOrder ⊆ expectedOrder, in the same relative order.
        var expectedIdx = 0
        for id in actualOrder {
            while expectedIdx < expectedOrder.count, expectedOrder[expectedIdx] != id {
                expectedIdx += 1
            }
            XCTAssertLessThan(expectedIdx, expectedOrder.count,
                              "section id \(id) missing or out-of-order in fixed roster")
            expectedIdx += 1
        }
    }

    func test_groupedForEmptyQuery_assignsFileCommandsToFileSection() {
        let (registry, _, _) = makeRegistry()
        let sections = registry.grouped(for: "")
        let fileSection = sections.first { $0.id == "file" }
        XCTAssertNotNil(fileSection)
        let ids = fileSection?.matches.map(\.command.id) ?? []
        XCTAssertTrue(ids.contains("file.new"))
        XCTAssertTrue(ids.contains("file.save"))
        XCTAssertTrue(ids.contains("file.reopenClosed"))
    }

    func test_groupedForEmptyQuery_flatLengthMatchesSearch() {
        let (registry, _, _) = makeRegistry()
        let sections = registry.grouped(for: "")
        let flat = sections.flatMap(\.matches)
        let searchResult = registry.search("")
        XCTAssertEqual(flat.count, searchResult.count,
                       "grouping reshapes the result list but shouldn't drop entries")
        // Every id from search should show up exactly once across sections.
        XCTAssertEqual(Set(flat.map(\.command.id)),
                       Set(searchResult.map(\.command.id)))
    }

    // MARK: - non-empty query

    func test_groupedForNonEmptyQuery_returnsSingleAnonymousSection() {
        let (registry, _, _) = makeRegistry()
        let sections = registry.grouped(for: "save")
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.id, "all")
        XCTAssertEqual(sections.first?.title, "",
                       "non-empty query sections render without a header")
    }

    // MARK: - prefix route

    func test_groupedForPrefixRoute_returnsSingleAnonymousSection() {
        let (registry, _, _) = makeRegistry()
        // Attach a dummy prefix route so `activeRoute(for:)` fires.
        registry.prefixRoutes = [
            PrefixRoute(id: "stub",
                        prefix: ">",
                        dynamicCommands: { _ in [] },
                        placeholder: "stub")
        ]
        let sections = registry.grouped(for: ">")
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.id, "all")
    }
}
