//
//  Coordinator+MarkdownList.swift
//  Phase 53a — markdown list / quote continuation glue between
//  ScintillaCodeEditor.Coordinator and the pure parser in
//  `MarkdownListContinuation.swift`.
//
//  The notification dispatcher (in ScintillaCodeEditor.swift) calls
//  `applyMarkdownListContinuation(in:)` whenever the user types a
//  newline inside a markdown document. The work splits into three
//  Scintilla calls:
//
//    1. Read the previous line via SCI_LINELENGTH + SCI_GETLINE
//       (cheap — one short line, no full-document round-trip).
//    2. Run the pure parser to decide what to do.
//    3. Apply the action: SCI_REPLACESEL (insert prefix at caret)
//       or SCI_DELETERANGE (wipe dangling prefix on previous line).
//
//  All three Scintilla edits ride inside SCI_BEGINUNDOACTION /
//  ENDUNDOACTION so a subsequent ⌘Z reverts the *whole* synthetic
//  expansion in one step rather than leaving the user with a
//  half-undone "- " prefix dangling at the caret.
//

import Foundation
import Scintilla

extension ScintillaCodeEditor.Coordinator {
    /// Phase 53a — entry point called from the SCN_CHARADDED branch
    /// of the main notification switch when `ch == \n` and the
    /// document is markdown.
    ///
    /// Reads the line the user just left, runs the pure
    /// `markdownListContinuation` parser, and applies whatever
    /// action it returns. A `.none` result is the common case
    /// (regular paragraph text) and short-circuits before any
    /// edit happens — the only cost on that path is one
    /// SCI_LINELENGTH call and a buffer alloc proportional to the
    /// last line's length.
    func applyMarkdownListContinuation(in view: ScintillaView) {
        let pos = Int(view.message(SCI.GETCURRENTPOS))
        let curLine = Int(view.message(SCI.LINEFROMPOSITION,
                                       wParam: UInt(bitPattern: pos)))
        // Newline can't have arrived on line 0 — there has to be a
        // previous line for the user to have ended.
        guard curLine > 0 else { return }
        let prevLine = curLine - 1

        guard let prevText = readLineText(prevLine, in: view) else { return }

        // Strip any trailing CR / LF that SCI_GETLINE includes for
        // mid-document lines. The parser expects line content
        // *without* the terminator.
        let prevContent = stripTrailingNewline(prevText)

        let action = markdownListContinuation(previousLine: prevContent)
        switch action {
        case .none:
            return
        case .insert(let prefix):
            insertAtCaret(prefix, in: view)
        case .clearPrefix(let count):
            clearLeadingBytes(count, on: prevLine, in: view)
        }
    }

    // MARK: - Scintilla helpers

    /// Read the raw bytes of `line` via SCI_GETLINE. Returns the
    /// decoded UTF-8 string, or `nil` if Scintilla reports a zero-
    /// length line and we have nothing to parse. The buffer is
    /// sized exactly via SCI_LINELENGTH so we never under-allocate
    /// for a wide CJK / emoji line.
    private func readLineText(_ line: Int, in view: ScintillaView) -> String? {
        let lineLen = Int(view.message(SCI.LINELENGTH,
                                       wParam: UInt(bitPattern: line)))
        guard lineLen > 0 else { return "" }
        // +1 leaves room for the null terminator SCI_GETLINE writes.
        var buffer = [UInt8](repeating: 0, count: lineLen + 1)
        let bytesCopied = buffer.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return Int(view.message(SCI.GETLINE,
                                    wParam: UInt(bitPattern: line),
                                    lParam: Int(bitPattern: base)))
        }
        guard bytesCopied > 0 else { return "" }
        // Drop the trailing zero terminator if present; SCI_GETLINE
        // returns the byte count *not* including the null but
        // sometimes the kernel clamps so we defensively trim by
        // taking only the reported length.
        let actual = min(bytesCopied, lineLen)
        return String(decoding: buffer[..<actual], as: UTF8.self)
    }

    /// CommonMark normalises CRLF and CR to LF, but Scintilla
    /// preserves whatever the source file uses; trim every
    /// terminator we know about so the parser sees pure content.
    private func stripTrailingNewline(_ s: String) -> String {
        var out = s
        while let last = out.last, last == "\n" || last == "\r" {
            out.removeLast()
        }
        return out
    }

    /// SCI_REPLACESEL writes at the current caret with no
    /// selection. Mirrors the pattern used by
    /// `Coordinator+TextTransform.swift`. Wrapped in a single undo
    /// action so ⌘Z reverts the inserted prefix as one unit, not
    /// character-by-character.
    private func insertAtCaret(_ text: String, in view: ScintillaView) {
        let bytes = Array(text.utf8) + [0]
        view.message(SCI.BEGINUNDOACTION)
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            view.message(SCI.REPLACESEL,
                         wParam: 0,
                         lParam: Int(bitPattern: base))
        }
        view.message(SCI.ENDUNDOACTION)
    }

    /// Wipe the first `count` UTF-8 bytes of `line`. SCI_DELETERANGE
    /// is byte-oriented; the parser returns UTF-16 unit counts that
    /// match UTF-8 byte counts for the ASCII prefixes we recognise
    /// (`-`, `*`, `+`, `0–9`, `.`, `)`, `>`, ` `). Wrapped in a
    /// single undo action.
    private func clearLeadingBytes(_ count: Int,
                                   on line: Int,
                                   in view: ScintillaView) {
        let lineStart = Int(view.message(SCI.POSITIONFROMLINE,
                                         wParam: UInt(bitPattern: line)))
        guard count > 0 else { return }
        view.message(SCI.BEGINUNDOACTION)
        view.message(SCI.DELETERANGE,
                     wParam: UInt(bitPattern: lineStart),
                     lParam: count)
        view.message(SCI.ENDUNDOACTION)
    }
}
