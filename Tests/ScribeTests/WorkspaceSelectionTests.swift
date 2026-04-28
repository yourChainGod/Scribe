//
//  WorkspaceSelectionTests.swift
//  Phase 18 — covers the `Workspace.activeSelection` shared field
//  that ScintillaCodeEditor writes from SCN_UPDATEUI and the
//  Find-in-Files command reads at invoke time. The Coordinator
//  itself isn't unit-testable without a live Scintilla view, so we
//  focus on the bookkeeping side of the bridge.
//

import XCTest
@testable import Scribe

@MainActor
final class WorkspaceSelectionTests: XCTestCase {

    private func makeWorkspace() -> Workspace {
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: "scribe-selection-\(UUID().uuidString)")!)
        return Workspace(prefs: prefs, openInitialUntitled: false)
    }

    func test_activeSelection_defaultsToEmpty() {
        let ws = makeWorkspace()
        XCTAssertTrue(ws.activeSelection.isEmpty)
    }

    func test_activeSelection_storesAndReadsBack() {
        let ws = makeWorkspace()
        ws.activeSelection = "foo bar"
        XCTAssertEqual(ws.activeSelection, "foo bar")
    }

    func test_activeSelection_isNotPublishedSoNoChurn() {
        // We assert this by reading via direct access without
        // observing — if the field were @Published and SwiftUI
        // observed it everywhere, every cursor move would tick the
        // entire view tree at typing speed. Documenting the
        // contract here so a future "make it @Published" refactor
        // gets a tap on the shoulder from the test suite.
        let ws = makeWorkspace()
        let mirror = Mirror(reflecting: ws)
        let descriptor = mirror.children.first { $0.label == "activeSelection" }
        // The field exists.
        XCTAssertNotNil(descriptor)
        // And it isn't backed by a Published<String> wrapper —
        // a @Published field would store its raw value under a
        // synthesized "_activeSelection" descriptor with a
        // Published<…> type. We assert the absence of that by
        // confirming the descriptor has the plain String type.
        if let value = descriptor?.value {
            XCTAssertTrue(value is String,
                          "activeSelection must remain a plain String, not @Published")
        }
    }

    func test_activeSelection_clearedSelectionResetsToEmpty() {
        let ws = makeWorkspace()
        ws.activeSelection = "hello"
        ws.activeSelection = ""
        XCTAssertTrue(ws.activeSelection.isEmpty,
                      "deselecting in the editor should clear the cached query")
    }
}
