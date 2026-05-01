//
//  WorkspaceTabReorderTests.swift
//  Phase 46a — covers `Workspace.moveDocument(fromIndex:toIndex:)`,
//  the single entry point the tab bar's drag-drop handler funnels
//  through. Tests run on `@MainActor` because Workspace mutations
//  are main-isolated.
//

import Combine
import XCTest
@testable import Scribe

@MainActor
final class WorkspaceTabReorderTests: XCTestCase {

    private func makeWorkspace(titles: [String]) -> (Workspace, [Document]) {
        let prefs = EditorPreferences(
            defaults: UserDefaults(suiteName: "scribe-reorder-\(UUID().uuidString)")!
        )
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let docs = titles.map { Document(title: $0) }
        workspace.documents = docs
        return (workspace, docs)
    }

    // MARK: - Happy path

    func test_moveForward_insertsBeforeDestinationIndex() {
        // [A, B, C, D] · move 0 → 2 ⇒ [B, A, C, D]
        // (Foundation move semantics: destination == target pre-move index)
        let (ws, docs) = makeWorkspace(titles: ["A", "B", "C", "D"])
        ws.moveDocument(fromIndex: 0, toIndex: 2)
        XCTAssertEqual(ws.documents.map(\.title), ["B", "A", "C", "D"])
        // Identities preserved, not freshly allocated.
        XCTAssertTrue(ws.documents.contains { $0 === docs[0] })
    }

    func test_moveBackward_insertsBeforeDestinationIndex() {
        // [A, B, C, D] · move 3 → 1 ⇒ [A, D, B, C]
        let (ws, _) = makeWorkspace(titles: ["A", "B", "C", "D"])
        ws.moveDocument(fromIndex: 3, toIndex: 1)
        XCTAssertEqual(ws.documents.map(\.title), ["A", "D", "B", "C"])
    }

    func test_moveToTail_usesCountAsDestination() {
        // [A, B, C, D] · move 0 → 4 ⇒ [B, C, D, A]
        let (ws, _) = makeWorkspace(titles: ["A", "B", "C", "D"])
        ws.moveDocument(fromIndex: 0, toIndex: 4)
        XCTAssertEqual(ws.documents.map(\.title), ["B", "C", "D", "A"])
    }

    func test_moveToHead_usesZero() {
        let (ws, _) = makeWorkspace(titles: ["A", "B", "C", "D"])
        ws.moveDocument(fromIndex: 2, toIndex: 0)
        XCTAssertEqual(ws.documents.map(\.title), ["C", "A", "B", "D"])
    }

    // MARK: - Selection stability

    func test_move_keepsSelectedIDStable_whenMovingSelectedDoc() {
        let (ws, docs) = makeWorkspace(titles: ["A", "B", "C"])
        ws.selectedID = docs[0].id
        ws.moveDocument(fromIndex: 0, toIndex: 3)
        XCTAssertEqual(ws.documents.map(\.title), ["B", "C", "A"])
        XCTAssertEqual(ws.selectedID, docs[0].id,
                       "selectedID tracks the document identity, not its index")
    }

    func test_move_keepsSelectedIDStable_whenMovingOtherDoc() {
        let (ws, docs) = makeWorkspace(titles: ["A", "B", "C"])
        ws.selectedID = docs[1].id
        ws.moveDocument(fromIndex: 0, toIndex: 3)
        XCTAssertEqual(ws.selectedID, docs[1].id)
    }

    // MARK: - No-ops

    func test_move_toSameSlot_isNoOp() {
        let (ws, _) = makeWorkspace(titles: ["A", "B", "C"])
        ws.moveDocument(fromIndex: 1, toIndex: 1)
        XCTAssertEqual(ws.documents.map(\.title), ["A", "B", "C"])
    }

    func test_move_toNextSlot_isNoOp() {
        // Inserting before index source+1 is the same slot the doc
        // already occupies; the guard short-circuits before mutating.
        let (ws, _) = makeWorkspace(titles: ["A", "B", "C"])
        ws.moveDocument(fromIndex: 1, toIndex: 2)
        XCTAssertEqual(ws.documents.map(\.title), ["A", "B", "C"])
    }

    func test_move_ignoresInvalidSourceIndex() {
        let (ws, _) = makeWorkspace(titles: ["A", "B"])
        ws.moveDocument(fromIndex: 5, toIndex: 0)
        ws.moveDocument(fromIndex: -1, toIndex: 0)
        XCTAssertEqual(ws.documents.map(\.title), ["A", "B"])
    }

    func test_move_clampsNegativeDestinationToHead() {
        let (ws, _) = makeWorkspace(titles: ["A", "B", "C"])
        ws.moveDocument(fromIndex: 2, toIndex: -10)
        XCTAssertEqual(ws.documents.map(\.title), ["C", "A", "B"])
    }

    func test_move_clampsOversizedDestinationToTail() {
        let (ws, _) = makeWorkspace(titles: ["A", "B", "C"])
        ws.moveDocument(fromIndex: 0, toIndex: 999)
        XCTAssertEqual(ws.documents.map(\.title), ["B", "C", "A"])
    }

    // MARK: - Degenerate shapes

    func test_move_onEmptyWorkspace_isNoOp() {
        let (ws, _) = makeWorkspace(titles: [])
        ws.moveDocument(fromIndex: 0, toIndex: 0)
        XCTAssertTrue(ws.documents.isEmpty)
    }

    func test_move_onSingleTabWorkspace_isNoOp() {
        let (ws, _) = makeWorkspace(titles: ["solo"])
        ws.moveDocument(fromIndex: 0, toIndex: 1)
        ws.moveDocument(fromIndex: 0, toIndex: 0)
        XCTAssertEqual(ws.documents.map(\.title), ["solo"])
    }

    // MARK: - @Published observation

    func test_move_triggersObjectWillChange_onRealMove() {
        let (ws, _) = makeWorkspace(titles: ["A", "B", "C"])
        let expectation = expectation(description: "objectWillChange fires")
        expectation.assertForOverFulfill = false
        let cancellable = ws.objectWillChange.sink { _ in
            expectation.fulfill()
        }
        ws.moveDocument(fromIndex: 0, toIndex: 2)
        wait(for: [expectation], timeout: 0.5)
        cancellable.cancel()
    }
}
