//
//  FindInFilesSelectionTests.swift
//  Phase 16 — covers the per-file inclusion / exclusion bookkeeping
//  that drives the FindInFilesSidebar replace UI. Pure-state tests;
//  the sidebar's NSAlert plumbing is out of scope here.
//

import XCTest
@testable import Scribe

@MainActor
final class FindInFilesSelectionTests: XCTestCase {

    private func seedResults(_ state: FindInFilesState,
                             count: Int,
                             matchesPerFile: Int = 3) {
        let results: [FileResult] = (0..<count).map { i in
            let url = URL(fileURLWithPath: "/tmp/scribe-find/\(i).txt")
            let matches: [LineMatch] = (0..<matchesPerFile).map { j in
                LineMatch(lineNumber: j + 1,
                          lineText: "line \(j)",
                          matchRanges: [0..<3])
            }
            return FileResult(url: url, matches: matches)
        }
        let total = count * matchesPerFile
        state.update(results: results,
                     totalMatches: total,
                     filesScanned: count,
                     filesWithMatches: count)
    }

    // MARK: - Defaults

    func test_defaultSelection_includesEveryFile() {
        let s = FindInFilesState()
        seedResults(s, count: 3)
        XCTAssertEqual(s.selectedURLs.count, 3)
        XCTAssertEqual(s.selectedMatchCount, 9)
        XCTAssertTrue(s.results.allSatisfy { s.isSelected($0.url) })
    }

    // MARK: - toggleSelection

    func test_toggleSelection_excludesAndReincludes() {
        let s = FindInFilesState()
        seedResults(s, count: 3)
        let url = s.results[1].url
        s.toggleSelection(url)
        XCTAssertFalse(s.isSelected(url))
        XCTAssertEqual(s.selectedURLs.count, 2)
        XCTAssertEqual(s.selectedMatchCount, 6)

        s.toggleSelection(url)
        XCTAssertTrue(s.isSelected(url))
        XCTAssertEqual(s.selectedURLs.count, 3)
        XCTAssertEqual(s.selectedMatchCount, 9)
    }

    // MARK: - selectAll / deselectAll

    func test_deselectAllThenSelectAll_roundTrips() {
        let s = FindInFilesState()
        seedResults(s, count: 4)
        s.deselectAll()
        XCTAssertEqual(s.selectedURLs.count, 0)
        XCTAssertEqual(s.selectedMatchCount, 0)

        s.selectAll()
        XCTAssertEqual(s.selectedURLs.count, 4)
        XCTAssertEqual(s.selectedMatchCount, 12)
    }

    // MARK: - Stale selection cleanup

    func test_freshSearch_dropsExclusionsForVanishedFiles() {
        // Exclude one URL, then re-run search with a result set that
        // doesn't contain it. The stale exclusion must be cleared so
        // it doesn't haunt a future search where that URL re-appears.
        let s = FindInFilesState()
        seedResults(s, count: 3)
        let droppedURL = s.results[0].url
        s.toggleSelection(droppedURL)
        XCTAssertTrue(s.excludedURLs.contains(droppedURL))

        // Second search returns only the OTHER two files.
        let kept = Array(s.results[1...])
        s.update(results: kept,
                 totalMatches: kept.reduce(0) { $0 + $1.matches.count },
                 filesScanned: 2,
                 filesWithMatches: 2)
        XCTAssertFalse(s.excludedURLs.contains(droppedURL),
                       "vanished URL should drop out of excludedURLs")
        XCTAssertEqual(s.selectedURLs.count, 2)
    }

    func test_freshSearch_preservesExclusionsForStillPresentFiles() {
        // The complement of the test above: when the same URL shows
        // up in the next result set, the user-facing exclusion bit
        // sticks. (Imagine: hit Replace, run search again to verify,
        // expect "this file I told you to skip" to still be skipped.)
        let s = FindInFilesState()
        seedResults(s, count: 3)
        let stickyURL = s.results[2].url
        s.toggleSelection(stickyURL)
        XCTAssertTrue(s.excludedURLs.contains(stickyURL))

        s.update(results: s.results,
                 totalMatches: 9,
                 filesScanned: 3,
                 filesWithMatches: 3)
        XCTAssertTrue(s.excludedURLs.contains(stickyURL),
                      "exclusion of a still-present URL must persist")
    }

    // MARK: - reset

    func test_reset_clearsExclusions() {
        let s = FindInFilesState()
        seedResults(s, count: 2)
        s.toggleSelection(s.results[0].url)
        s.reset()
        XCTAssertTrue(s.excludedURLs.isEmpty)
        XCTAssertTrue(s.excludedLines.isEmpty)
    }

    // MARK: - Phase 17: line-level selection

    func test_lineSelection_defaultsToOn() {
        let s = FindInFilesState()
        seedResults(s, count: 1, matchesPerFile: 3)
        let url = s.results[0].url
        for match in s.results[0].matches {
            XCTAssertTrue(s.isLineSelected(url, line: match.lineNumber))
        }
    }

    func test_toggleLineSelection_excludesAndReincludes() {
        let s = FindInFilesState()
        seedResults(s, count: 1, matchesPerFile: 3)
        let url = s.results[0].url
        s.toggleLineSelection(url, line: 2)
        XCTAssertFalse(s.isLineSelected(url, line: 2))
        XCTAssertTrue(s.isLineSelected(url, line: 1))
        XCTAssertTrue(s.isLineSelected(url, line: 3))
        XCTAssertEqual(s.selectedMatchCount, 2)

        s.toggleLineSelection(url, line: 2)
        XCTAssertTrue(s.isLineSelected(url, line: 2))
        XCTAssertEqual(s.selectedMatchCount, 3)
    }

    func test_toggleLineSelection_emptySetClearsURLEntry() {
        // Toggling all lines off and then back on should leave
        // excludedLines without that URL key — keeps the dict from
        // accumulating { url: [] } sentinels across edits.
        let s = FindInFilesState()
        seedResults(s, count: 1, matchesPerFile: 2)
        let url = s.results[0].url
        s.toggleLineSelection(url, line: 1)
        XCTAssertEqual(s.excludedLines[url], [1])
        s.toggleLineSelection(url, line: 1)
        XCTAssertNil(s.excludedLines[url])
    }

    func test_lineSelection_shadowedByFileExclusion() {
        // File-off ⇒ every line reads as deselected, regardless of
        // its own bit. The line bit is preserved so re-enabling the
        // file restores the user's earlier per-line choices.
        let s = FindInFilesState()
        seedResults(s, count: 1, matchesPerFile: 2)
        let url = s.results[0].url
        s.toggleLineSelection(url, line: 1)
        s.toggleSelection(url)              // file off
        XCTAssertFalse(s.isLineSelected(url, line: 1))
        XCTAssertFalse(s.isLineSelected(url, line: 2))
        XCTAssertEqual(s.selectedMatchCount, 0)

        s.toggleSelection(url)              // file back on
        XCTAssertFalse(s.isLineSelected(url, line: 1))   // earlier per-line bit restored
        XCTAssertTrue(s.isLineSelected(url, line: 2))
    }

    func test_selectedURLs_dropsFilesWithEveryLineDeselected() {
        let s = FindInFilesState()
        seedResults(s, count: 2, matchesPerFile: 2)
        let url = s.results[0].url
        s.toggleLineSelection(url, line: 1)
        s.toggleLineSelection(url, line: 2)
        // Every line of file 0 deselected ⇒ file drops out of
        // selectedURLs without us having to also flip the file
        // checkbox. The engine call gets a clean list of URLs that
        // actually need a write.
        XCTAssertEqual(s.selectedURLs, [s.results[1].url])
        XCTAssertEqual(s.selectedMatchCount, 2)
    }

    func test_excludedLinesByURL_filtersFilesAlreadyExcluded() {
        // If a file's top-level checkbox is off, its excludedLines
        // entries shouldn't propagate to the engine (no need — the
        // file isn't in `selectedURLs` at all).
        let s = FindInFilesState()
        seedResults(s, count: 2, matchesPerFile: 2)
        let url = s.results[0].url
        s.toggleLineSelection(url, line: 1)
        s.toggleSelection(url)              // turn off entire file
        XCTAssertNil(s.excludedLinesByURL[url],
                     "engine shouldn't see line filter for an excluded file")
    }

    func test_freshSearch_dropsLineEntriesForVanishedLineNumbers() {
        // Shape of the second result set differs from the first —
        // line 5 is gone. The exclusion bit on line 5 must clear so
        // a hypothetical future result with line 5 again starts
        // selected by default, matching the URL-level behaviour.
        let s = FindInFilesState()
        seedResults(s, count: 1, matchesPerFile: 5)
        let url = s.results[0].url
        s.toggleLineSelection(url, line: 5)
        XCTAssertEqual(s.excludedLines[url], [5])

        // Re-run search with only lines 1..3.
        let trimmed = (1...3).map {
            LineMatch(lineNumber: $0,
                      lineText: "line \($0)",
                      matchRanges: [0..<3])
        }
        s.update(results: [FileResult(url: url, matches: trimmed)],
                 totalMatches: 3,
                 filesScanned: 1,
                 filesWithMatches: 1)
        XCTAssertNil(s.excludedLines[url],
                     "line-5 exclusion must drop when line 5 vanishes")
    }
}
