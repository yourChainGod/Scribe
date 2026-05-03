//
//  Coordinator+BraceMatch.swift
//  Phase 62 — bracket highlight + auto-close glue for the main
//  editor's Coordinator. Two concerns share this file because the
//  live on a single notification channel — SCN_UPDATEUI for the
//  highlight, SCN_CHARADDED for the auto-close — and they share
//  the same predicate "is this character a bracket?".
//
//  Highlight path
//    On every caret update, peek at the character at the caret
//    (and the char behind it). If either is one of () [] {}, call
//    SCI_BRACEMATCH; a valid partner calls SCI_BRACEHIGHLIGHT on
//    both positions (Scintilla paints them with STYLE_BRACELIGHT).
//    A missing partner calls SCI_BRACEBADLIGHT (STYLE_BRACEBAD)
//    so the unmatched opener stands out in red. Clearing the
//    highlight is a single `-1, -1` call at the top of the path
//    — Scintilla's own contract for "turn it off".
//
//  Auto-close path
//    When SCN_CHARADDED fires with one of `(`, `[`, `{`, we insert
//    the matching closer at the caret (without advancing) inside
//    an undo group, so a single ⌘Z reverts the pair atomically.
//    Skipped for markdown documents, where `(link)` etc. would
//    balloon into `(())` — the prose friction outweighs the
//    benefit for that file type.
//
//  Goto matching bracket
//    ⌘E (wired in AppCommands.swift) routes through
//    `jumpToMatchingBracket(in:)` here. We reuse SCI_BRACEMATCH;
//    `jumpToBrace` also restores the highlight so the user sees
//    the destination land with the same visual treatment.
//

import Foundation
import Scintilla

extension ScintillaCodeEditor.Coordinator {

    // MARK: - Brackets we participate in

    /// Opening brackets that trigger auto-close. Closing halves
    /// are never inserted on their own; their pairing emerges
    /// from the open half inserting them.
    private static let openBrackets: Set<Character> = ["(", "[", "{"]

    /// Every bracket character we highlight (open + close). Quotes
    /// are intentionally absent — single / double quotes legitimately
    /// appear as prose apostrophes or string delimiters depending
    /// on context, and SCI_BRACEMATCH has no "match-only-paired"
    /// mode for them.
    private static let bracketChars: Set<UInt8> =
        Set("()[]{}".utf8)

    // MARK: - Highlight

    /// Called from `SCN_UPDATEUI`. Cheap on caret-only ticks —
    /// the GETCHARAT queries are O(1) in Scintilla and we short-
    /// circuit before dispatching BRACEMATCH unless the caret is
    /// actually adjacent to one of our bracket chars.
    func applyBraceMatchHighlight(in view: ScintillaView) {
        let pos = Int(view.message(SCI.GETCURRENTPOS))

        // Gather the two candidate positions: the char at the
        // caret, and the char immediately before it. Scintilla's
        // VS-style convention is that either counts — matching a
        // `)` the caret just advanced past is as useful as
        // matching a `(` it's about to type into.
        let posBefore = Int(view.message(SCI.POSITIONBEFORE,
                                         wParam: UInt(bitPattern: pos)))
        let bracePos = firstBracketPosition(near: pos,
                                            positionBefore: posBefore,
                                            in: view)

        guard let bp = bracePos else {
            // No bracket at the caret → clear any previous
            // highlight. `-1, -1` is Scintilla's documented
            // "turn off" contract.
            view.message(SCI.BRACEHIGHLIGHT,
                         wParam: UInt(bitPattern: -1),
                         lParam: -1)
            return
        }

        let partner = Int(view.message(SCI.BRACEMATCH,
                                       wParam: UInt(bitPattern: bp),
                                       lParam: 0))
        if partner >= 0 {
            view.message(SCI.BRACEHIGHLIGHT,
                         wParam: UInt(bitPattern: bp),
                         lParam: partner)
        } else {
            // Unmatched bracket at bp — paint it "bad" so the
            // user notices the dangler. Clear any stale good
            // highlight first (Scintilla won't do it for us).
            view.message(SCI.BRACEHIGHLIGHT,
                         wParam: UInt(bitPattern: -1),
                         lParam: -1)
            view.message(SCI.BRACEBADLIGHT,
                         wParam: UInt(bitPattern: bp),
                         lParam: 0)
        }
    }

    /// Return the position of the bracket char at / just before
    /// `pos`, or nil when neither adjacent slot carries one.
    private func firstBracketPosition(near pos: Int,
                                      positionBefore: Int,
                                      in view: ScintillaView) -> Int? {
        if isBracket(byteAt: pos, in: view) {
            return pos
        }
        if positionBefore >= 0,
           positionBefore != pos,
           isBracket(byteAt: positionBefore, in: view) {
            return positionBefore
        }
        return nil
    }

    private func isBracket(byteAt pos: Int, in view: ScintillaView) -> Bool {
        let raw = view.message(SCI.GETCHARAT,
                               wParam: UInt(bitPattern: pos))
        // GETCHARAT returns the raw byte. Bracket chars are all
        // ASCII (< 0x80), so a Unicode multi-byte sequence's
        // continuation byte can't false-match: the leading byte
        // of e.g. `（` (U+FF08 fullwidth left paren) is 0xEF, not
        // 0x28.
        return Self.bracketChars.contains(UInt8(truncatingIfNeeded: raw))
    }

    // MARK: - Auto-close

    /// Called from `SCN_CHARADDED` in the notification dispatcher
    /// when the typed character is `(`, `[`, or `{`. Inserts the
    /// closer at the caret and leaves the caret between the pair.
    ///
    /// The insert rides inside BEGINUNDOACTION / ENDUNDOACTION so
    /// one ⌘Z reverts the synthetic closer alongside the user's
    /// typed opener rather than leaving a dangling `)` behind.
    func autoCloseBracket(opener: Character, in view: ScintillaView) {
        // Policy gate: markdown documents skip auto-close because
        // `(link)` / `[ref]` balloon into `(())` / `[[]]`. Prose
        // wants the typing to stay WYSIWYG.
        guard !doc.isMarkdown else { return }
        guard Self.openBrackets.contains(opener) else { return }
        let closer: Character
        switch opener {
        case "(": closer = ")"
        case "[": closer = "]"
        case "{": closer = "}"
        default:  return
        }

        let caret = Int(view.message(SCI.GETCURRENTPOS))
        view.message(SCI.BEGINUNDOACTION)
        defer { view.message(SCI.ENDUNDOACTION) }
        // INSERTTEXT at `caret` places the closer *after* the
        // caret position WITHOUT advancing the caret — which is
        // exactly the "caret stays between the pair" UX we want.
        let bytes = Array(String(closer).utf8) + [0]   // C string for INSERTTEXT
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            view.message(SCI.INSERTTEXT,
                         wParam: UInt(bitPattern: caret),
                         lParam: Int(bitPattern: base))
        }
    }

    // MARK: - Goto matching bracket (⌘E)

    /// Command invoked by the `findState.commands` sink when the
    /// user triggers Edit ▸ Go to Matching Bracket. Finds the
    /// partner of the bracket adjacent to the caret and jumps
    /// there. No-ops when the caret isn't next to a bracket or
    /// when the bracket has no partner within Scintilla's styling
    /// budget.
    func jumpToMatchingBracket(in view: ScintillaView) {
        let pos = Int(view.message(SCI.GETCURRENTPOS))
        let posBefore = Int(view.message(SCI.POSITIONBEFORE,
                                         wParam: UInt(bitPattern: pos)))
        guard let bp = firstBracketPosition(near: pos,
                                            positionBefore: posBefore,
                                            in: view) else { return }
        let partner = Int(view.message(SCI.BRACEMATCH,
                                       wParam: UInt(bitPattern: bp),
                                       lParam: 0))
        guard partner >= 0 else { return }
        // SETSEL with equal wParam / lParam drops a zero-width
        // caret at `partner`. SCROLLCARET makes sure the target
        // line lands inside the visible viewport.
        view.message(SCI.SETSEL,
                     wParam: UInt(bitPattern: partner),
                     lParam: partner)
        view.message(SCI.SCROLLCARET)
    }
}
