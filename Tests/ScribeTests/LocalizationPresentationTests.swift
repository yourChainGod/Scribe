//
//  LocalizationPresentationTests.swift
//  Phase 36d — regression coverage for UI strings that are assembled
//  in code before SwiftUI renders them.
//

import XCTest
@testable import Scribe

final class LocalizationPresentationTests: XCTestCase {
    func test_findBarStatusUsesLocalizedCountAndEmptyLabels() {
        XCTAssertEqual(
            FindBarPresentation.statusText(
                status: "",
                currentMatch: 3,
                matchCount: 8,
                query: "needle",
                countText: { current, total in "hit \(current)/\(total)" },
                noMatchesText: { "none" }
            ),
            "hit 3/8"
        )

        XCTAssertEqual(
            FindBarPresentation.statusText(
                status: "",
                currentMatch: 0,
                matchCount: 0,
                query: "needle",
                countText: { current, total in "hit \(current)/\(total)" },
                noMatchesText: { "none" }
            ),
            "none"
        )
    }

    func test_findBarActionStatusesUseLocalizedText() {
        XCTAssertEqual(
            FindBarPresentation.noMatchesStatus(localize: { "key:\($0)" }),
            "key:findbar.matches.none"
        )
        XCTAssertEqual(
            FindBarPresentation.wrappedStatus(
                forward: true,
                localize: { "key:\($0)" }
            ),
            "key:findbar.status.wrappedTop"
        )
        XCTAssertEqual(
            FindBarPresentation.replacedStatus(localize: { "key:\($0)" }),
            "key:findbar.status.replaced"
        )
        XCTAssertEqual(
            FindBarPresentation.replacedCountStatus(
                count: 5,
                text: { "changed \($0)" }
            ),
            "changed 5"
        )
    }

    // MARK: - Phase 58 — no-match red overlay rule

    func test_shouldHighlightNoMatch_emptyQuery_returnsFalse() {
        // Pre-search neutral state: nothing typed yet, the overlay
        // would distract more than it helps. Status text also stays
        // empty in this branch — the two presentations agree.
        XCTAssertFalse(
            FindBarPresentation.shouldHighlightNoMatch(query: "",
                                                       matchCount: 0)
        )
    }

    func test_shouldHighlightNoMatch_whitespaceOnlyQuery_returnsFalse() {
        // Whitespace-only entries are common when the user hits
        // space inside the field; treating them as "real query" would
        // flash the field red until the next character arrives.
        XCTAssertFalse(
            FindBarPresentation.shouldHighlightNoMatch(query: "   ",
                                                       matchCount: 0)
        )
        XCTAssertFalse(
            FindBarPresentation.shouldHighlightNoMatch(query: "\t",
                                                       matchCount: 0)
        )
    }

    func test_shouldHighlightNoMatch_queryWithMatches_returnsFalse() {
        // Anything > 0 matches ⇒ neutral border colour, even with a
        // non-empty status (e.g. "Wrapped").
        XCTAssertFalse(
            FindBarPresentation.shouldHighlightNoMatch(query: "foo",
                                                       matchCount: 1)
        )
        XCTAssertFalse(
            FindBarPresentation.shouldHighlightNoMatch(query: "foo",
                                                       matchCount: 42)
        )
    }

    func test_shouldHighlightNoMatch_queryButZeroMatches_returnsTrue() {
        // The signature case: user typed something, engine reports
        // zero hits — paint the overlay red.
        XCTAssertTrue(
            FindBarPresentation.shouldHighlightNoMatch(query: "qwerty",
                                                       matchCount: 0)
        )
    }

    func test_findInFilesReplaceSummaryUsesLocalizedFragments() {
        var summary = ReplaceSummary(filesScanned: 4,
                                     filesChanged: 2,
                                     totalReplacements: 6)
        summary.errors = [
            (URL(fileURLWithPath: "/tmp/a.txt"), "bad encoding"),
            (URL(fileURLWithPath: "/tmp/b.txt"), "permission denied"),
            (URL(fileURLWithPath: "/tmp/c.txt"), "locked")
        ]

        let text = FindInFilesPresentation.replaceSummaryText(
            summary,
            baseText: { replacements, changed, scanned in
                "done \(replacements) \(changed)/\(scanned)."
            },
            errorsText: { "problems: \($0)." },
            moreText: { "and \($0) more" }
        )

        XCTAssertEqual(
            text,
            "done 6 2/4. problems: a.txt: bad encoding; b.txt: permission denied and 1 more."
        )
    }

    func test_findInFilesSelectionLabelsUseLocalizedText() {
        XCTAssertEqual(
            FindInFilesPresentation.fileToggleHelp(
                isSelected: true,
                localize: { "key:\($0)" }
            ),
            "key:finfiles.selection.file.includeHelp"
        )
        XCTAssertEqual(
            FindInFilesPresentation.fileToggleAccessibility(
                isSelected: false,
                fileName: "Note.md",
                excludedText: { "excluded \($0)" }
            ),
            "excluded Note.md"
        )
        XCTAssertEqual(
            FindInFilesPresentation.matchToggleAccessibility(
                lineNumber: 42,
                isSelected: true,
                selectedText: { $0 ? "oui" : "non" },
                labelText: { line, selected in "line \(line): \(selected)" }
            ),
            "line 42: oui"
        )
    }

    func test_settingsSummariesUseLocalizedFormatters() {
        XCTAssertEqual(
            SettingsPresentation.fontSizeSummary(points: 14) { "\($0) points" },
            "14 points"
        )
        XCTAssertEqual(
            SettingsPresentation.tabWidthSummary(spaces: 4) { "\($0) cols" },
            "4 cols"
        )
        XCTAssertEqual(
            SettingsPresentation.recentFilesSummary(
                count: 7,
                maxCount: 20,
                text: { "\($0) kept / \($1) cap" }
            ),
            "7 kept / 20 cap"
        )
    }
}
