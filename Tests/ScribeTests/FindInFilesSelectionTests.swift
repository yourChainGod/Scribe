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
    }
}
