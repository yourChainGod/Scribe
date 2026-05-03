//
//  MarkdownTaskToggleTests.swift
//  Phase 53b — every case the task-toggle parser has to handle:
//  unchecked → checked, checked → unchecked, plain bullet promoted
//  to a task, and the pile of no-op shapes (non-list lines,
//  malformed checkboxes, weird whitespace, non-ASCII after the
//  marker).
//

import XCTest
@testable import Scribe

final class MarkdownTaskToggleTests: XCTestCase {

    // MARK: - Flip (already a task list item)

    func test_uncheckedFlipsToChecked() {
        // The happy path. The caret is on `- [ ] foo`; the user
        // hits the shortcut and the inner space becomes `x`. The
        // byte offset `3` is the position of the ` ` between the
        // two brackets ("- [" is 3 bytes: `-`, ` `, `[`).
        XCTAssertEqual(markdownTaskToggle(line: "- [ ] foo"),
                       .flip(byteOffset: 3, newCharacter: "x"))
    }

    func test_checkedFlipsToUnchecked() {
        XCTAssertEqual(markdownTaskToggle(line: "- [x] done"),
                       .flip(byteOffset: 3, newCharacter: " "))
    }

    func test_uppercaseCheckedFlipsToUnchecked() {
        // GitHub-flavoured Markdown allows `[X]`; we read it and
        // emit lowercase `[ ]` on flip (the canonical form).
        XCTAssertEqual(markdownTaskToggle(line: "- [X] big check"),
                       .flip(byteOffset: 3, newCharacter: " "))
    }

    func test_starMarkerFlips() {
        // Should work with any valid unordered marker, not just `-`.
        XCTAssertEqual(markdownTaskToggle(line: "* [ ] starry"),
                       .flip(byteOffset: 3, newCharacter: "x"))
    }

    func test_plusMarkerFlips() {
        XCTAssertEqual(markdownTaskToggle(line: "+ [x] plussy"),
                       .flip(byteOffset: 3, newCharacter: " "))
    }

    // MARK: - Indentation

    func test_indentedTaskFlipsAtRightOffset() {
        // `  - [ ] foo` — two spaces of indent. The `[_]` inner
        // byte sits at offset 5 (two spaces + `- [`).
        XCTAssertEqual(markdownTaskToggle(line: "  - [ ] nested"),
                       .flip(byteOffset: 5, newCharacter: "x"))
    }

    func test_tabIndentedTaskFlipsAtRightOffset() {
        // `\t- [ ] foo` — tab + `- [` = 4 bytes to the inner space.
        XCTAssertEqual(markdownTaskToggle(line: "\t- [x] tabby"),
                       .flip(byteOffset: 4, newCharacter: " "))
    }

    // MARK: - Promote (plain bullet → task list)

    func test_plainBulletPromotesToTask() {
        // The shortcut on a non-task bullet should not be a no-op;
        // it's the "start using tasks" action. Insert `[ ] ` at
        // byte offset 2 (right after `- `).
        XCTAssertEqual(markdownTaskToggle(line: "- draft item"),
                       .promote(byteOffset: 2))
    }

    func test_indentedPlainBulletPromotes() {
        // Indent + marker + space = 4 bytes before content start.
        XCTAssertEqual(markdownTaskToggle(line: "  - sub item"),
                       .promote(byteOffset: 4))
    }

    func test_emptyPlainBulletPromotes() {
        // Even an empty list item (user just typed `- `) can be
        // promoted — the caller may want to type the task right
        // after. Matches Typora's behaviour.
        XCTAssertEqual(markdownTaskToggle(line: "- "),
                       .promote(byteOffset: 2))
    }

    // MARK: - No-op shapes

    func test_plainParagraphIsNoOp() {
        // Non-list lines must not sprout a task checkbox. The
        // shortcut's mental model is "toggle the thing I'm on",
        // not "spawn a task list".
        XCTAssertEqual(markdownTaskToggle(line: "just a paragraph"),
                       .none)
    }

    func test_emptyLineIsNoOp() {
        XCTAssertEqual(markdownTaskToggle(line: ""),
                       .none)
    }

    func test_headingIsNoOp() {
        // ATX headings start with `#`, not a list bullet; a heading
        // is not a task list candidate.
        XCTAssertEqual(markdownTaskToggle(line: "## Section"),
                       .none)
    }

    func test_bulletWithoutSpaceIsNoOp() {
        // `-foo` (no space) isn't a list item. Toggle must leave
        // such lines alone — otherwise the user's `-9.5` / `-vv`
        // CLI example would get hijacked.
        XCTAssertEqual(markdownTaskToggle(line: "-foo"),
                       .none)
    }

    func test_linkReferenceIsNoOp() {
        // `- [label](url)` is a list item whose content starts
        // with a Markdown link reference `[label]`. The parser
        // must *not* interpret that opening `[` as a checkbox
        // bracket — both the inner char and the closing bracket
        // have to form a valid `[_] ` triad (space, x, or X) to
        // qualify.
        XCTAssertEqual(markdownTaskToggle(line: "- [label](url)"),
                       .none,
                       "link reference must not be misread as a checkbox")
    }

    func test_bracketWithOtherCharIsNoOp() {
        // `- [?] maybe` — the inner byte is `?`, not a checkbox
        // marker. Flipping it would corrupt the user's text.
        XCTAssertEqual(markdownTaskToggle(line: "- [?] maybe"),
                       .none)
    }

    func test_missingSpaceAfterCloseBracketIsNoOp() {
        // `- [x]foo` (no space after `]`) isn't a recognised task
        // list syntax. We reject rather than silently flip.
        XCTAssertEqual(markdownTaskToggle(line: "- [x]foo"),
                       .none)
    }

    func test_numberedListIsNoOp() {
        // Task lists only attach to unordered bullets; VS Code and
        // GitHub agree. An ordered list with a `[ ]` is a rarity
        // not worth supporting.
        XCTAssertEqual(markdownTaskToggle(line: "1. [ ] item"),
                       .none)
    }

    // MARK: - Mid-line content preservation

    func test_taskWithLongContentFlipsAtRightOffset() {
        // Content length after the marker doesn't change the
        // byte offset — it's always `indent + 3` for a task list
        // item using a single-byte marker and single-space indent.
        let line = "- [ ] a very long task description with punctuation!"
        XCTAssertEqual(markdownTaskToggle(line: line),
                       .flip(byteOffset: 3, newCharacter: "x"))
    }

    func test_nonAsciiContentDoesNotShiftOffset() {
        // Content after the checkbox is arbitrary UTF-8; it must
        // not affect the `[_]` offset (which sits before the
        // content). Exercises that the parser doesn't accidentally
        // drift when the line contains multi-byte characters.
        XCTAssertEqual(markdownTaskToggle(line: "- [ ] 中文任务"),
                       .flip(byteOffset: 3, newCharacter: "x"))
    }
}
