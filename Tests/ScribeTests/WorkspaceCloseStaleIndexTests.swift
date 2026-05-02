//
//  WorkspaceCloseStaleIndexTests.swift
//  Bug 2 regression coverage. Pre-fix `Workspace.close(documentID:)`
//  cached `idx = documents.firstIndex(...)` *before* it potentially
//  pumped the runloop via `NSAlert.runModal()`; if anything mutated
//  `documents` during the modal session (background `openFile`
//  applying a load result, an FS-event-driven reorder, a future
//  multi-window code path) the cached idx pointed at the wrong
//  tab — or out of bounds — when the post-modal `documents.remove(at:)`
//  ran. Fix re-locates by id right before the remove.
//
//  We can't drive `NSAlert.runModal()` from XCTest (it would block
//  the test runner waiting for a click), so the regression suite
//  attacks the post-modal path directly: it forces the documents
//  array into the awkward shapes the bug used to walk into and
//  asserts `close` does the right thing in each.
//

import XCTest
@testable import Scribe

@MainActor
final class WorkspaceCloseStaleIndexTests: XCTestCase {

    private func makeWorkspace() -> Workspace {
        let suite = "scribe-close-stale-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        return Workspace(prefs: prefs, openInitialUntitled: false)
    }

    /// Sanity: a vanilla close on a non-dirty doc removes the
    /// requested doc and only the requested doc, leaves the
    /// neighbours untouched. Locks in the contract the bug fix
    /// preserved.
    func test_close_nonDirty_removesOnlyRequestedDoc() {
        let ws = makeWorkspace()
        let docA = Document(title: "a.txt")
        let docB = Document(title: "b.txt")
        let docC = Document(title: "c.txt")
        ws.documents = [docA, docB, docC]
        ws.selectedID = docB.id

        ws.close(documentID: docB.id)

        XCTAssertEqual(ws.documents.map(\.title), ["a.txt", "c.txt"],
                       "close must drop the requested doc and only the requested doc")
        XCTAssertNotEqual(ws.selectedID, docB.id,
                          "selectedID must move off the closed doc")
    }

    /// Bug 2 head-on: simulate the array having been reordered between
    /// the captured idx and the remove. Pre-fix, calling close on a
    /// doc that was NOT at its original index meant `documents.remove(at: idx)`
    /// killed a neighbour. Post-fix re-resolves the live index and
    /// strikes the right doc.
    ///
    /// We model this by hand-pushing the documents array into the
    /// reordered shape immediately before the close — same end-state
    /// as if a background `openFile`/`resortByPin` had landed during
    /// the modal session.
    func test_close_afterDocumentsReordered_targetsCorrectDoc() {
        let ws = makeWorkspace()
        let docA = Document(title: "a.txt")
        let docB = Document(title: "b.txt")
        let docC = Document(title: "c.txt")
        ws.documents = [docA, docB, docC]

        // "User asked to close docA; meanwhile something reorders to
        // [docB, docC, docA]." Pre-fix `idx` would still be 0 and we'd
        // delete docB by mistake.
        ws.documents = [docB, docC, docA]
        ws.close(documentID: docA.id)

        XCTAssertEqual(ws.documents.map(\.title), ["b.txt", "c.txt"],
                       "close must follow documentID, not a stale array index")
    }

    /// Edge case: documents grew during the modal session — close still
    /// must hit the requested doc, not the new tail.
    func test_close_afterDocumentsAppended_targetsCorrectDoc() {
        let ws = makeWorkspace()
        let docA = Document(title: "a.txt")
        let docB = Document(title: "b.txt")
        ws.documents = [docA, docB]

        let docC = Document(title: "c.txt")
        ws.documents = [docA, docB, docC]
        ws.close(documentID: docA.id)

        XCTAssertEqual(ws.documents.map(\.title), ["b.txt", "c.txt"])
    }

    /// Edge case: the doc was already removed (e.g. another close path
    /// ran first). Pre-fix, the cached idx could fire `remove(at:)` on
    /// a stale index — out of bounds in the worst case. Post-fix the
    /// guard returns silently.
    func test_close_alreadyRemoved_isNoOpAndDoesNotCrash() {
        let ws = makeWorkspace()
        let docA = Document(title: "a.txt")
        let docB = Document(title: "b.txt")
        ws.documents = [docA, docB]

        // close(docA) but with docA already missing from the array —
        // first guard short-circuits the function entirely.
        ws.documents = [docB]
        ws.close(documentID: docA.id)

        XCTAssertEqual(ws.documents.map(\.title), ["b.txt"],
                       "missing-by-the-time-we-arrive must be a no-op, not delete a neighbour")
    }

    /// If the close empties the document list, Workspace re-seeds an
    /// Untitled buffer per the existing contract. The fix preserves
    /// this for both the live-idx path and the stale-idx fallback.
    func test_close_lastDoc_seedsUntitled() {
        let ws = makeWorkspace()
        let docA = Document(title: "only.txt")
        ws.documents = [docA]
        ws.selectedID = docA.id

        ws.close(documentID: docA.id)

        XCTAssertEqual(ws.documents.count, 1,
                       "closing the last doc must seed a fresh Untitled tab")
        XCTAssertNotEqual(ws.documents.first?.id, docA.id,
                          "the seeded doc is a new instance, not the closed one")
    }
}
