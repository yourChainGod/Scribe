//
//  MergeConflictResolver.swift
//  Phase 68 — pure functions that turn a user's Accept Current /
//  Incoming / Both choice into an (NSRange, replacement: String)
//  pair the editor can hand to Scintilla's replaceTarget / an
//  NSTextStorage `replaceCharacters`. Kept isolated from the
//  Coordinator layer so the resolution algebra is unit-testable
//  without spinning up a live view.
//

import Foundation

/// Outcome of resolving a single conflict.
struct MergeConflictResolution: Equatable {
    /// The range the editor should overwrite — always equal to
    /// `MergeConflict.range` so the three `<`/`=`/`>` marker lines
    /// come out atomically with the body the user picked.
    let range: NSRange
    /// Text that replaces the conflict block. May be empty when
    /// the chosen side was empty (e.g. Accept Incoming on a
    /// `<<<<<<<\n=======\nsomething\n>>>>>>>`-style "deletion"
    /// conflict where ours is empty).
    let replacement: String
}

/// Which of the three buttons the user clicked.
enum MergeConflictChoice {
    case current    // "ours" — the HEAD side
    case incoming   // "theirs" — the merged-in branch
    case both       // keep both bodies, ours first
}

enum MergeConflictResolver {

    /// Compose the replacement payload for `conflict` given the
    /// user's `choice` and the original document text. Splitting
    /// this out (rather than returning the full resolved
    /// document) lets the editor apply the patch through
    /// Scintilla's target API, which preserves undo history,
    /// caret position, and viewport — a whole-document replace
    /// would reset all three.
    static func resolve(_ conflict: MergeConflict,
                        choice: MergeConflictChoice,
                        in originalText: String) -> MergeConflictResolution {
        let body: String
        switch choice {
        case .current:
            body = conflict.currentText
        case .incoming:
            body = conflict.incomingText
        case .both:
            body = combinedBody(current: conflict.currentText,
                                incoming: conflict.incomingText)
        }
        let replacement = paddedReplacement(
            body: body,
            conflictRange: conflict.range,
            originalText: originalText as NSString)
        return MergeConflictResolution(range: conflict.range,
                                       replacement: replacement)
    }

    // MARK: - Private

    /// Accept-Both concatenation with a single newline between
    /// the two sections when both are non-empty. An empty side
    /// collapses into the non-empty one so the user doesn't get
    /// a stray blank paragraph for a truly one-sided conflict.
    private static func combinedBody(current: String,
                                      incoming: String) -> String {
        if current.isEmpty { return incoming }
        if incoming.isEmpty { return current }
        return current + "\n" + incoming
    }

    /// Preserve the "range ends with a newline or not" invariant
    /// of the original slice so upstream Scintilla / NSTextStorage
    /// replacements don't accidentally merge adjacent lines (when
    /// we drop a trailing newline) or introduce a phantom blank
    /// line (when we add one). Two rules:
    ///
    ///   - If the conflict range ends with `\n`, the replacement
    ///     must also end with `\n`. Empty body ⇒ empty replacement
    ///     (drops the whole block, leaving the preceding and
    ///     following lines adjacent — the expected behaviour when
    ///     both sides are empty).
    ///   - If the conflict range is at EOF without a trailing
    ///     newline, the replacement must also not end with `\n`
    ///     so the file's no-trailing-newline status is preserved.
    private static func paddedReplacement(body: String,
                                          conflictRange: NSRange,
                                          originalText: NSString) -> String {
        guard conflictRange.length > 0 else { return body }
        let endsWithNewline: Bool = {
            let lastCharIdx = NSMaxRange(conflictRange) - 1
            guard lastCharIdx < originalText.length else { return false }
            let lastChar = originalText.character(at: lastCharIdx)
            return lastChar == UInt16(UnicodeScalar("\n").value)
        }()
        if body.isEmpty {
            // Dropping the whole conflict. Leaving the leading
            // newline of the block (if any) would produce a blank
            // line where none existed before, so we emit an empty
            // replacement and let the range deletion do its job.
            return ""
        }
        if endsWithNewline && !body.hasSuffix("\n") {
            return body + "\n"
        }
        if !endsWithNewline && body.hasSuffix("\n") {
            // This branch is unreachable under the current body
            // sources (they never gain a trailing newline), but
            // keeping it defensive makes the invariant obvious.
            return String(body.dropLast())
        }
        return body
    }
}
