//
//  WorkspacePinBoundaryTests.swift
//  Phase 48c — locks the `Workspace.pinBoundaryIndex` contract that
//  drives the TabBarView pin/unpin hairline separator. Keeping the
//  rule in the model (rather than the SwiftUI body) gives us a
//  testable seam without needing a headless NSView harness; the
//  view just asks "am I the last pinned index?" and trusts this
//  computation.
//

import XCTest
@testable import Scribe

@MainActor
final class WorkspacePinBoundaryTests: XCTestCase {

    private func suiteName() -> String { "scribe-pin-boundary-\(UUID().uuidString)" }

    private func makePrefs(suite: String) -> EditorPreferences {
        EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    private func makeWorkspace() -> Workspace {
        Workspace(prefs: makePrefs(suite: suiteName()),
                  openInitialUntitled: false)
    }

    // MARK: - nil / empty-like cases

    func test_pinBoundary_isNilForEmptyDocumentList() {
        let ws = makeWorkspace()
        XCTAssertTrue(ws.documents.isEmpty)
        XCTAssertNil(ws.pinBoundaryIndex,
                     "no tabs ⇒ no boundary; view should render no separator")
    }

    func test_pinBoundary_isNilWhenNothingPinned() {
        let ws = makeWorkspace()
        ws.documents = [
            Document(title: "A"),
            Document(title: "B"),
            Document(title: "C"),
        ]
        XCTAssertNil(ws.pinBoundaryIndex,
                     "all unpinned ⇒ no separator")
    }

    // MARK: - trailing pinned (no separator)

    func test_pinBoundary_returnsLastIndexWhenAllArePinned() {
        // Boundary index is the final slot — view guards on
        // `idx + 1 < count` so a strip of all-pinned tabs renders
        // zero separators, but the computation itself still fires.
        let ws = makeWorkspace()
        let a = Document(title: "A"); a.isPinned = true
        let b = Document(title: "B"); b.isPinned = true
        ws.documents = [a, b]
        XCTAssertEqual(ws.pinBoundaryIndex, 1)
    }

    // MARK: - canonical boundary

    func test_pinBoundary_pointsAtLastPinnedTab() {
        let ws = makeWorkspace()
        let a = Document(title: "A"); a.isPinned = true
        let b = Document(title: "B"); b.isPinned = true
        let c = Document(title: "C")                    // unpinned
        let d = Document(title: "D")                    // unpinned
        ws.documents = [a, b, c, d]
        XCTAssertEqual(ws.pinBoundaryIndex, 1,
                       "boundary ⇒ index of `b`, the trailing pinned tab")
    }

    func test_pinBoundary_withSinglePinnedHeadTab() {
        let ws = makeWorkspace()
        let a = Document(title: "A"); a.isPinned = true
        let b = Document(title: "B")
        ws.documents = [a, b]
        XCTAssertEqual(ws.pinBoundaryIndex, 0,
                       "one pinned tab at head → boundary at 0")
    }

    // MARK: - tracks togglePin

    func test_pinBoundary_followsTogglePinMutation() {
        let ws = makeWorkspace()
        let a = Document(title: "A", url: URL(fileURLWithPath: "/tmp/a"))
        let b = Document(title: "B", url: URL(fileURLWithPath: "/tmp/b"))
        let c = Document(title: "C", url: URL(fileURLWithPath: "/tmp/c"))
        ws.documents = [a, b, c]
        XCTAssertNil(ws.pinBoundaryIndex)

        // Pinning `b` should float it to the head AND expose the
        // boundary at index 0 of the post-resort array.
        ws.togglePin(b)
        XCTAssertEqual(ws.documents.first?.title, "B")
        XCTAssertEqual(ws.pinBoundaryIndex, 0)

        // Unpinning drops the boundary back to nil.
        ws.togglePin(b)
        XCTAssertNil(ws.pinBoundaryIndex)
    }

    // MARK: - separator gate (mirrors the view-level guard)

    func test_pinBoundary_gateHidesSeparatorWhenPinnedFillsStrip() {
        // Mirrors the `idx + 1 < documents.count` guard the view
        // layers on top of `pinBoundaryIndex`. Encodes the rule here
        // so a reviewer touching the separator logic in TabBarView
        // has a unit test to update alongside.
        let ws = makeWorkspace()
        let a = Document(title: "A"); a.isPinned = true
        ws.documents = [a]
        let boundary = ws.pinBoundaryIndex
        XCTAssertEqual(boundary, 0)
        let wouldRenderSeparator = (boundary != nil) &&
            (boundary! + 1 < ws.documents.count)
        XCTAssertFalse(wouldRenderSeparator,
                       "trailing pinned with no unpinned neighbour → no line")
    }

    func test_pinBoundary_gateShowsSeparatorWhenUnpinnedFollows() {
        let ws = makeWorkspace()
        let a = Document(title: "A"); a.isPinned = true
        let b = Document(title: "B")
        ws.documents = [a, b]
        let boundary = ws.pinBoundaryIndex
        XCTAssertEqual(boundary, 0)
        let wouldRenderSeparator = (boundary != nil) &&
            (boundary! + 1 < ws.documents.count)
        XCTAssertTrue(wouldRenderSeparator,
                      "pinned followed by unpinned → line should appear")
    }
}
