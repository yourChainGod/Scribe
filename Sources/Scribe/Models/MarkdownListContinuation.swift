//
//  MarkdownListContinuation.swift
//  Phase 53a — pure parsing helper that decides what to do when the
//  user presses Enter inside a markdown document.
//
//  The logic is intentionally separated from any Scintilla glue so
//  XCTest can pin every list / quote / checkbox / nested case
//  without standing up a live editor view. ScintillaCodeEditor's
//  Coordinator calls this on every `SCN_CHARADDED` notification
//  whose `ch == \n` and applies the result via Scintilla messages.
//
//  Behaviour mirrors VS Code / Typora / Obsidian:
//
//    1. `- foo<Enter>` ⇒ next line gets `- ` inserted at caret.
//    2. `- <Enter>`     ⇒ the trailing `- ` on the *previous* line
//                        is wiped (user wants to exit the list).
//    3. `1. foo<Enter>` ⇒ next line gets `2. ` (number incremented).
//    4. `> foo<Enter>`  ⇒ next line gets `> ` (quote continuation).
//    5. `- [ ] foo<Enter>` ⇒ next line gets `- [ ] ` (task continued
//                            unchecked, never carried as `[x]` —
//                            a fresh task starts fresh).
//    6. Indentation (`  - foo` → `  - `) and quote nesting
//       (`> > foo` → `> > `) are preserved verbatim.
//
//  Anything that doesn't match a recognised pattern returns `.none`
//  so Scintilla's default newline behaviour stays in charge.
//

import Foundation

/// Outcome of running `markdownListContinuation` on the line the
/// user just ended with Enter.
///
///   - `none`               — not a list / quote line; let the
///                            editor's default newline behaviour
///                            stand.
///   - `insert(prefix)`     — caret is on the freshly-created
///                            empty line; the editor should insert
///                            `prefix` at the caret to continue
///                            the list / quote.
///   - `clearPrefix(count)` — the user pressed Enter on an empty
///                            list / quote item; the editor should
///                            delete the first `count` UTF-16
///                            code units of the *previous* line so
///                            the dangling bullet / quote vanishes.
public enum MarkdownListContinuation: Equatable {
    case none
    case insert(String)
    case clearPrefix(Int)
}

/// Parse the `previousLine` (the line the user just ended) and
/// return the action the editor should take on the new caret line.
///
/// The function operates on a single line of text without the
/// terminating newline. UTF-16 code units are the unit of
/// measurement for `clearPrefix` because Scintilla's position API
/// is byte-oriented but the prefixes we recognise are pure ASCII —
/// for ASCII text the UTF-16 length matches the UTF-8 byte length,
/// which matches the Scintilla character count. Any non-ASCII
/// content inside a bullet would only ever appear in the bullet's
/// *content*, never the prefix.
public func markdownListContinuation(previousLine: String) -> MarkdownListContinuation {
    // Quick reject: empty line can't be a list item; let Scintilla
    // handle the newline.
    guard !previousLine.isEmpty else { return .none }

    // Walk leading whitespace (spaces or tabs only — CommonMark
    // doesn't allow other Unicode whitespace as list indent).
    var idx = previousLine.startIndex
    while idx < previousLine.endIndex,
          previousLine[idx] == " " || previousLine[idx] == "\t" {
        idx = previousLine.index(after: idx)
    }
    let indent = String(previousLine[previousLine.startIndex..<idx])
    let afterIndent = previousLine[idx...]

    // Quote line: any number of "> " segments forms the quote
    // prefix. CommonMark allows "> >" without a trailing space, but
    // Typora-style rendering picks "> " consistently — we mirror
    // the trailing-space form so the continuation feels uniform.
    if afterIndent.hasPrefix(">") {
        if let q = parseQuotePrefix(afterIndent) {
            // Content after the quote markers — empty content with
            // *only* quote markers is still a quote (e.g. `> ` is a
            // valid empty quote line that the user might want to
            // exit). Apply the same exit rule as lists.
            let content = afterIndent.dropFirst(q.markerLength)
            let trimmedContent = content.drop(while: { $0 == " " || $0 == "\t" })
            if trimmedContent.isEmpty {
                // Wipe the indent + quote markers from the previous line.
                let total = indent.utf16.count + q.markerLength
                return .clearPrefix(total)
            }
            return .insert(indent + q.normalised)
        }
    }

    // Ordered list: `<digits>. ` or `<digits>) ` followed by content.
    // We support both `.` and `)` as terminators because CommonMark
    // does, but only `.` round-trips cleanly through most renderers
    // and is what we emit on continuation.
    if let ord = parseOrderedListMarker(afterIndent) {
        let content = afterIndent[ord.contentStart...]
        let trimmedContent = content.drop(while: { $0 == " " || $0 == "\t" })
        if trimmedContent.isEmpty {
            let total = indent.utf16.count + ord.markerLength
            return .clearPrefix(total)
        }
        let nextNumber = ord.number + 1
        return .insert("\(indent)\(nextNumber)\(ord.terminator) ")
    }

    // Unordered list (possibly task list): `[-*+] ` then optional
    // `[ ]` / `[x]` / `[X]` checkbox, then content.
    if let bullet = parseUnorderedListMarker(afterIndent) {
        // After the bullet we may have a task-list checkbox.
        let afterBullet = afterIndent[bullet.contentStart...]
        let (checkbox, postCheckbox) = parseTaskCheckbox(afterBullet)
        let trimmedContent = postCheckbox.drop(while: { $0 == " " || $0 == "\t" })
        if trimmedContent.isEmpty {
            let total = indent.utf16.count + bullet.markerLength + (checkbox?.markerLength ?? 0)
            return .clearPrefix(total)
        }
        // Carry the bullet + (if present) a fresh empty checkbox —
        // a continued task always starts unchecked, regardless of
        // whether the previous task was `[ ]` or `[x]`. This
        // matches VS Code / Obsidian.
        if checkbox != nil {
            return .insert("\(indent)\(bullet.bullet) [ ] ")
        }
        return .insert("\(indent)\(bullet.bullet) ")
    }

    return .none
}

// MARK: - Internal parsers

/// Result of recognising a quote prefix on a line. `markerLength`
/// is the number of UTF-16 units the parser consumed; `normalised`
/// is the canonical `> > ` form we emit on continuation.
private struct QuotePrefixMatch {
    let markerLength: Int
    let normalised: String
}

private func parseQuotePrefix(_ s: Substring) -> QuotePrefixMatch? {
    var idx = s.startIndex
    var levels = 0
    var consumed = 0
    while idx < s.endIndex, s[idx] == ">" {
        idx = s.index(after: idx)
        consumed += 1
        levels += 1
        // Optional single space after `>` (CommonMark canonical form).
        if idx < s.endIndex, s[idx] == " " {
            idx = s.index(after: idx)
            consumed += 1
        }
    }
    guard levels > 0 else { return nil }
    let normalised = String(repeating: "> ", count: levels)
    return QuotePrefixMatch(markerLength: consumed, normalised: normalised)
}

private struct UnorderedListMarkerMatch {
    let bullet: Character
    let markerLength: Int     // bullet + the single mandatory space
    let contentStart: Substring.Index
}

private func parseUnorderedListMarker(_ s: Substring) -> UnorderedListMarkerMatch? {
    guard let first = s.first,
          first == "-" || first == "*" || first == "+" else { return nil }
    let afterBullet = s.index(after: s.startIndex)
    // CommonMark requires whitespace between bullet and content. We
    // accept exactly one space (the canonical form); without it the
    // line isn't a list item (`-foo` is a paragraph starting with a
    // hyphen).
    guard afterBullet < s.endIndex, s[afterBullet] == " " else { return nil }
    let contentStart = s.index(after: afterBullet)
    return UnorderedListMarkerMatch(bullet: first,
                                    markerLength: 2,
                                    contentStart: contentStart)
}

private struct OrderedListMarkerMatch {
    let number: Int
    let terminator: Character  // `.` or `)`
    let markerLength: Int      // digits + terminator + space
    let contentStart: Substring.Index
}

private func parseOrderedListMarker(_ s: Substring) -> OrderedListMarkerMatch? {
    var idx = s.startIndex
    var digits = ""
    while idx < s.endIndex, let d = s[idx].asciiValue, d >= 0x30, d <= 0x39 {
        digits.append(s[idx])
        idx = s.index(after: idx)
    }
    guard !digits.isEmpty, let n = Int(digits) else { return nil }
    // Cap continuation numbers at a sane width — pathological input
    // like `9999999999999999999999. foo` would otherwise overflow
    // Int. Falling through to .none keeps Scintilla's default
    // behaviour rather than crashing.
    guard n < 1_000_000 else { return nil }
    guard idx < s.endIndex else { return nil }
    let term = s[idx]
    guard term == "." || term == ")" else { return nil }
    idx = s.index(after: idx)
    guard idx < s.endIndex, s[idx] == " " else { return nil }
    let contentStart = s.index(after: idx)
    let markerLength = digits.utf16.count + 1 + 1 // digits + terminator + space
    return OrderedListMarkerMatch(number: n,
                                  terminator: term,
                                  markerLength: markerLength,
                                  contentStart: contentStart)
}

private struct TaskCheckboxMatch {
    let markerLength: Int  // `[ ] ` is always 4 UTF-16 units
}

/// Recognise an optional task-list checkbox (`[ ] ` / `[x] ` /
/// `[X] `) immediately after the bullet's mandatory space. Returns
/// `(nil, original)` when no checkbox is present.
private func parseTaskCheckbox(_ s: Substring) -> (TaskCheckboxMatch?, Substring) {
    guard s.count >= 4 else { return (nil, s) }
    let i0 = s.startIndex
    let i1 = s.index(after: i0)
    let i2 = s.index(after: i1)
    let i3 = s.index(after: i2)
    guard s[i0] == "[",
          s[i2] == "]",
          s[i3] == " " else { return (nil, s) }
    let inner = s[i1]
    guard inner == " " || inner == "x" || inner == "X" else { return (nil, s) }
    let after = s.index(after: i3)
    return (TaskCheckboxMatch(markerLength: 4), s[after...])
}
