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

    // MARK: - Phase 53b · task-checkbox toggle

    /// Phase 53b — caret-driven entry point. Fired by the ⇧⌘K
    /// menu / shortcut. Reads the line the caret is on and
    /// dispatches to the shared apply path.
    func toggleMarkdownTaskCheckbox(in view: ScintillaView) {
        guard doc.isMarkdown else { return }
        let pos = Int(view.message(SCI.GETCURRENTPOS))
        let line = Int(view.message(SCI.LINEFROMPOSITION,
                                    wParam: UInt(bitPattern: pos)))
        applyTaskToggle(atLine: line, in: view)
    }

    /// Phase 53b — preview-driven entry point. Fired when the JS
    /// click handler in MarkdownPreviewPane posts a line number
    /// (1-based, matching MarkdownConverter's `data-source-line`
    /// stamps). Translates to Scintilla's 0-based index and
    /// dispatches.
    ///
    /// A stale `line1Based` (preview hasn't caught up with a doc
    /// edit) would read whatever content lives at the translated
    /// index and either flip a nearby task or no-op — never
    /// corrupt unrelated content, because the pure parser refuses
    /// every shape that isn't a list item.
    func toggleMarkdownTaskCheckbox(atLine line1Based: Int,
                                    in view: ScintillaView) {
        guard doc.isMarkdown else { return }
        guard line1Based >= 1 else { return }
        let line0 = line1Based - 1
        let total = Int(view.message(SCI.GETLINECOUNT))
        guard line0 < total else { return }
        applyTaskToggle(atLine: line0, in: view)
    }

    /// Shared body: read the line, run the pure parser, apply the
    /// resulting edit. Wrapped on the caller side in
    /// BEGIN/ENDUNDOACTION so the toggle is one ⌘Z step.
    private func applyTaskToggle(atLine line: Int, in view: ScintillaView) {
        guard let lineText = readLineText(line, in: view) else { return }
        let content = stripTrailingNewline(lineText)

        let action = markdownTaskToggle(line: content)
        switch action {
        case .none:
            return
        case .flip(let offset, let newCharacter):
            flipByte(line: line,
                     byteOffset: offset,
                     newCharacter: newCharacter,
                     in: view)
        case .promote(let offset):
            promoteToTask(line: line, byteOffset: offset, in: view)
        }
    }

    /// Replace a single byte on `line` at `byteOffset` with the
    /// ASCII representation of `newCharacter`. Used by the
    /// unchecked ↔ checked flip: the parser has already proven
    /// the target byte is an ASCII `' '` / `'x'` / `'X'`, so the
    /// single-byte UTF-8 assumption holds.
    private func flipByte(line: Int,
                          byteOffset: Int,
                          newCharacter: Character,
                          in view: ScintillaView) {
        let lineStart = Int(view.message(SCI.POSITIONFROMLINE,
                                         wParam: UInt(bitPattern: line)))
        let targetPos = lineStart + byteOffset
        // Replacement is always a single ASCII byte.
        let replacement = String(newCharacter)
        let bytes = Array(replacement.utf8) + [0]
        view.message(SCI.BEGINUNDOACTION)
        // Select the single byte, then REPLACESEL: cheaper than a
        // delete+insert dance and keeps the caret where the user
        // expects (right after the flipped char).
        view.message(SCI.SETSEL,
                     wParam: UInt(bitPattern: targetPos),
                     lParam: targetPos + 1)
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            view.message(SCI.REPLACESEL,
                         wParam: 0,
                         lParam: Int(bitPattern: base))
        }
        view.message(SCI.ENDUNDOACTION)
    }

    /// Insert `"[ ] "` at `byteOffset` on `line`. Used by the
    /// plain-bullet → task-list promotion path.
    private func promoteToTask(line: Int,
                               byteOffset: Int,
                               in view: ScintillaView) {
        let lineStart = Int(view.message(SCI.POSITIONFROMLINE,
                                         wParam: UInt(bitPattern: line)))
        let insertPos = lineStart + byteOffset
        let bytes = Array("[ ] ".utf8) + [0]
        view.message(SCI.BEGINUNDOACTION)
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            view.message(SCI.INSERTTEXT,
                         wParam: UInt(bitPattern: insertPos),
                         lParam: Int(bitPattern: base))
        }
        view.message(SCI.ENDUNDOACTION)
    }

    // MARK: - SCI_REPLACESEL helpers

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
