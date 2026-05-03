//
//  MarkdownTaskToggle.swift
//  Phase 53b — pure parser that decides what to do when the user
//  asks to toggle / add a task-list checkbox on the current line.
//
//  Keyboard-driven: the user hits ⇧⌘⏎ (or whatever the shortcut is
//  bound to) and expects one of three things to happen on the line
//  their caret is currently on:
//
//    1. `- [ ] foo` → `- [x] foo` (flip unchecked → checked)
//    2. `- [x] foo` → `- [ ] foo` (flip checked → unchecked)
//    3. `- foo`     → `- [ ] foo` (promote plain bullet to task)
//
//  Anything that isn't a list item is a no-op — Typora / Obsidian
//  insert a new `- [ ] ` on non-list lines, which we *considered*
//  but deliberately rejected: the shortcut's mental model is
//  "toggle the thing I'm on", not "spawn a task list I wasn't
//  asking for".
//
//  Pure + deterministic so XCTest pins the table of cases without
//  any Scintilla dependency. Scintilla glue converts the returned
//  action to `SCI_DELETERANGE` / `SCI_INSERTTEXT` calls at the
//  right byte offsets.
//

import Foundation

/// Outcome of running `markdownTaskToggle` on a line.
///
///   - `none`             — line isn't a list item; caller should
///                          do nothing so the shortcut doesn't
///                          graffiti unrelated lines.
///   - `flip(byteOffset)` — line already has a checkbox; the
///                          caller should overwrite the single
///                          byte at `byteOffset` within the line
///                          to flip its state. The new character
///                          is supplied as `newCharacter` so the
///                          caller doesn't have to re-parse.
///   - `promote(byteOffset)` — line is a plain bullet; the caller
///                          should insert `"[ ] "` (four bytes)
///                          at `byteOffset` within the line so
///                          the bullet becomes a task list item.
public enum MarkdownTaskToggleAction: Equatable {
    case none
    case flip(byteOffset: Int, newCharacter: Character)
    case promote(byteOffset: Int)
}

/// Run the parser on `line` (the full text of one line, no
/// trailing newline) and return the edit the caller should apply.
///
/// The byte offsets are UTF-8 byte counts within the line — they
/// can be fed directly into Scintilla's position API without any
/// unit conversion because every character we care about (`-`,
/// `*`, `+`, ` `, `[`, `]`, `x`, `X`) is a single ASCII byte.
public func markdownTaskToggle(line: String) -> MarkdownTaskToggleAction {
    guard !line.isEmpty else { return .none }

    // Walk leading whitespace to find the bullet.
    var cursor = line.utf8.startIndex
    let utf8 = line.utf8
    while cursor < utf8.endIndex, utf8[cursor] == 0x20 || utf8[cursor] == 0x09 {
        cursor = utf8.index(after: cursor)
    }
    guard cursor < utf8.endIndex else { return .none }
    let b = utf8[cursor]
    guard b == 0x2D /* - */ || b == 0x2A /* * */ || b == 0x2B /* + */ else {
        return .none
    }
    // The byte immediately after the bullet has to be a space for
    // it to count as a list item.
    let afterBullet = utf8.index(after: cursor)
    guard afterBullet < utf8.endIndex, utf8[afterBullet] == 0x20 else {
        return .none
    }
    let contentStart = utf8.index(after: afterBullet)

    // Offset of `contentStart` from the line's start, in bytes.
    // This is where either the existing `[` lives (if the line is
    // already a task list item) or where we'd insert `[ ] ` to
    // promote the bullet.
    let contentOffset = utf8.distance(from: utf8.startIndex, to: contentStart)

    // Two shapes from here:
    //
    //   (a) Content starts with `[` — *only* valid when the full
    //       `[_] ` triad with inner ∈ {space, x, X} follows. Any
    //       other use of `[` (link reference `[label](url)`,
    //       non-standard `[?]`, missing trailing space `[x]foo`)
    //       must be a no-op: we refuse to either flip a non-
    //       checkbox byte or bulldoze a legit bracket with a
    //       phantom `[ ] `.
    //
    //   (b) Content doesn't start with `[` — safe to promote to a
    //       task list item by inserting `[ ] ` at the content
    //       boundary.
    if contentStart < utf8.endIndex, utf8[contentStart] == 0x5B /* [ */ {
        if utf8.distance(from: contentStart, to: utf8.endIndex) >= 4 {
            let i0 = contentStart
            let i1 = utf8.index(after: i0)
            let i2 = utf8.index(after: i1)
            let i3 = utf8.index(after: i2)
            if utf8[i2] == 0x5D /* ] */, utf8[i3] == 0x20 /* space */ {
                let inner = utf8[i1]
                if inner == 0x20 {
                    let flipOffset = utf8.distance(from: utf8.startIndex, to: i1)
                    return .flip(byteOffset: flipOffset, newCharacter: "x")
                } else if inner == 0x78 /* x */ || inner == 0x58 /* X */ {
                    let flipOffset = utf8.distance(from: utf8.startIndex, to: i1)
                    return .flip(byteOffset: flipOffset, newCharacter: " ")
                }
            }
        }
        // `[` present but not a valid task-list triad — leave the
        // line alone so link references / pathological brackets
        // survive untouched.
        return .none
    }

    // Plain bullet — promote to `- [ ] ` by inserting `[ ] ` at
    // the content start. The bullet + its trailing space already
    // exist; the caller injects exactly four bytes.
    return .promote(byteOffset: contentOffset)
}
