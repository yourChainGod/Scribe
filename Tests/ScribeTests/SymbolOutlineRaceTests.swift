//
//  SymbolOutlineRaceTests.swift
//  Regression coverage for the Bug 1 fix in `SymbolOutline.update`
//  — the stale-result guard now reads `Task.isCancelled` of the
//  enclosing task (which is the correct signal that a newer update
//  has overtaken this one) rather than `self.debounceTask?.isCancelled`
//  which always reads the *newest* task and therefore never blocks
//  a stale write.
//
//  These tests exercise the observable contract: after a burst of
//  rapid updates, `outline.symbols` must reflect the *last* doc
//  passed in, never a stale snapshot from an earlier update().
//  We can't directly inject timing into the detached parse closure
//  without invasive refactor, but an integration-level test still
//  catches the regression that occurs when multiple updates land
//  inside the debounce window.
//

import XCTest
@testable import Scribe

@MainActor
final class SymbolOutlineRaceTests: XCTestCase {

    private func writeTempFile(_ text: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-outline-race-\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Two rapid updates against two different parseable docs — the
    /// later one must win. Regardless of how the internal debounce
    /// plays out, the final `symbols` should belong to `docB`.
    func test_rapidSuccessiveUpdates_lastDocWins() async throws {
        let swiftURLA = try writeTempFile(
            """
            func alphaOne() {}
            func alphaTwo() {}
            """,
            ext: "swift"
        )
        let swiftURLB = try writeTempFile(
            """
            func betaOnly() {}
            """,
            ext: "swift"
        )
        defer {
            try? FileManager.default.removeItem(at: swiftURLA)
            try? FileManager.default.removeItem(at: swiftURLB)
        }

        let docA = Document(title: swiftURLA.lastPathComponent,
                            text: try String(contentsOf: swiftURLA, encoding: .utf8),
                            url: swiftURLA)
        let docB = Document(title: swiftURLB.lastPathComponent,
                            text: try String(contentsOf: swiftURLB, encoding: .utf8),
                            url: swiftURLB)

        let outline = SymbolOutline()

        // Burst of updates with no await between them — stresses the
        // debounce + cancel path the bug fix lives on.
        outline.update(for: docA)
        outline.update(for: docB)
        outline.update(for: docA)
        outline.update(for: docB)

        // Wait long enough for debounce + parse + MainActor hop.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let names = outline.symbols.map(\.name)
        XCTAssertFalse(names.contains("alphaOne"),
                       "stale symbols from docA leaked into outline: \(names)")
        XCTAssertFalse(names.contains("alphaTwo"),
                       "stale symbols from docA leaked into outline: \(names)")
        XCTAssertTrue(names.contains("betaOnly"),
                      "expected docB symbols in outline, got: \(names)")
        XCTAssertFalse(outline.isParsing,
                       "isParsing should settle to false after the last update completes")
    }

    /// Switching to a doc with no parseable extension after a parse
    /// has been scheduled must empty the outline immediately — the
    /// in-flight Swift parse cannot resurrect stale symbols.
    func test_updateToUnparseableDoc_clearsStaleSymbols() async throws {
        let swiftURL = try writeTempFile(
            """
            func oldSymbol() {}
            """,
            ext: "swift"
        )
        defer { try? FileManager.default.removeItem(at: swiftURL) }

        let docSwift = Document(title: swiftURL.lastPathComponent,
                                text: try String(contentsOf: swiftURL, encoding: .utf8),
                                url: swiftURL)
        let docUntitled = Document(title: "untitled")

        let outline = SymbolOutline()
        outline.update(for: docSwift)
        // Immediate switch to unparseable doc should take the synchronous
        // clear path and leave no room for the background Swift parse to
        // race in.
        outline.update(for: docUntitled)

        // Wait long enough that the cancelled Swift parse, if it were
        // going to leak, would have done so.
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(outline.symbols, [],
                       "unparseable doc must present an empty outline; got \(outline.symbols.map(\.name))")
    }

    /// `update(for: nil)` cancels + clears. Regression guard: make
    /// sure an in-flight parse that later tries to write back is
    /// blocked by the new `Task.isCancelled` check.
    func test_updateToNil_afterScheduledParse_staysEmpty() async throws {
        let swiftURL = try writeTempFile(
            """
            func shouldNotAppear() {}
            """,
            ext: "swift"
        )
        defer { try? FileManager.default.removeItem(at: swiftURL) }

        let doc = Document(title: swiftURL.lastPathComponent,
                           text: try String(contentsOf: swiftURL, encoding: .utf8),
                           url: swiftURL)

        let outline = SymbolOutline()
        outline.update(for: doc)
        outline.update(for: nil)

        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(outline.symbols, [],
                       "nil doc path must stay empty; got \(outline.symbols.map(\.name))")
    }
}
