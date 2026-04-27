//
//  FileIndexTests.swift
//  Phase 6 — exercises the off-main `FileIndex.walk` so we can be sure
//  Quick Open File sees the right set of files. Builds a synthetic tree
//  in a temp directory and asserts what gets included / skipped.
//

import XCTest
@testable import Scribe

final class FileIndexTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        // /var/folders is a symlink to /private/var/folders on macOS,
        // and FileManager.enumerator returns the resolved path. Create
        // the directory first, then resolve so the resolution actually
        // walks the symlink chain.
        let raw = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-fileindex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: raw,
            withIntermediateDirectories: true)
        tempRoot = raw.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Helpers

    private func touch(_ relativePath: String) throws {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func relativePaths(of urls: [URL]) -> Set<String> {
        // Resolve both sides because /var ↔ /private/var symlink on
        // macOS makes raw `path` comparison fragile.
        let resolvedRoot = tempRoot.resolvingSymlinksInPath().path + "/"
        return Set(urls.map { url in
            let resolved = url.resolvingSymlinksInPath().path
            return String(resolved.dropFirst(resolvedRoot.count))
        })
    }

    // MARK: - Tests

    func test_walk_includesRegularSourceFiles() throws {
        try touch("README.md")
        try touch("src/main.swift")
        try touch("src/util/helpers.swift")
        let names = relativePaths(of: FileIndex.walk(root: tempRoot))
        XCTAssertEqual(names, [
            "README.md",
            "src/main.swift",
            "src/util/helpers.swift",
        ])
    }

    func test_walk_skipsDotFilesAndDotDirectories() throws {
        try touch(".env")
        try touch(".gitignore")
        try touch(".git/HEAD")            // .git is in IgnoredPaths
        try touch("src/.DS_Store")
        try touch("src/keep.txt")
        let names = relativePaths(of: FileIndex.walk(root: tempRoot))
        XCTAssertEqual(names, ["src/keep.txt"])
    }

    func test_walk_skipsCuratedHeavyDirectories() throws {
        // Curated names from IgnoredPaths.directories — picking the most
        // common ones developers actually run into.
        try touch("node_modules/react/index.js")
        try touch(".build/debug/Scribe")
        try touch("DerivedData/Foo/Index/v5.json")
        try touch("Pods/Alamofire/Source.swift")
        try touch("target/debug/binary")
        try touch("dist/bundle.js")
        try touch("__pycache__/foo.cpython-311.pyc")
        try touch(".venv/lib/python3.11/site-packages/x.py")
        try touch("kept/main.rs")
        let names = relativePaths(of: FileIndex.walk(root: tempRoot))
        XCTAssertEqual(names, ["kept/main.rs"])
    }

    func test_walk_handlesEmptyDirectoryGracefully() {
        let urls = FileIndex.walk(root: tempRoot)
        XCTAssertTrue(urls.isEmpty)
    }

    func test_walk_returnsURLsSpanningMultipleDepths() throws {
        try touch("a.txt")
        try touch("d1/b.txt")
        try touch("d1/d2/c.txt")
        try touch("d1/d2/d3/d.txt")
        let names = relativePaths(of: FileIndex.walk(root: tempRoot))
        XCTAssertEqual(names, [
            "a.txt",
            "d1/b.txt",
            "d1/d2/c.txt",
            "d1/d2/d3/d.txt",
        ])
    }

    // MARK: - IgnoredPaths

    func test_ignoredPaths_dotPrefixIsAlwaysSkipped() {
        XCTAssertTrue(IgnoredPaths.shouldSkipDirectory(named: ".anything"))
        XCTAssertTrue(IgnoredPaths.shouldSkipDirectory(named: ".git"))
    }

    func test_ignoredPaths_curatedNames() {
        XCTAssertTrue(IgnoredPaths.shouldSkipDirectory(named: "node_modules"))
        XCTAssertTrue(IgnoredPaths.shouldSkipDirectory(named: "DerivedData"))
        XCTAssertTrue(IgnoredPaths.shouldSkipDirectory(named: "target"))
    }

    func test_ignoredPaths_allowsRegularNames() {
        XCTAssertFalse(IgnoredPaths.shouldSkipDirectory(named: "src"))
        XCTAssertFalse(IgnoredPaths.shouldSkipDirectory(named: "Sources"))
        XCTAssertFalse(IgnoredPaths.shouldSkipDirectory(named: "Tests"))
    }
}
