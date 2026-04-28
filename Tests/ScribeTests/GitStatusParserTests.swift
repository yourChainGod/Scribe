//
//  GitStatusParserTests.swift
//  Phase 35b-1 — pin every porcelain v1 shape we expect to see in
//  the wild against the parser. These cases are the same matrix
//  `git status --porcelain=v1 -z` emits in real repos; if a future
//  git version invents a new XY combination, the .unknown branch
//  catches it and we surface the rendered glyph as-is rather than
//  crashing.
//

import XCTest
@testable import Scribe

final class GitStatusParserTests: XCTestCase {

    private let repoRoot = URL(fileURLWithPath: "/tmp/scribe-test-repo")

    // MARK: - Empty / malformed input

    func test_empty_returnsEmptyArray() {
        XCTAssertTrue(GitStatusParser.parse("", repoRoot: repoRoot).isEmpty)
    }

    func test_singleNul_returnsEmptyArray() {
        // git emits no output for a clean tree; we don't even get
        // a single NUL, but be defensive against the edge anyway.
        XCTAssertTrue(GitStatusParser.parse("\0", repoRoot: repoRoot).isEmpty)
    }

    func test_tooShortEntry_isSilentlySkipped() {
        // "AB" without space + path is malformed; we drop it
        // instead of crashing.
        XCTAssertTrue(GitStatusParser.parse("AB\0", repoRoot: repoRoot).isEmpty)
    }

    // MARK: - Single-row shapes

    func test_modifiedUnstaged_parsesAsBlankM() {
        // " M README.md" — modified in working tree, not yet staged.
        let raw = " M README.md\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].path, "README.md")
        XCTAssertEqual(rows[0].staged, .unmodified)
        XCTAssertEqual(rows[0].unstaged, .modified)
        XCTAssertFalse(rows[0].hasStagedChanges)
        XCTAssertTrue(rows[0].hasUnstagedChanges)
        XCTAssertFalse(rows[0].isUntracked)
        XCTAssertFalse(rows[0].isConflict)
    }

    func test_modifiedStaged_parsesAsMBlank() {
        // "M  README.md" — staged but no further unstaged edits.
        let raw = "M  README.md\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].staged, .modified)
        XCTAssertEqual(rows[0].unstaged, .unmodified)
        XCTAssertTrue(rows[0].hasStagedChanges)
        XCTAssertFalse(rows[0].hasUnstagedChanges)
    }

    func test_added_thenModified_parsesAsAM() {
        // "AM file.txt" — staged add, then further modified before
        // the next add. Should appear in BOTH staged and unstaged
        // sections of the sidebar.
        let raw = "AM new.txt\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].staged, .added)
        XCTAssertEqual(rows[0].unstaged, .modified)
        XCTAssertTrue(rows[0].hasStagedChanges)
        XCTAssertTrue(rows[0].hasUnstagedChanges)
    }

    func test_untracked_parsesAsQQ() {
        // "?? newfile" — pure untracked. Both columns are '?'.
        let raw = "?? newfile.swift\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].staged, .untracked)
        XCTAssertEqual(rows[0].unstaged, .untracked)
        XCTAssertTrue(rows[0].isUntracked)
        XCTAssertFalse(rows[0].hasStagedChanges)
    }

    // MARK: - Conflict matrix

    func test_unmergedBoth_isConflict() {
        // "UU file" — both sides modified during merge.
        let raw = "UU conflict.swift\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isConflict)
    }

    func test_addedBoth_isConflict() {
        // "AA file" — both sides added the same path during merge.
        let raw = "AA both-added.swift\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isConflict)
    }

    func test_deletedByUs_isConflict() {
        // "DU file" — we deleted, they modified. Standard conflict.
        let raw = "DU file.swift\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isConflict)
    }

    // MARK: - Rename / copy

    func test_renamed_consumesOriginalPath() {
        // "R  newname\0oldname\0" — rename detected by git's `-M`
        // heuristic. The parser must consume both NUL-separated
        // tokens for this entry, not bleed into the next row.
        let raw = "R  newname.swift\0oldname.swift\0 M next.swift\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].path, "newname.swift")
        XCTAssertEqual(rows[0].originalPath, "oldname.swift")
        XCTAssertEqual(rows[0].staged, .renamed)
        XCTAssertEqual(rows[1].path, "next.swift")
        XCTAssertNil(rows[1].originalPath)
    }

    func test_copied_consumesOriginalPath() {
        let raw = "C  copy.swift\0source.swift\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].path, "copy.swift")
        XCTAssertEqual(rows[0].originalPath, "source.swift")
        XCTAssertEqual(rows[0].staged, .copied)
    }

    // MARK: - Multi-entry stream

    func test_multipleEntries_parseInOrder() {
        // Stitched from a real-world status output: a staged add,
        // an unstaged modify, an untracked file, a deletion. Each
        // entry's bytes match exactly what `git status -z` emits.
        let raw = "A  README.md\0 M Sources/main.swift\0?? Tests/new.swift\0D  oldfile.swift\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].path, "README.md")
        XCTAssertEqual(rows[0].staged, .added)
        XCTAssertEqual(rows[1].path, "Sources/main.swift")
        XCTAssertEqual(rows[1].unstaged, .modified)
        XCTAssertEqual(rows[2].path, "Tests/new.swift")
        XCTAssertTrue(rows[2].isUntracked)
        XCTAssertEqual(rows[3].path, "oldfile.swift")
        XCTAssertEqual(rows[3].staged, .deleted)
    }

    // MARK: - Path resolution

    func test_path_resolvesAbsoluteAgainstRepoRoot() {
        let raw = " M src/Foo.swift\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].url.path,
                       "/tmp/scribe-test-repo/src/Foo.swift")
    }

    func test_pathWithSpaces_isPreservedVerbatim() {
        // `-z` is exactly the flag that lets paths with spaces
        // round-trip without git's escaping. The parser must leave
        // them alone (no shell unquoting / no normalization).
        let raw = " M src/with spaces/Foo.swift\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].path, "src/with spaces/Foo.swift")
    }

    // MARK: - Unknown codes

    func test_unknownCode_capturedNotCrashed() {
        // Imagine git ships a future "X" code we don't recognise.
        // The .unknown branch absorbs it and the row still renders.
        let raw = "X  exotic.swift\0"
        let rows = GitStatusParser.parse(raw, repoRoot: repoRoot)
        XCTAssertEqual(rows.count, 1)
        if case .unknown(let ch) = rows[0].staged {
            XCTAssertEqual(ch, "X")
        } else {
            XCTFail("Expected .unknown('X'), got \(rows[0].staged)")
        }
        XCTAssertEqual(rows[0].staged.glyph, "X")
    }
}
