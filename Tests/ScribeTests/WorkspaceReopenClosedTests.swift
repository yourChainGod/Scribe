//
//  WorkspaceReopenClosedTests.swift
//  Phase 46c — covers the `recentlyClosedURLs` stack and the
//  `reopenLastClosed()` API backing the ⌘⇧T shortcut.
//
//  Notes:
//    - Uses real temp files because `openFile(at:)` short-circuits
//      through a file-existence check. A stub URL would never be
//      reopened by `reopenLastClosed` and the tests would silently
//      pass on a no-op path instead of the real branch.
//    - `close(documentID:)` runs on the main actor because it
//      sometimes pops an NSAlert for dirty docs; every doc we seed
//      here is clean, so the alert branch never fires.
//

import XCTest
@testable import Scribe

@MainActor
final class WorkspaceReopenClosedTests: XCTestCase {

    private func makeWorkspace() -> Workspace {
        let suite = "scribe-reopen-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        return Workspace(prefs: prefs, openInitialUntitled: false)
    }

    /// Create `count` temp files preloaded with unique content. Files
    /// are auto-removed in the test's `tearDown`; caller receives the
    /// URLs in creation order.
    @discardableResult
    private func makeTempFiles(_ count: Int) -> [URL] {
        var urls: [URL] = []
        for i in 0..<count {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("scribe-reopen-\(UUID().uuidString)-\(i).txt")
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

    // MARK: - basics

    func test_closingTab_pushesOntoRecentlyClosedStack() {
        let ws = makeWorkspace()
        let urls = makeTempFiles(1)
        ws.openFile(at: urls[0])
        guard let doc = ws.documents.first else {
            return XCTFail("openFile didn't produce a document")
        }

        ws.close(documentID: doc.id)

        XCTAssertEqual(ws.recentlyClosedURLs.count, 1)
        XCTAssertEqual(ws.recentlyClosedURLs.last?.standardizedFileURL,
                       urls[0].standardizedFileURL)
    }

    func test_closingUntitledTab_doesNotPushStack() {
        let ws = makeWorkspace()
        ws.newDocument()  // produces Untitled (no URL)
        guard let doc = ws.documents.first else {
            return XCTFail("newDocument didn't produce a document")
        }
        XCTAssertNil(doc.url)

        ws.close(documentID: doc.id)

        XCTAssertTrue(ws.recentlyClosedURLs.isEmpty,
                      "Untitled docs have no URL to restore from")
    }

    func test_reopenLastClosed_popsFromTopAndOpensNewTab() {
        let ws = makeWorkspace()
        let urls = makeTempFiles(2)
        ws.openFile(at: urls[0])
        ws.openFile(at: urls[1])

        // Close both — urls[0] pushed first, urls[1] pushed second;
        // reopen should therefore return urls[1] first (LIFO).
        let firstOpened = ws.documents.first(where: {
            $0.url?.standardizedFileURL == urls[0].standardizedFileURL
        })!
        let secondOpened = ws.documents.first(where: {
            $0.url?.standardizedFileURL == urls[1].standardizedFileURL
        })!
        ws.close(documentID: firstOpened.id)
        ws.close(documentID: secondOpened.id)

        let popped = ws.reopenLastClosed()
        XCTAssertEqual(popped?.standardizedFileURL,
                       urls[1].standardizedFileURL,
                       "reopen pops the most-recently-closed URL first")
        XCTAssertEqual(ws.recentlyClosedURLs.count, 1)
        XCTAssertEqual(ws.recentlyClosedURLs.last?.standardizedFileURL,
                       urls[0].standardizedFileURL)
    }

    func test_reopenLastClosed_onEmptyStack_returnsNil() {
        let ws = makeWorkspace()
        XCTAssertNil(ws.reopenLastClosed())
    }

    // MARK: - FIFO cap + dedupe

    func test_recentlyClosed_capsAtRecentlyClosedCap() {
        let ws = makeWorkspace()
        // Seed cap + 3 temp files and close them sequentially.
        let excess = Workspace.recentlyClosedCap + 3
        let urls = makeTempFiles(excess)
        for url in urls {
            ws.openFile(at: url)
            let doc = ws.documents.last!
            ws.close(documentID: doc.id)
        }
        XCTAssertEqual(ws.recentlyClosedURLs.count,
                       Workspace.recentlyClosedCap,
                       "stack should never exceed the cap")
        // The earliest entries dropped; the latest survived.
        XCTAssertEqual(ws.recentlyClosedURLs.first?.standardizedFileURL,
                       urls[3].standardizedFileURL)
        XCTAssertEqual(ws.recentlyClosedURLs.last?.standardizedFileURL,
                       urls[excess - 1].standardizedFileURL)
    }

    func test_recentlyClosed_dedupesRepeatedUrls() {
        let ws = makeWorkspace()
        let urls = makeTempFiles(1)

        for _ in 0..<3 {
            ws.openFile(at: urls[0])
            guard let doc = ws.documents.first(where: {
                $0.url?.standardizedFileURL == urls[0].standardizedFileURL
            }) else {
                return XCTFail("could not locate reopened doc")
            }
            ws.close(documentID: doc.id)
        }
        XCTAssertEqual(ws.recentlyClosedURLs.count, 1,
                       "same URL closed multiple times collapses to one slot")
    }

    // MARK: - Disk races

    func test_reopenLastClosed_skipsDeletedFiles() {
        let ws = makeWorkspace()
        let urls = makeTempFiles(2)
        ws.openFile(at: urls[0])
        ws.openFile(at: urls[1])
        let docs = Array(ws.documents)
        for doc in docs where doc.url != nil {
            ws.close(documentID: doc.id)
        }

        // Delete urls[1] (the top of the stack) so reopen should
        // fall through to urls[0].
        try? FileManager.default.removeItem(at: urls[1])

        let popped = ws.reopenLastClosed()
        XCTAssertEqual(popped?.standardizedFileURL,
                       urls[0].standardizedFileURL,
                       "missing-on-disk URLs are skipped silently")
        XCTAssertTrue(ws.recentlyClosedURLs.isEmpty,
                      "both entries consumed: urls[1] dropped, urls[0] popped")
    }
}
