//
//  DiffEditorPane.swift
//  Phase 5 — read-only Scintilla pane used inside the Compare view.
//  Renders one side (left or right) and paints the gutter + per-line
//  background based on the DiffOp covering that line.
//
//  Why a separate Representable instead of reusing ScintillaCodeEditor:
//  the diff pane has no Document, no two-way sync, no Lexilla lexer, and
//  needs marker / line-background machinery that the editing pane
//  deliberately avoids. Cleaner to keep them apart.
//

import AppKit
import Combine
import Scintilla
import SwiftUI

struct DiffEditorPane: NSViewRepresentable {
    enum Side { case left, right }

    let text: String
    let ops: [DiffOp]
    let side: Side
    /// Driven by the toolbar's "Next / Previous diff" buttons. The pane
    /// scrolls + selects this hunk's first line on every update.
    let activeHunkIndex: Int
    /// Owning session — coordinator forwards scroll notifications here
    /// so the other pane can be synced.
    weak var session: DiffSession?
    /// Closure called when the user clicks a line on this pane — the
    /// container uses it to keep the two panes in sync.
    let onLineClicked: (Int) -> Void
    /// Phase 15 — read the user-selected theme. The host (DiffView)
    /// passes the live EditorPreferences so the diff pane re-themes
    /// alongside the editor when the user switches palettes.
    @EnvironmentObject var prefs: EditorPreferences

    func makeCoordinator() -> Coordinator {
        Coordinator(side: side, session: session, onLineClicked: onLineClicked)
    }

    func makeNSView(context: Context) -> ScintillaView {
        let view = ScintillaView(frame: .zero)
        view.delegate = context.coordinator
        context.coordinator.attach(view: view)
        // Register on the session so the sibling pane can find us.
        switch side {
        case .left:  session?.leftView = view
        case .right: session?.rightView = view
        }
        configureMarkers(in: view)
        configureMargins(in: view)
        configureIndicators(in: view)
        configureTheme(in: view)
        // setString must happen BEFORE we lock the buffer read-only —
        // SCI_SETREADONLY rejects every internal SCI_INSERTTEXT,
        // leaving the pane blank.
        applyText(text, to: view)
        view.setEditable(false)
        applyOps(ops, to: view)
        applyWordDiff(in: view)
        return view
    }

    func updateNSView(_ view: ScintillaView, context: Context) {
        context.coordinator.onLineClicked = onLineClicked
        // Phase 15: re-apply theme on every update so a live theme
        // switch picks up immediately. Cheap — STYLECLEARALL touches
        // a dozen styles tops.
        configureMarkers(in: view)
        configureTheme(in: view)
        if view.string() != text {
            // Same caveat as makeNSView — toggle off → write → toggle back.
            view.setEditable(true)
            applyText(text, to: view)
            view.setEditable(false)
        }
        applyOps(ops, to: view)
        applyWordDiff(in: view)
        scrollToHunk(in: view)
    }

    // MARK: - Configuration

    private func configureMargins(in view: ScintillaView) {
        // Margin 0 — line numbers, like the editor.
        view.message(SCI_DIFF.SETMARGINTYPEN, wParam: 0, lParam: SC_DIFF.MARGIN_NUMBER)
        view.message(SCI_DIFF.SETMARGINWIDTHN, wParam: 0, lParam: 44)
        // Margin 1 — diff symbol gutter (▶ on changed lines).
        view.message(SCI_DIFF.SETMARGINTYPEN, wParam: 1, lParam: SC_DIFF.MARGIN_SYMBOL)
        view.message(SCI_DIFF.SETMARGINWIDTHN, wParam: 1, lParam: 14)
        view.message(SCI_DIFF.SETMARGINMASKN,  wParam: 1, lParam: SC_DIFF.MARK_MASK_DIFF)
    }

    /// Set up two indicators for word-level diff.
    /// 1 = removed-word background (red), 2 = added-word background (green).
    /// INDIC_STRAIGHTBOX with ~110/255 alpha mirrors GitHub's palette and
    /// keeps the underlying glyph legible.
    private func configureIndicators(in view: ScintillaView) {
        defineIndicator(view,
                        num: SC_DIFF.IND_REMOVED,
                        rgb: 0xE74C3C,
                        alpha: 110)
        defineIndicator(view,
                        num: SC_DIFF.IND_ADDED,
                        rgb: 0x27AE60,
                        alpha: 110)
    }

    private func defineIndicator(_ view: ScintillaView,
                                 num: Int,
                                 rgb: Int,
                                 alpha: Int) {
        view.message(SCI_DIFF.INDICSETSTYLE,
                     wParam: UInt(num),
                     lParam: SC_DIFF.INDIC_STRAIGHTBOX)
        view.message(SCI_DIFF.INDICSETFORE,
                     wParam: UInt(num),
                     lParam: bgrColor(rgb))
        view.message(SCI_DIFF.INDICSETALPHA,
                     wParam: UInt(num),
                     lParam: alpha)
        view.message(SCI_DIFF.INDICSETOUTLINEALPHA,
                     wParam: UInt(num),
                     lParam: 255)
    }

    private func configureMarkers(in view: ScintillaView) {
        let theme = prefs.themeID.resolve(appearance: NSApp.effectiveAppearance)
        // Marker number → glyph + colour. Empty side uses opaque dimmed
        // background so the placeholder lines are visible but muted.
        defineMarker(view, num: SC_DIFF.MARK_ADDED,    fore: 0x2ECC71, back: 0xD5F5E3)
        defineMarker(view, num: SC_DIFF.MARK_REMOVED,  fore: 0xE74C3C, back: 0xFADBD8)
        defineMarker(view, num: SC_DIFF.MARK_CHANGED,  fore: 0xF1C40F, back: 0xFCF3CF)
        defineMarker(view, num: SC_DIFF.MARK_PLACEHOLDER, fore: theme.marginForeground, back: 0xEAEAEA)
    }

    private func defineMarker(_ view: ScintillaView,
                              num: Int,
                              fore: Int,
                              back: Int) {
        // SC_MARK_FULLRECT (26) paints the entire margin cell — gives us
        // a coloured stripe even without a glyph, which is the look we want.
        view.message(SCI_DIFF.MARKERDEFINE, wParam: UInt(num), lParam: SC_DIFF.MARK_FULLRECT)
        view.message(SCI_DIFF.MARKERSETFORE, wParam: UInt(num), lParam: bgrColor(fore))
        view.message(SCI_DIFF.MARKERSETBACK, wParam: UInt(num), lParam: bgrColor(back))
    }

    private func configureTheme(in view: ScintillaView) {
        let theme = prefs.themeID.resolve(appearance: NSApp.effectiveAppearance)
        view.message(SCI_DIFF.STYLESETBACK, wParam: UInt(SC_DIFF.STYLE_DEFAULT), lParam: bgrColor(theme.background))
        view.message(SCI_DIFF.STYLESETFORE, wParam: UInt(SC_DIFF.STYLE_DEFAULT), lParam: bgrColor(theme.foreground))
        view.message(SCI_DIFF.STYLECLEARALL)
        view.message(SCI_DIFF.STYLESETBACK, wParam: UInt(SC_DIFF.STYLE_LINENUMBER), lParam: bgrColor(theme.marginBackground))
        view.message(SCI_DIFF.STYLESETFORE, wParam: UInt(SC_DIFF.STYLE_LINENUMBER), lParam: bgrColor(theme.marginForeground))
        view.setFontName("Menlo", size: 12, bold: false, italic: false)
    }

    // MARK: - State push

    private func applyText(_ text: String, to view: ScintillaView) {
        view.setString(text)
    }

    private func applyOps(_ ops: [DiffOp], to view: ScintillaView) {
        // Wipe every marker on every line and repaint — diffs are small
        // enough that the cost is negligible vs tracking incremental deltas.
        let lineCount = Int(view.message(SCI_DIFF.GETLINECOUNT))
        for line in 0..<lineCount {
            view.message(SCI_DIFF.MARKERDELETE,
                         wParam: UInt(line),
                         lParam: -1)   // -1 ⇒ all marker numbers
        }
        for op in ops {
            switch op.kind {
            case .equal:
                continue
            case .insert:
                if side == .right {
                    addMarker(view, lines: op.rightRange, marker: SC_DIFF.MARK_ADDED)
                }
            case .delete:
                if side == .left {
                    addMarker(view, lines: op.leftRange, marker: SC_DIFF.MARK_REMOVED)
                }
            case .replace:
                let range = side == .left ? op.leftRange : op.rightRange
                addMarker(view, lines: range, marker: SC_DIFF.MARK_CHANGED)
            }
        }
    }

    private func addMarker(_ view: ScintillaView,
                           lines: Range<Int>,
                           marker: Int) {
        for line in lines {
            view.message(SCI_DIFF.MARKERADD, wParam: UInt(line), lParam: marker)
        }
    }

    /// Walk every `.replace` op, run a word-level diff on the relevant
    /// block of text, and paint indicators 1/2 (red for removed, green
    /// for added) over the actual changed token byte ranges. UTF-16 ↔
    /// UTF-8 conversion is needed because Scintilla addresses positions
    /// in bytes, while our DiffEngine emits UTF-16 offsets.
    private func applyWordDiff(in view: ScintillaView) {
        let isLeft = side == .left
        let myIndicator = isLeft ? SC_DIFF.IND_REMOVED : SC_DIFF.IND_ADDED
        // SCI_SETREADONLY rejects INDICATORFILLRANGE / CLEARRANGE just
        // like it rejects text edits. Toggle the lock for the duration
        // of this paint pass.
        view.setEditable(true)
        defer { view.setEditable(false) }

        // Wipe any previous fills so updates don't accumulate.
        view.message(SCI_DIFF.SETINDICATORCURRENT,
                     wParam: UInt(myIndicator))
        let docLen = Int(view.message(SCI_DIFF.GETLENGTH))
        view.message(SCI_DIFF.INDICATORCLEARRANGE,
                     wParam: 0, lParam: docLen)

        // Word diff needs both sides' text. Read the sibling pane's text
        // off the session — bail if the session has gone away.
        guard let session, session.result != nil else { return }
        let myLines    = DiffEngine.splitLines(text)
        let otherText  = isLeft ? session.rightText : session.leftText
        let otherLines = DiffEngine.splitLines(otherText)

        for op in ops where op.kind == .replace {
            let myRange    = isLeft ? op.leftRange  : op.rightRange
            let otherRange = isLeft ? op.rightRange : op.leftRange
            let myBlock    = myLines[myRange].joined(separator: "\n")
            let otherBlock = otherLines[otherRange].joined(separator: "\n")
            // Always invoke wordDiff with the consistent (left, right)
            // ordering it expects — leftAddedRanges is the LHS-changed
            // set, regardless of which pane we're rendering.
            let wd = isLeft
                ? DiffEngine.wordDiff(left: myBlock, right: otherBlock)
                : DiffEngine.wordDiff(left: otherBlock, right: myBlock)
            let ranges16 = isLeft ? wd.leftAddedRanges : wd.rightAddedRanges
            let blockStart = Int(view.message(SCI_DIFF.POSITIONFROMLINE,
                                              wParam: UInt(myRange.lowerBound)))
            for r in ranges16 {
                let startByte = blockStart + utf8Offset(in: myBlock, utf16: r.lowerBound)
                let endByte   = blockStart + utf8Offset(in: myBlock, utf16: r.upperBound)
                guard endByte > startByte else { continue }
                view.message(SCI_DIFF.INDICATORFILLRANGE,
                             wParam: UInt(startByte),
                             lParam: endByte - startByte)
            }
        }
    }

    /// UTF-16 index in `s` ⇒ byte offset (UTF-8). NSString-based so it
    /// handles surrogate pairs correctly without the bridging cost of
    /// full-string UTF-8 conversion on every call.
    private func utf8Offset(in s: String, utf16: Int) -> Int {
        let ns = s as NSString
        let clamped = max(0, min(utf16, ns.length))
        if clamped == 0 { return 0 }
        return (ns.substring(to: clamped) as NSString)
            .lengthOfBytes(using: String.Encoding.utf8.rawValue)
    }

    private func scrollToHunk(in view: ScintillaView) {
        let nonEqual = ops.filter { $0.kind != .equal }
        guard !nonEqual.isEmpty else { return }
        let idx = max(0, min(activeHunkIndex, nonEqual.count - 1))
        let op = nonEqual[idx]
        let line = side == .left ? op.leftRange.lowerBound
                                 : op.rightRange.lowerBound
        view.message(SCI_DIFF.GOTOLINE, wParam: UInt(line))
        view.message(SCI_DIFF.SCROLLCARET)
    }

    // MARK: - Colour packing

    private func bgrColor(_ rgb: Int) -> Int {
        let r = (rgb >> 16) & 0xFF
        let g = (rgb >> 8)  & 0xFF
        let b =  rgb        & 0xFF
        return (b << 16) | (g << 8) | r
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, ScintillaNotificationProtocol {
        let side: Side
        weak var session: DiffSession?
        var onLineClicked: (Int) -> Void
        weak var view: ScintillaView?

        init(side: Side,
             session: DiffSession?,
             onLineClicked: @escaping (Int) -> Void) {
            self.side = side
            self.session = session
            self.onLineClicked = onLineClicked
        }

        func attach(view: ScintillaView) { self.view = view }

        nonisolated func notification(_ scn: UnsafeMutablePointer<SCNotification>?) {
            guard let scn else { return }
            let code = scn.pointee.nmhdr.code
            // updated bit-mask: see SC_UPDATE_* in Scintilla.h.
            // We can't read the bit field across the nonisolated boundary,
            // so capture the masked-int value here.
            let updated = scn.pointee.updated
            if code == SCN_DIFF.UPDATEUI {
                Task { @MainActor [weak self] in
                    guard let self, let view = self.view else { return }
                    // Always echo caret line for click-to-jump UX.
                    let pos = view.message(SCI_DIFF.GETCURRENTPOS)
                    let caretLine = view.message(SCI_DIFF.LINEFROMPOSITION,
                                                 wParam: UInt(pos))
                    self.onLineClicked(Int(caretLine))
                    // Vertical scroll bit set ⇒ sync sibling pane.
                    if updated & SC_UPDATE.V_SCROLL != 0 {
                        let firstVisible = view.message(SCI_DIFF.GETFIRSTVISIBLELINE)
                        self.session?.syncScroll(from: self.side,
                                                 firstVisibleLine: Int(firstVisible))
                    }
                }
            }
        }
    }
}

// MARK: - Locally-scoped Scintilla constants

private enum SCI_DIFF {
    static let GETLINECOUNT:      UInt32 = 2154
    static let GETLENGTH:         UInt32 = 2006
    static let GETCURRENTPOS:     UInt32 = 2008
    static let LINEFROMPOSITION:  UInt32 = 2166
    static let POSITIONFROMLINE:  UInt32 = 2167
    static let GETFIRSTVISIBLELINE: UInt32 = 2152
    static let SETMARGINTYPEN:    UInt32 = 2240
    static let SETMARGINWIDTHN:   UInt32 = 2242
    static let SETMARGINMASKN:    UInt32 = 2244
    static let MARKERDEFINE:      UInt32 = 2040
    static let MARKERSETFORE:     UInt32 = 2041
    static let MARKERSETBACK:     UInt32 = 2042
    static let MARKERADD:         UInt32 = 2043
    static let MARKERDELETE:      UInt32 = 2044
    static let STYLECLEARALL:     UInt32 = 2050
    static let STYLESETFORE:      UInt32 = 2051
    static let STYLESETBACK:      UInt32 = 2052
    static let GOTOLINE:          UInt32 = 2024
    static let SCROLLCARET:       UInt32 = 2169
    // Indicators (Phase 5b-2 word-level diff)
    static let INDICSETSTYLE:     UInt32 = 2080
    static let INDICSETFORE:      UInt32 = 2082
    static let INDICSETALPHA:     UInt32 = 2523
    static let INDICSETOUTLINEALPHA: UInt32 = 2558
    static let INDICSETUNDER:     UInt32 = 2510
    static let SETINDICATORCURRENT: UInt32 = 2500
    static let INDICATORFILLRANGE:  UInt32 = 2504
    static let INDICATORCLEARRANGE: UInt32 = 2505
}

/// Bit flags for SCNotification.updated.
private enum SC_UPDATE {
    static let CONTENT:  Int32 = 0x1
    static let SELECTION: Int32 = 0x2
    static let V_SCROLL: Int32 = 0x4
    static let H_SCROLL: Int32 = 0x8
}

private enum SC_DIFF {
    static let STYLE_DEFAULT:    Int = 32
    static let STYLE_LINENUMBER: Int = 33
    static let MARGIN_NUMBER:    Int = 1
    static let MARGIN_SYMBOL:    Int = 0
    static let MARK_FULLRECT:    Int = 26   // SC_MARK_FULLRECT
    /// Marker numbers — must be < 32 (Scintilla limit).
    static let MARK_ADDED:        Int = 1
    static let MARK_REMOVED:      Int = 2
    static let MARK_CHANGED:      Int = 3
    static let MARK_PLACEHOLDER:  Int = 4
    /// Bitmask covering every marker we use; passed to SETMARGINMASKN
    /// so margin 1 only displays our four markers.
    static let MARK_MASK_DIFF: Int = (1 << MARK_ADDED) | (1 << MARK_REMOVED) | (1 << MARK_CHANGED) | (1 << MARK_PLACEHOLDER)
    /// Indicator numbers (Phase 5b-2 word-level diff).
    /// Indicator 0 is reserved for find-match highlight in the editor;
    /// the diff panes don't share that, but staying clear of it keeps
    /// future shared infrastructure simple.
    static let IND_REMOVED: Int = 1
    static let IND_ADDED:   Int = 2
    /// Indicator styles.
    static let INDIC_FULLBOX:     Int = 16
    static let INDIC_ROUNDBOX:    Int = 7
    static let INDIC_STRAIGHTBOX: Int = 8
}

private enum SCN_DIFF {
    static let UPDATEUI: UInt32 = 2007
}
