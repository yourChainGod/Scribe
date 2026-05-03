//
//  MarkdownListContinuationTests.swift
//  Phase 53a — every shape the markdown list-continuation parser
//  has to recognise, in five clusters:
//
//    1. Unordered lists (`-`, `*`, `+`) with content / empty.
//    2. Ordered lists with number incrementing.
//    3. Task lists (`- [ ]` / `- [x]`) — continuation is *always*
//       a fresh unchecked box.
//    4. Block quotes (single + nested).
//    5. Edge cases: indentation preservation, non-list lines,
//       pathological input.
//
//  Each test pins exactly one behaviour. Inline rationale explains
//  *why* the expected output is what it is — most cases mirror VS
//  Code / Typora / Obsidian, and the tests document those choices
//  so a future "let's match Vim instead" rewrite has to consciously
//  flip them.
//

import XCTest
@testable import Scribe

final class MarkdownListContinuationTests: XCTestCase {

    // MARK: - Unordered lists

    func test_dashListContinuesWithSamePrefix() {
        // The bread-and-butter case: `- foo<Enter>` on a non-empty
        // bullet should produce another `- ` so the user can keep
        // typing items without re-typing the prefix.
        XCTAssertEqual(markdownListContinuation(previousLine: "- foo"),
                       .insert("- "))
    }

    func test_starListContinuesWithStar() {
        // CommonMark accepts `*` as an unordered marker. Continuation
        // must preserve the user's chosen marker — flipping `*`s to
        // `-`s mid-list would silently rewrite the user's prose.
        XCTAssertEqual(markdownListContinuation(previousLine: "* hello"),
                       .insert("* "))
    }

    func test_plusListContinuesWithPlus() {
        XCTAssertEqual(markdownListContinuation(previousLine: "+ point"),
                       .insert("+ "))
    }

    func test_emptyDashItemClearsPrefix() {
        // Pressing Enter on an empty bullet means "I'm done with the
        // list". The previous line's `- ` should be wiped so the
        // doc isn't littered with dangling bullets.
        XCTAssertEqual(markdownListContinuation(previousLine: "- "),
                       .clearPrefix(2))
    }

    func test_dashWithoutSpaceIsNotAList() {
        // `-foo` with no space is a paragraph starting with a hyphen
        // (CommonMark §5.2). We must not treat it as a list, or
        // pasted text like `-9.5°C` would sprout a phantom bullet.
        XCTAssertEqual(markdownListContinuation(previousLine: "-foo"),
                       .none)
    }

    // MARK: - Indentation

    func test_indentedListPreservesIndent() {
        // Nested lists are indistinguishable from un-nested ones at
        // the line level; the only signal is leading whitespace.
        // The continuation must echo the same indent or the user's
        // sub-list collapses back to the outer level.
        XCTAssertEqual(markdownListContinuation(previousLine: "  - sub"),
                       .insert("  - "))
    }

    func test_tabIndentedListPreservesTab() {
        XCTAssertEqual(markdownListContinuation(previousLine: "\t- tabby"),
                       .insert("\t- "))
    }

    func test_indentedEmptyListClearsBoth() {
        // Empty nested item: the user wants to break out one level.
        // Wiping just the bullet (and not the indent) would leave a
        // ghost-indented blank line; wiping the whole prefix is the
        // expected exit. Total = 2 spaces + 2-char marker = 4.
        XCTAssertEqual(markdownListContinuation(previousLine: "  - "),
                       .clearPrefix(4))
    }

    // MARK: - Ordered lists

    func test_orderedListIncrementsNumber() {
        // The N+1 rule comes from VS Code; Typora does it too. Some
        // markdown extensions don't care about the actual digits
        // (any number renders correctly), but most users expect to
        // see an incrementing counter.
        XCTAssertEqual(markdownListContinuation(previousLine: "1. first"),
                       .insert("2. "))
    }

    func test_orderedListAtArbitraryNumber() {
        XCTAssertEqual(markdownListContinuation(previousLine: "42. fortytwo"),
                       .insert("43. "))
    }

    func test_orderedListWithParenTerminator() {
        // CommonMark also accepts `1)` as an ordered marker. We
        // preserve whichever terminator the user used so a `1) foo`
        // list continues with `2)` rather than silently flipping
        // to `2.`.
        XCTAssertEqual(markdownListContinuation(previousLine: "1) item"),
                       .insert("2) "))
    }

    func test_orderedListEmptyClearsPrefix() {
        // `2. <Enter>` should kill the dangling `2. `. The marker
        // length is `digits + . + space` = 3.
        XCTAssertEqual(markdownListContinuation(previousLine: "2. "),
                       .clearPrefix(3))
    }

    func test_orderedListGiantNumberDoesNotOverflow() {
        // Pathological input with an astronomically large counter.
        // Falling through to `.none` keeps Scintilla in charge of
        // the newline and protects Int from overflow.
        let huge = String(repeating: "9", count: 30) + ". x"
        XCTAssertEqual(markdownListContinuation(previousLine: huge),
                       .none)
    }

    // MARK: - Task lists

    func test_taskListContinuesAsUnchecked() {
        // A continued task is always fresh-empty: the just-typed
        // item is "done" or "to-do", but the *next* item the user
        // is about to type is conceptually new. VS Code, Typora and
        // Obsidian all do this; we match.
        XCTAssertEqual(markdownListContinuation(previousLine: "- [ ] write tests"),
                       .insert("- [ ] "))
    }

    func test_completedTaskStillContinuesAsUnchecked() {
        // Same rule applies even when the previous task was checked.
        // The user's next typed item shouldn't inherit `[x]`.
        XCTAssertEqual(markdownListContinuation(previousLine: "- [x] shipped"),
                       .insert("- [ ] "))
    }

    func test_uppercaseCheckboxRecognised() {
        // GitHub-flavoured Markdown allows `[X]` (capital). We
        // recognise it on input but always emit lowercase `[ ]` on
        // continuation — the canonical empty form.
        XCTAssertEqual(markdownListContinuation(previousLine: "- [X] big check"),
                       .insert("- [ ] "))
    }

    func test_emptyTaskItemClearsPrefixIncludingCheckbox() {
        // `- [ ] <Enter>` on an empty task: clear bullet (`- `, 2
        // chars) + checkbox (`[ ] `, 4 chars) = 6.
        XCTAssertEqual(markdownListContinuation(previousLine: "- [ ] "),
                       .clearPrefix(6))
    }

    func test_taskListWithStarMarker() {
        // Checkbox parsing should work for any unordered marker.
        XCTAssertEqual(markdownListContinuation(previousLine: "* [ ] starry task"),
                       .insert("* [ ] "))
    }

    // MARK: - Block quotes

    func test_singleQuoteContinues() {
        XCTAssertEqual(markdownListContinuation(previousLine: "> quoted"),
                       .insert("> "))
    }

    func test_nestedQuoteContinues() {
        // `> > foo` is a two-deep quote. Continuation has to carry
        // both `>` characters with their interleaving spaces or the
        // user's nesting collapses one level on every Enter.
        XCTAssertEqual(markdownListContinuation(previousLine: "> > nested"),
                       .insert("> > "))
    }

    func test_emptyQuoteClearsPrefix() {
        // Same exit semantics as lists. `> ` → 2 chars.
        XCTAssertEqual(markdownListContinuation(previousLine: "> "),
                       .clearPrefix(2))
    }

    func test_emptyNestedQuoteClearsAllLevels() {
        // `> > ` → 4 chars; the user wants out of the whole quote
        // structure, not just the inner level, so we clear the
        // entire prefix in one shot.
        XCTAssertEqual(markdownListContinuation(previousLine: "> > "),
                       .clearPrefix(4))
    }

    func test_quoteWithoutTrailingSpaceStillRecognised() {
        // CommonMark allows `>foo` (no space). We accept that form
        // on input but emit the canonical `> ` (with space) on
        // continuation — what the renderer prefers and what the
        // user usually wants.
        XCTAssertEqual(markdownListContinuation(previousLine: ">word"),
                       .insert("> "))
    }

    // MARK: - Non-list lines

    func test_plainParagraphReturnsNone() {
        // A regular sentence isn't a list; the parser must not
        // hijack the newline.
        XCTAssertEqual(markdownListContinuation(previousLine: "Just a paragraph."),
                       .none)
    }

    func test_emptyLineReturnsNone() {
        // The user pressing Enter on an already-empty line should
        // produce another empty line, no list magic involved.
        XCTAssertEqual(markdownListContinuation(previousLine: ""),
                       .none)
    }

    func test_atxHeadingReturnsNone() {
        // Headings aren't list items; the next line shouldn't get a
        // hash prefix dropped on it.
        XCTAssertEqual(markdownListContinuation(previousLine: "## Section"),
                       .none)
    }

    func test_codeFenceReturnsNone() {
        // ```` ``` ```` is structural. The list-continuation parser
        // shouldn't treat it as anything (Scintilla itself handles
        // typing inside a fenced block).
        XCTAssertEqual(markdownListContinuation(previousLine: "```swift"),
                       .none)
    }

    // MARK: - Edge cases

    func test_listItemContainingDashInContent() {
        // The bullet rule looks at the line *start*; mid-line
        // hyphens like `state-of-the-art` mustn't confuse it.
        XCTAssertEqual(markdownListContinuation(previousLine: "- state-of-the-art"),
                       .insert("- "))
    }

    func test_listItemWithMultipleSpacesAfterBulletStillContinues() {
        // CommonMark allows extra spaces (`-   foo` defines a list
        // item with content `foo`). Our parser only requires *one*
        // space after the bullet; everything after that space is
        // content, including more spaces. Continuation emits the
        // canonical single-space form.
        XCTAssertEqual(markdownListContinuation(previousLine: "-   spaced content"),
                       .insert("- "))
    }
}
