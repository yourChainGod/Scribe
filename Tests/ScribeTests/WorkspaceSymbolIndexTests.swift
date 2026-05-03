//
//  WorkspaceSymbolIndexTests.swift
//  Phase 65 — guardrails on the workspace-wide symbol indexer.
//  Builds a tmp-dir mini-repo on disk and runs the parser end-to-
//  end so the file-IO + size-cap + ordering invariants don't
//  rot. The MainActor-bound `rebuild` path is covered through a
//  small XCTestExpectation wait; the pure `parseAll` static is
//  also tested directly so a regression localises to either
//  the parsers or the orchestration.
//

import Combine
import XCTest
@testable import Scribe

@MainActor
final class WorkspaceSymbolIndexTests: XCTestCase {

    // MARK: - Helpers

    /// Build a one-shot tmp dir and return its URL plus a close-
    /// on-teardown cleanup. Each test gets its own root so two
    /// running in parallel can't cross-contaminate.
    private func makeTempRepo(_ files: [(name: String, body: String)]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-symidx-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        for (name, body) in files {
            let url = root.appendingPathComponent(name)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func collectFiles(under root: URL) -> [URL] {
        FileIndex.walk(root: root)
    }

    // MARK: - parseAll (pure)

    func test_parseAll_emitsSymbolsForSwiftFile() throws {
        let root = try makeTempRepo([
            ("Foo.swift",
             """
             struct Foo {
                 func bar() {}
             }
             """)
        ])
        let result = WorkspaceSymbolIndex.parseAll(files: collectFiles(under: root))
        XCTAssertEqual(result.symbols.count, 2)
        XCTAssertEqual(result.symbols.map(\.name).sorted(), ["Foo", "bar"])
        XCTAssertFalse(result.didTruncate)
        // url + line + name id format must match WorkspaceSymbol.makeID.
        let foo = result.symbols.first { $0.name == "Foo" }!
        XCTAssertEqual(foo.id,
                       WorkspaceSymbol.makeID(url: foo.url,
                                              line: foo.line,
                                              name: foo.name))
    }

    func test_parseAll_skipsUnsupportedExtensions() throws {
        let root = try makeTempRepo([
            ("ignore.bin", "not a source file"),
            ("notes.txt", "free-form text without symbols"),
            ("Real.swift", "struct Real {}"),
        ])
        let result = WorkspaceSymbolIndex.parseAll(files: collectFiles(under: root))
        XCTAssertEqual(result.symbols.count, 1)
        XCTAssertEqual(result.symbols.first?.name, "Real")
    }

    func test_parseAll_skipsBinaryUtf8DecodeFailures() throws {
        let root = try makeTempRepo([
            ("Real.swift", "struct Real {}"),
        ])
        // Drop a fake .swift file that can't decode as UTF-8 — the
        // parser should silently skip it.
        let bogus = root.appendingPathComponent("invalid.swift")
        try Data([0xFF, 0xFE, 0xFD]).write(to: bogus)
        let result = WorkspaceSymbolIndex.parseAll(files: collectFiles(under: root))
        XCTAssertEqual(result.symbols.count, 1,
                       "binary file masquerading as .swift must be skipped, not crash the scan")
        XCTAssertEqual(result.symbols.first?.name, "Real")
    }

    func test_parseAll_orderIsStable_byPathThenLine() throws {
        // Two files; expect sorted by path first, then line. Names
        // chosen so alphabetical path ordering disagrees with
        // creation order, exposing any "first-write-wins" bugs.
        let root = try makeTempRepo([
            ("z.swift",
             "struct ZTop {}\nstruct ZBottom {}"),
            ("a.swift",
             "struct ATop {}"),
        ])
        let result = WorkspaceSymbolIndex.parseAll(files: collectFiles(under: root))
        XCTAssertEqual(result.symbols.map(\.name),
                       ["ATop", "ZTop", "ZBottom"],
                       "results must sort by path then line")
    }

    func test_parseAll_collectsFromMultipleLanguages() throws {
        let root = try makeTempRepo([
            ("a.swift", "struct A {}"),
            ("b.py",    "def b(): pass"),
            ("c.go",    "package main\nfunc C() {}"),
            ("d.md",    "# Doc Heading"),
        ])
        let result = WorkspaceSymbolIndex.parseAll(files: collectFiles(under: root))
        let names = Set(result.symbols.map(\.name))
        XCTAssertTrue(names.contains("A"), "swift parser missing")
        XCTAssertTrue(names.contains("b"), "python parser missing")
        XCTAssertTrue(names.contains("C"), "go parser missing")
        XCTAssertTrue(names.contains("Doc Heading"), "markdown parser missing")
    }

    // MARK: - Rebuild lifecycle

    func test_rebuild_publishesSymbolsAndClearsIsIndexing() async throws {
        let root = try makeTempRepo([
            ("Foo.swift", "struct Foo {}"),
            ("Bar.swift", "func bar() {}"),
        ])
        let index = WorkspaceSymbolIndex()
        XCTAssertFalse(index.isIndexing)

        let exp = expectation(description: "indexing finishes")
        let cancellable = index.$isIndexing
            .dropFirst()                  // skip the initial false → true publish
            .sink { newValue in
                if newValue == false { exp.fulfill() }
            }
        index.rebuild(rootURL: root, files: collectFiles(under: root))
        // We expect: true (rebuild start) → false (Task finished).
        await fulfillment(of: [exp], timeout: 5)
        cancellable.cancel()

        XCTAssertEqual(index.symbols.count, 2)
        XCTAssertEqual(index.sourceRootURL, root)
        XCTAssertFalse(index.didTruncate)
    }

    func test_rebuild_thenClear_emptiesPublishedState() async throws {
        let root = try makeTempRepo([
            ("Foo.swift", "struct Foo {}"),
        ])
        let index = WorkspaceSymbolIndex()

        let done = expectation(description: "first rebuild finishes")
        let sub = index.$isIndexing.dropFirst().sink { v in
            if v == false { done.fulfill() }
        }
        index.rebuild(rootURL: root, files: collectFiles(under: root))
        await fulfillment(of: [done], timeout: 5)
        sub.cancel()

        XCTAssertFalse(index.symbols.isEmpty)
        index.clear()
        XCTAssertTrue(index.symbols.isEmpty)
        XCTAssertNil(index.sourceRootURL)
        XCTAssertFalse(index.isIndexing)
    }

    // MARK: - Truncation

    func test_parseAll_truncatesWhenSymbolCapReached() throws {
        // Generate a single file with > maxSymbols entries. Each
        // line is `func sN() {}` so the swift parser emits one
        // symbol per line.
        let cap = WorkspaceSymbolIndex.maxSymbols
        var body = ""
        for i in 0..<(cap + 100) {
            body += "func s\(i)() {}\n"
        }
        let root = try makeTempRepo([("Big.swift", body)])
        let result = WorkspaceSymbolIndex.parseAll(files: collectFiles(under: root))
        XCTAssertEqual(result.symbols.count, cap)
        XCTAssertTrue(result.didTruncate)
    }
}
