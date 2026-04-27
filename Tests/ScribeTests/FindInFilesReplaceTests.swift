//
//  FindInFilesReplaceTests.swift
//  Phase 4c — exercises FindInFilesEngine.replaceAll end-to-end:
//  builds a temp tree, runs a search, runs a replace pass, and asserts
//  the disk contents + summary numbers match expectations. The engine
//  is @MainActor, so all tests are wrapped in MainActor.run.
//

import XCTest
@testable import Scribe

final class FindInFilesReplaceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        let raw = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-fif-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw,
                                                withIntermediateDirectories: true)
        tempRoot = raw.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func write(_ contents: String, to relPath: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
        return url.resolvingSymlinksInPath()
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Replace mechanics

    @MainActor
    func test_replaceAll_literalSwapsEveryMatchAcrossFiles() async throws {
        let a = try write("alpha bravo alpha", to: "a.txt")
        let b = try write("alpha\nalpha", to: "b.txt")
        let c = try write("no matches here", to: "c.txt")

        let engine = FindInFilesEngine()
        let state = FindInFilesState()
        let opts = FindInFilesOptions(query: "alpha",
                                      matchCase: true,
                                      wholeWord: false,
                                      regex: false,
                                      includeGlobs: [],
                                      excludeGlobs: [])

        let summary = await withCheckedContinuation { (cont: CheckedContinuation<ReplaceSummary, Never>) in
            engine.replaceAll(options: opts,
                              replacement: "ALPHA",
                              urls: [a, b, c],
                              into: state) { summary in
                cont.resume(returning: summary)
            }
        }

        XCTAssertEqual(summary.filesScanned, 3)
        XCTAssertEqual(summary.filesChanged, 2)        // c.txt has zero matches
        XCTAssertEqual(summary.totalReplacements, 4)   // 2 in a, 2 in b
        XCTAssertTrue(summary.errors.isEmpty)
        XCTAssertEqual(try contents(of: a), "ALPHA bravo ALPHA")
        XCTAssertEqual(try contents(of: b), "ALPHA\nALPHA")
        XCTAssertEqual(try contents(of: c), "no matches here")
    }

    @MainActor
    func test_replaceAll_caseSensitivityRespectsOption() async throws {
        let url = try write("foo Foo FOO", to: "x.txt")
        let engine = FindInFilesEngine()
        let state = FindInFilesState()
        let opts = FindInFilesOptions(query: "foo",
                                      matchCase: true,
                                      wholeWord: false,
                                      regex: false,
                                      includeGlobs: [],
                                      excludeGlobs: [])

        let summary = await withCheckedContinuation { (cont: CheckedContinuation<ReplaceSummary, Never>) in
            engine.replaceAll(options: opts,
                              replacement: "BAR",
                              urls: [url],
                              into: state) { cont.resume(returning: $0) }
        }
        XCTAssertEqual(summary.totalReplacements, 1)
        XCTAssertEqual(try contents(of: url), "BAR Foo FOO")
    }

    @MainActor
    func test_replaceAll_regexBackrefSupported() async throws {
        let url = try write("Mr. Smith and Mrs. Jones", to: "x.txt")
        let engine = FindInFilesEngine()
        let state = FindInFilesState()
        let opts = FindInFilesOptions(query: "(Mr|Mrs)\\. (\\w+)",
                                      matchCase: true,
                                      wholeWord: false,
                                      regex: true,
                                      includeGlobs: [],
                                      excludeGlobs: [])

        let summary = await withCheckedContinuation { (cont: CheckedContinuation<ReplaceSummary, Never>) in
            engine.replaceAll(options: opts,
                              replacement: "$2 ($1)",
                              urls: [url],
                              into: state) { cont.resume(returning: $0) }
        }
        XCTAssertEqual(summary.totalReplacements, 2)
        XCTAssertEqual(try contents(of: url), "Smith (Mr) and Jones (Mrs)")
    }

    @MainActor
    func test_replaceAll_literalDollarSignsAreEscaped() async throws {
        // $1 in literal mode must NOT be interpreted as a backref.
        let url = try write("price = X", to: "x.txt")
        let engine = FindInFilesEngine()
        let state = FindInFilesState()
        let opts = FindInFilesOptions(query: "X",
                                      matchCase: true,
                                      wholeWord: false,
                                      regex: false,
                                      includeGlobs: [],
                                      excludeGlobs: [])

        let summary = await withCheckedContinuation { (cont: CheckedContinuation<ReplaceSummary, Never>) in
            engine.replaceAll(options: opts,
                              replacement: "$1",
                              urls: [url],
                              into: state) { cont.resume(returning: $0) }
        }
        XCTAssertEqual(summary.totalReplacements, 1)
        XCTAssertEqual(try contents(of: url), "price = $1")
    }

    @MainActor
    func test_replaceAll_emptyQueryIsNoOp() async throws {
        let url = try write("hello", to: "x.txt")
        let engine = FindInFilesEngine()
        let state = FindInFilesState()
        let opts = FindInFilesOptions(query: "",
                                      matchCase: false,
                                      wholeWord: false,
                                      regex: false,
                                      includeGlobs: [],
                                      excludeGlobs: [])

        let summary = await withCheckedContinuation { (cont: CheckedContinuation<ReplaceSummary, Never>) in
            engine.replaceAll(options: opts,
                              replacement: "world",
                              urls: [url],
                              into: state) { cont.resume(returning: $0) }
        }
        XCTAssertEqual(summary.filesScanned, 0)
        XCTAssertEqual(summary.totalReplacements, 0)
        XCTAssertEqual(try contents(of: url), "hello")
        XCTAssertFalse(state.isReplacing)
    }

    // MARK: - Phase 17: per-line exclusion

    @MainActor
    func test_replaceAll_skipsLinesInExcludedSet() async throws {
        // Three matching lines; user opts out of line 2. The disk
        // file should end up with replacements on lines 1 and 3 only.
        let url = try write(
            "line1 alpha here\nline2 alpha there\nline3 alpha last\n",
            to: "x.txt"
        )
        let engine = FindInFilesEngine()
        let state = FindInFilesState()
        let opts = FindInFilesOptions(query: "alpha",
                                      matchCase: true,
                                      wholeWord: false,
                                      regex: false,
                                      includeGlobs: [],
                                      excludeGlobs: [])

        let summary = await withCheckedContinuation { (cont: CheckedContinuation<ReplaceSummary, Never>) in
            engine.replaceAll(options: opts,
                              replacement: "ALPHA",
                              urls: [url],
                              excludedLinesByURL: [url: [2]],
                              into: state) { cont.resume(returning: $0) }
        }
        XCTAssertEqual(summary.totalReplacements, 2,
                       "line 2 must be skipped")
        XCTAssertEqual(try contents(of: url),
                       "line1 ALPHA here\nline2 alpha there\nline3 ALPHA last\n")
    }

    @MainActor
    func test_replaceAll_perLineExclusionPreservesBackrefs() async throws {
        // The slow path computes its own replacement string per
        // match — it needs to honour template substitution with the
        // same fidelity as the fast path.
        let url = try write("Mr. Smith\nMrs. Jones\nDr. Brown", to: "x.txt")
        let engine = FindInFilesEngine()
        let state = FindInFilesState()
        let opts = FindInFilesOptions(query: "(Mr|Mrs|Dr)\\. (\\w+)",
                                      matchCase: true,
                                      wholeWord: false,
                                      regex: true,
                                      includeGlobs: [],
                                      excludeGlobs: [])

        // Skip line 2 (Mrs. Jones) — backrefs on lines 1 and 3 must
        // still resolve correctly.
        let summary = await withCheckedContinuation { (cont: CheckedContinuation<ReplaceSummary, Never>) in
            engine.replaceAll(options: opts,
                              replacement: "$2 ($1)",
                              urls: [url],
                              excludedLinesByURL: [url: [2]],
                              into: state) { cont.resume(returning: $0) }
        }
        XCTAssertEqual(summary.totalReplacements, 2)
        XCTAssertEqual(try contents(of: url),
                       "Smith (Mr)\nMrs. Jones\nBrown (Dr)")
    }

    @MainActor
    func test_replaceAll_perLineExclusionAllLinesOff() async throws {
        // Excluding every line means the file gets neither read-write
        // churn nor a write at all; summary.filesChanged stays 0.
        let url = try write("alpha\nalpha\nalpha\n", to: "x.txt")
        let engine = FindInFilesEngine()
        let state = FindInFilesState()
        let opts = FindInFilesOptions(query: "alpha",
                                      matchCase: true,
                                      wholeWord: false,
                                      regex: false,
                                      includeGlobs: [],
                                      excludeGlobs: [])
        let summary = await withCheckedContinuation { (cont: CheckedContinuation<ReplaceSummary, Never>) in
            engine.replaceAll(options: opts,
                              replacement: "x",
                              urls: [url],
                              excludedLinesByURL: [url: [1, 2, 3]],
                              into: state) { cont.resume(returning: $0) }
        }
        XCTAssertEqual(summary.totalReplacements, 0)
        XCTAssertEqual(summary.filesChanged, 0)
        XCTAssertEqual(try contents(of: url), "alpha\nalpha\nalpha\n")
    }

    // MARK: - Original error / boundary cases

    @MainActor
    func test_replaceAll_recordsErrorForBinaryFile() async throws {
        // 8KB of binary data — replaceAll's runReplace tries UTF-8 decode
        // and should record a per-file error rather than crashing.
        let url = tempRoot.appendingPathComponent("blob.bin").resolvingSymlinksInPath()
        try Data(repeating: 0xFF, count: 8 * 1024).write(to: url)

        let engine = FindInFilesEngine()
        let state = FindInFilesState()
        let opts = FindInFilesOptions(query: "x",
                                      matchCase: true,
                                      wholeWord: false,
                                      regex: false,
                                      includeGlobs: [],
                                      excludeGlobs: [])

        let summary = await withCheckedContinuation { (cont: CheckedContinuation<ReplaceSummary, Never>) in
            engine.replaceAll(options: opts,
                              replacement: "y",
                              urls: [url],
                              into: state) { cont.resume(returning: $0) }
        }
        XCTAssertEqual(summary.filesScanned, 1)
        XCTAssertEqual(summary.filesChanged, 0)
        XCTAssertEqual(summary.errors.count, 1)
        XCTAssertEqual(summary.errors[0].0, url)
    }
}
