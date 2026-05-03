//
//  WorkspaceCLIArgsTests.swift
//  Phase 54 — exercises the new column / readOnly / lexerOverride
//  parameters on `Workspace.openFile(at:line:column:readOnly:lexerOverride:)`.
//
//  Why test at the Workspace seam:
//    The wrapper-side validation (Tests/ScribeTests/ScribeCLITests.swift)
//    pins `Scripts/scribe`'s parsing surface. The env-vars-to-Document
//    plumbing happens inside Workspace.openFile, which is reachable
//    from Swift without spinning up an NSApplication. We seed real
//    temp files because openFile short-circuits through an existence
//    check that a stub URL would fail.
//

import XCTest
@testable import Scribe

@MainActor
final class WorkspaceCLIArgsTests: XCTestCase {

    private func makeWorkspace() -> Workspace {
        let suite = "scribe-cli-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        return Workspace(prefs: prefs, openInitialUntitled: false)
    }

    @discardableResult
    private func makeTempFile(content: String = "alpha\nbeta\ngamma") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-cli-\(UUID().uuidString).txt")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        createdTempURLs.append(url)
        return url
    }

    private var createdTempURLs: [URL] = []

    override func tearDown() {
        for url in createdTempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdTempURLs.removeAll()
        super.tearDown()
    }

    // MARK: - Read-only flag

    func test_openFile_readOnly_setsDocumentFlag() {
        let ws = makeWorkspace()
        let url = makeTempFile()
        ws.openFile(at: url, readOnly: true)
        guard let doc = ws.documents.first else {
            return XCTFail("openFile did not produce a document")
        }
        XCTAssertTrue(doc.isReadOnly,
                      "openFile(readOnly: true) must stamp doc.isReadOnly")
    }

    func test_openFile_defaultReadOnly_isFalse() {
        let ws = makeWorkspace()
        let url = makeTempFile()
        ws.openFile(at: url)
        guard let doc = ws.documents.first else {
            return XCTFail("openFile did not produce a document")
        }
        XCTAssertFalse(doc.isReadOnly,
                       "default openFile must leave doc.isReadOnly == false")
    }

    func test_openFile_reopenWithReadOnly_upgradesExistingDoc() {
        // The reuse path (file already open) used to ignore the
        // CLI flags. Phase 54 propagates them so a `scribe -r
        // already-open.md` invocation locks the live tab without
        // requiring close-and-reopen.
        let ws = makeWorkspace()
        let url = makeTempFile()
        ws.openFile(at: url)                       // first open: writable
        ws.openFile(at: url, readOnly: true)       // reopen: should lock
        let matches = ws.documents.filter {
            $0.url?.standardizedFileURL == url.standardizedFileURL
        }
        XCTAssertEqual(matches.count, 1,
                       "reopen path must reuse the existing tab, not duplicate it")
        XCTAssertTrue(matches.first?.isReadOnly ?? false,
                      "reopen with readOnly: true must upgrade the live tab")
    }

    // MARK: - Lexer override

    func test_openFile_lexerOverride_setsDocumentField() {
        let ws = makeWorkspace()
        let url = makeTempFile()
        ws.openFile(at: url, lexerOverride: "swift")
        guard let doc = ws.documents.first else {
            return XCTFail("openFile did not produce a document")
        }
        XCTAssertEqual(doc.lexerOverride, "swift")
    }

    func test_openFile_lexerOverrideEmpty_leavesDocumentNil() {
        // The wrapper passes an empty string when the user doesn't
        // request `-L`; we treat it as "no override" so the catalog
        // falls back to extension-based auto-detection.
        let ws = makeWorkspace()
        let url = makeTempFile()
        ws.openFile(at: url, lexerOverride: "")
        guard let doc = ws.documents.first else {
            return XCTFail("openFile did not produce a document")
        }
        XCTAssertNil(doc.lexerOverride,
                     "empty-string lexerOverride must collapse to nil")
    }

    // MARK: - Column / line atomic landing

    func test_openFile_lineAndColumn_landsOnAtomicTarget() {
        // PendingScrollTarget bundles line + column so the editor
        // applies them in one tick. Phase 49c introduced the
        // struct; Phase 54 wires the column field through the CLI.
        let ws = makeWorkspace()
        let url = makeTempFile()
        ws.openFile(at: url, line: 2, column: 3)
        guard let doc = ws.documents.first,
              let target = doc.pendingScroll else {
            return XCTFail("openFile did not stamp pendingScroll")
        }
        XCTAssertEqual(target.line, 2)
        XCTAssertEqual(target.column, 3)
    }

    func test_openFile_lineWithoutColumn_keepsColumnNil() {
        // Pre-Phase 54 surface: `-l 2` alone selects the whole
        // destination line (high-visibility cue). Verify nil
        // column survives the new signature.
        let ws = makeWorkspace()
        let url = makeTempFile()
        ws.openFile(at: url, line: 2)
        guard let doc = ws.documents.first,
              let target = doc.pendingScroll else {
            return XCTFail("openFile did not stamp pendingScroll")
        }
        XCTAssertEqual(target.line, 2)
        XCTAssertNil(target.column,
                     "no -c argument must leave column nil for the row-select path")
    }
}
