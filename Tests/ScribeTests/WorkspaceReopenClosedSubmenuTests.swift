//
//  WorkspaceReopenClosedSubmenuTests.swift
//  Phase 48a — covers the new `Workspace.reopenClosed(url:)` and
//  `clearRecentlyClosed()` entry points that back the File →
//  Recently Closed submenu. Complements `WorkspaceReopenClosedTests`
//  which locks the top-of-stack ⌘⇧T path; these exercise the
//  pick-any-entry and clear paths surfaced by the menu.
//

import Combine
import XCTest
@testable import Scribe

@MainActor
final class WorkspaceReopenClosedSubmenuTests: XCTestCase {

    private func makeWorkspace() -> Workspace {
        let suite = "scribe-reopen-submenu-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        return Workspace(prefs: prefs, openInitialUntitled: false)
    }

    @discardableResult
    private func makeTempFiles(_ count: Int) -> [URL] {
        var urls: [URL] = []
        for i in 0..<count {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("scribe-reopen-submenu-\(UUID().uuidString)-\(i).txt")
            try? "content \(i)".write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        createdTempURLs.append(contentsOf: urls)
        return urls
    }

    private var createdTempURLs: [URL] = []

    override func tearDown() {
        for url in createdTempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdTempURLs.removeAll()
        super.tearDown()
    }

    /// Helper — close every open tab with a URL, leaving the stack
    /// populated in append order.
    private func closeAllOpenTabs(_ ws: Workspace) {
        let docs = Array(ws.documents)
        for doc in docs where doc.url != nil {
            ws.close(documentID: doc.id)
        }
    }

    // MARK: - reopenClosed(url:) — middle / arbitrary pick

    func test_reopenClosedURL_removesThatEntryAndOpensTab() {
        let ws = makeWorkspace()
        let urls = makeTempFiles(3)
        for u in urls { ws.openFile(at: u) }
        closeAllOpenTabs(ws)

        // Stack order after three closes: urls[0], urls[1], urls[2].
        XCTAssertEqual(ws.recentlyClosedURLs.count, 3)

        // Pick the middle entry. That's the "user chose urls[1] from
        // the submenu" path — not the top of stack, which is what
        // ⌘⇧T would pop.
        let ok = ws.reopenClosed(url: urls[1])
        XCTAssertTrue(ok, "existing URL should be consumed and opened")

        XCTAssertEqual(ws.recentlyClosedURLs.count, 2,
                       "picked entry is removed from the stack")
        XCTAssertFalse(ws.recentlyClosedURLs.contains(where: {
            $0.standardizedFileURL == urls[1].standardizedFileURL
        }), "only the picked URL is removed")
        XCTAssertTrue(ws.documents.contains(where: {
            $0.url?.standardizedFileURL == urls[1].standardizedFileURL
        }), "picked URL should appear as an open tab")
    }

    func test_reopenClosedURL_preservesRelativeOrderOfRemaining() {
        let ws = makeWorkspace()
        let urls = makeTempFiles(3)
        for u in urls { ws.openFile(at: u) }
        closeAllOpenTabs(ws)

        // Pop the middle — survivors should stay in their original
        // append order (no reshuffling).
        _ = ws.reopenClosed(url: urls[1])
        XCTAssertEqual(
            ws.recentlyClosedURLs.map { $0.standardizedFileURL },
            [urls[0].standardizedFileURL, urls[2].standardizedFileURL]
        )
    }

    func test_reopenClosedURL_returnsFalseForUnknownURL() {
        let ws = makeWorkspace()
        let urls = makeTempFiles(1)
        ws.openFile(at: urls[0])
        closeAllOpenTabs(ws)

        // Build a URL that was never closed — the stack has exactly
        // `urls[0]` at this point.
        let phantom = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-nonexistent-\(UUID().uuidString).txt")

        let ok = ws.reopenClosed(url: phantom)
        XCTAssertFalse(ok, "unknown URL should be rejected cleanly")
        XCTAssertEqual(ws.recentlyClosedURLs.count, 1,
                       "unknown URL lookup must not mutate the stack")
    }

    func test_reopenClosedURL_dropsMissingFileAndReturnsFalse() {
        let ws = makeWorkspace()
        let urls = makeTempFiles(2)
        for u in urls { ws.openFile(at: u) }
        closeAllOpenTabs(ws)

        // Delete urls[0] off disk to simulate a Finder race.
        try? FileManager.default.removeItem(at: urls[0])

        let ok = ws.reopenClosed(url: urls[0])
        XCTAssertFalse(ok, "missing-on-disk URL should report failure")
        XCTAssertFalse(ws.recentlyClosedURLs.contains(where: {
            $0.standardizedFileURL == urls[0].standardizedFileURL
        }), "phantom entry should still be purged from the stack")
        XCTAssertFalse(ws.documents.contains(where: {
            $0.url?.standardizedFileURL == urls[0].standardizedFileURL
        }), "no tab should be opened for a deleted file")
    }

    // MARK: - clearRecentlyClosed

    func test_clearRecentlyClosed_emptiesStack() {
        let ws = makeWorkspace()
        let urls = makeTempFiles(3)
        for u in urls { ws.openFile(at: u) }
        closeAllOpenTabs(ws)
        XCTAssertEqual(ws.recentlyClosedURLs.count, 3)

        ws.clearRecentlyClosed()
        XCTAssertTrue(ws.recentlyClosedURLs.isEmpty)
    }

    func test_clearRecentlyClosed_onEmptyStack_isNoop() {
        let ws = makeWorkspace()
        XCTAssertTrue(ws.recentlyClosedURLs.isEmpty)

        // Call should be safe even when nothing's in the stack; no
        // crash, no unwanted @Published tick.
        var ticks = 0
        let cancel = ws.objectWillChange.sink { _ in ticks += 1 }
        ws.clearRecentlyClosed()
        cancel.cancel()

        XCTAssertTrue(ws.recentlyClosedURLs.isEmpty)
        XCTAssertEqual(ticks, 0,
                       "no-op clear should avoid spurious objectWillChange")
    }
}
