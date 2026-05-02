//
//  QuickOpenMRUTests.swift
//  Phase 49b — Quick Open (⌘P) shows already-open files at the top
//  of the list. Pre-49b they were in tab-strip order; now they are
//  ordered by `Document.lastActivatedAt` (descending) so the most-
//  recently-touched tab leads, mirroring VS Code's MRU behaviour.
//
//  Tests target the pure `QuickOpenController.sortedOpenDocuments`
//  helper plus the integration with `Workspace.selectedID.didSet`.
//

import XCTest
@testable import Scribe

@MainActor
final class QuickOpenMRUTests: XCTestCase {

    // MARK: - Pure helper

    func test_sortedOpenDocuments_putsMostRecentFirst() {
        let docA = Document(title: "A")
        let docB = Document(title: "B")
        let docC = Document(title: "C")
        docA.lastActivatedAt = Date(timeIntervalSinceReferenceDate: 100)
        docB.lastActivatedAt = Date(timeIntervalSinceReferenceDate: 300)
        docC.lastActivatedAt = Date(timeIntervalSinceReferenceDate: 200)

        let sorted = QuickOpenController.sortedOpenDocuments([docA, docB, docC])

        XCTAssertEqual(sorted.map(\.title), ["B", "C", "A"])
    }

    func test_sortedOpenDocuments_neverActivatedDocsKeepStripOrder() {
        // All three docs default to `Date.distantPast`. Sort must
        // fall back to the original tab-strip order — never re-shuffle
        // tabs the user has never visited.
        let docA = Document(title: "A")
        let docB = Document(title: "B")
        let docC = Document(title: "C")

        let sorted = QuickOpenController.sortedOpenDocuments([docA, docB, docC])

        XCTAssertEqual(sorted.map(\.title), ["A", "B", "C"])
    }

    func test_sortedOpenDocuments_activatedDocsLeadNeverActivatedOnes() {
        // Mixed: docB has a real timestamp, docA + docC are pristine.
        // Activated doc must lead; the two pristine docs keep their
        // original strip order.
        let docA = Document(title: "A")
        let docB = Document(title: "B")
        let docC = Document(title: "C")
        docB.lastActivatedAt = Date(timeIntervalSinceReferenceDate: 500)

        let sorted = QuickOpenController.sortedOpenDocuments([docA, docB, docC])

        XCTAssertEqual(sorted.map(\.title), ["B", "A", "C"])
    }

    func test_sortedOpenDocuments_emptyInputReturnsEmpty() {
        XCTAssertTrue(QuickOpenController.sortedOpenDocuments([]).isEmpty)
    }

    // MARK: - Workspace integration

    func test_selectedIDDidSet_stampsActivatedDocument() {
        // Hand-build a Workspace, append two docs, flip selection,
        // and confirm the timestamp moves with the selection so the
        // MRU sort would float the newly-selected doc to the top.
        let ws = makeBareWorkspace()
        let docA = Document(title: "A")
        let docB = Document(title: "B")
        ws.documents = [docA, docB]

        let before = Date()
        ws.selectedID = docA.id
        let afterA = Date()

        XCTAssertGreaterThanOrEqual(docA.lastActivatedAt, before)
        XCTAssertLessThanOrEqual(docA.lastActivatedAt, afterA)
        XCTAssertEqual(docB.lastActivatedAt, .distantPast,
                       "non-selected doc must not be stamped")

        // Switching to docB stamps docB and leaves docA's older
        // timestamp untouched — so docB now leads the MRU sort.
        ws.selectedID = docB.id

        XCTAssertGreaterThan(docB.lastActivatedAt, docA.lastActivatedAt)
        let sorted = QuickOpenController.sortedOpenDocuments(ws.documents)
        XCTAssertEqual(sorted.map(\.id), [docB.id, docA.id])
    }

    func test_selectedIDDidSet_ignoresUnknownIDs() {
        // Setting selectedID to a UUID that isn't in `documents`
        // (transient state during close / reorder) must be a no-op.
        let ws = makeBareWorkspace()
        let docA = Document(title: "A")
        ws.documents = [docA]

        ws.selectedID = UUID()

        XCTAssertEqual(docA.lastActivatedAt, .distantPast)
    }

    // MARK: - Helpers

    /// Build a Workspace with no auto-created Untitled tab so each
    /// test owns the contents of `documents` outright. The unique
    /// UserDefaults suite isolates tests from each other and from
    /// the host machine's preferences.
    private func makeBareWorkspace() -> Workspace {
        let suite = "scribe-quickopen-mru-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        return Workspace(prefs: prefs, openInitialUntitled: false)
    }
}
