//
//  MergeConflictEngineTests.swift
//  Phase 68 — verifies the engine binds / unbinds documents
//  cleanly, seeds the conflict list synchronously on attach,
//  re-parses through the debounce when the bound doc's text
//  mutates, and refresh() bypasses the debounce window.
//

import XCTest
import Combine
@testable import Scribe

@MainActor
final class MergeConflictEngineTests: XCTestCase {

    private static let conflictBody = """
    prefix
    <<<<<<< HEAD
    ours
    =======
    theirs
    >>>>>>> feature
    suffix
    """

    func test_unbound_emitsEmpty() {
        let engine = MergeConflictEngine()
        XCTAssertTrue(engine.conflicts.isEmpty)
        XCTAssertNil(engine.boundDocumentID)
    }

    func test_bind_seedsImmediatelyForCurrentText() {
        let engine = MergeConflictEngine()
        let doc = Document(title: "demo", text: Self.conflictBody)
        engine.bind(to: doc)
        XCTAssertEqual(engine.conflicts.count, 1,
                       "first bind must seed before the debounce window")
        XCTAssertEqual(engine.boundDocumentID, doc.id)
    }

    func test_bindNil_clearsConflicts() {
        let engine = MergeConflictEngine()
        let doc = Document(title: "demo", text: Self.conflictBody)
        engine.bind(to: doc)
        XCTAssertEqual(engine.conflicts.count, 1)
        engine.bind(to: nil)
        XCTAssertTrue(engine.conflicts.isEmpty)
        XCTAssertNil(engine.boundDocumentID)
    }

    func test_bindSameDocTwice_isNoOp() {
        let engine = MergeConflictEngine()
        let doc = Document(title: "demo", text: Self.conflictBody)
        engine.bind(to: doc)
        let firstSnapshot = engine.conflicts
        // Second bind with same id should not re-parse / replace.
        engine.bind(to: doc)
        XCTAssertEqual(engine.conflicts, firstSnapshot,
                       "rebinding the same doc must not churn the parsed list")
    }

    func test_textMutation_eventuallyRepublishes() async throws {
        let engine = MergeConflictEngine()
        let doc = Document(title: "demo", text: Self.conflictBody)
        engine.bind(to: doc)
        XCTAssertEqual(engine.conflicts.count, 1)

        // Drop the conflict by removing one of the markers.
        doc.text = "now without any markers at all"

        // Wait through the debounce window. The sink scheduler is
        // RunLoop.main; pump until the published list updates or
        // the timeout expires.
        let deadline = Date().addingTimeInterval(1.5)
        while !engine.conflicts.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(engine.conflicts.isEmpty,
                      "engine must drop conflicts when the text no longer has markers")
    }

    func test_refresh_bypassesDebounce() {
        let engine = MergeConflictEngine()
        let doc = Document(title: "demo", text: "no conflicts here")
        engine.bind(to: doc)
        XCTAssertTrue(engine.conflicts.isEmpty)

        // Mutate the buffer and call refresh() without pumping the
        // runloop. The point of refresh is precisely to skip the
        // 300ms debounce after a programmatic edit (e.g. the
        // resolver path); the new conflict list must appear in
        // the same runloop tick.
        doc.text = Self.conflictBody
        engine.refresh()
        XCTAssertEqual(engine.conflicts.count, 1)
    }

    func test_rebindToDifferentDoc_swapsConflicts() {
        let engine = MergeConflictEngine()
        let docA = Document(title: "A", text: Self.conflictBody)
        let docB = Document(title: "B", text: "clean file\n")
        engine.bind(to: docA)
        XCTAssertEqual(engine.conflicts.count, 1)
        engine.bind(to: docB)
        XCTAssertTrue(engine.conflicts.isEmpty)
        XCTAssertEqual(engine.boundDocumentID, docB.id)
    }
}
