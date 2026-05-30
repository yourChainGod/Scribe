//
//  Coordinator+Folding.swift
//  Phase 82 — code folding. Paints a fold-margin strip in margin 2 of
//  the editor and exposes fold / unfold / fold-all / unfold-all as
//  command sinks pumped by the same FindState.commands Combine bus.
//
//  Margin layout (extends the map documented in Coordinator+GitGutter)
//      0  line numbers   (44 px)  — applyLineNumberMargin
//      1  git gutter      (6 px)  — Coordinator+GitGutter
//      2  fold strip      (14 px) — this file, width tied to the lexer
//
//  Why margin 2 / markers 25–31
//    Scintilla reserves marker numbers 25–31 for the folding system
//    (SC_MARKNUM_FOLDER*). The git gutter deliberately stays in the
//    user range 21–23 (see Coordinator+GitGutter:28-32) so the two
//    strips never collide: disjoint margins, disjoint marker bits,
//    disjoint masks (fold mask 0xFE000000 vs gutter 0x00E00000).
//
//  Why no manual margin-click handler
//    SCI_SETAUTOMATICFOLD(SHOW|CLICK|CHANGE) makes Scintilla handle
//    margin clicks, auto-revealing hidden lines when the caret moves
//    into them, and re-folding on edits — all internally. That keeps
//    the `notification(_:)` SCN dispatcher untouched (no MARGINCLICK
//    arm to maintain). If click-to-fold ever misbehaves, the fallback
//    is an SCN_MARGINCLICK arm calling SCI_TOGGLEFOLD(line).
//
//  Width is lexer-gated
//    Plain-text buffers (empty Lexilla name) emit no fold levels, so a
//    fold margin would be a dead empty column. `foldMarginWidth` maps
//    the empty lexer to 0 and any real lexer to 14 px — the margin
//    appears only where it can do something. There is no user pref in
//    v1; the lexer gate is the on/off switch.
//

import AppKit
import Scintilla

extension ScintillaCodeEditor.Coordinator {

    /// Margin index that hosts the fold strip. 0 = line numbers,
    /// 1 = git gutter; 2 is the first free symbol margin. `internal`
    /// (not `fileprivate`) because `applyLexer` in Coordinator+Theme
    /// re-sets this margin's width on every lexer change.
    static let foldMarginIndex = 2

    /// The seven standard fold markers, in the order Scintilla expects
    /// them coloured. Box-tree glyphs give the familiar +/− with
    /// connecting lines down the margin.
    fileprivate static let foldMarkerNumbers: [Int] = [
        SC.MARKNUM_FOLDEROPEN,     // 31 — expanded header (−)
        SC.MARKNUM_FOLDER,         // 30 — contracted header (+)
        SC.MARKNUM_FOLDERSUB,      // 29 — body continuation (│)
        SC.MARKNUM_FOLDERTAIL,     // 28 — last child (└)
        SC.MARKNUM_FOLDEREND,      // 25 — contracted header w/ sibling (⊞)
        SC.MARKNUM_FOLDEROPENMID,  // 26 — expanded header w/ sibling (⊟)
        SC.MARKNUM_FOLDERMIDTAIL,  // 27 — child boundary (├)
    ]

    /// Fold-margin width in pixels for a given Lexilla lexer name.
    /// Pure (no view, no state) so it's the one piece of this file the
    /// unit tests can exercise — Scintilla's NSView can't be stood up
    /// under XCTest. Empty name ⇒ null lexer ⇒ no fold levels ⇒ no
    /// margin; any real lexer gets a 14 px strip.
    static func foldMarginWidth(forLexillaName name: String) -> Int {
        name.isEmpty ? 0 : 14
    }

    /// One-time setup of margin 2: type + initial width + fold mask +
    /// click sensitivity, the seven marker glyphs, the folded-line
    /// underline cue, and automatic-fold behaviour. Called from
    /// `makeNSView` immediately after `configureGitGutterMargin`.
    func configureFoldMargin(in view: ScintillaView) {
        let margin = UInt(Self.foldMarginIndex)
        view.message(SCI.SETMARGINTYPEN, wParam: margin, lParam: SC.MARGIN_SYMBOL)
        view.message(SCI.SETMARGINMASKN, wParam: margin, lParam: SC.MASK_FOLDERS)
        view.message(SCI.SETMARGINSENSITIVEN, wParam: margin, lParam: 1)
        // Initial width from the document's resolved lexer. `applyLexer`
        // (Coordinator+Theme) re-sets this whenever the lexer changes,
        // so a buffer that starts plain and is later language-tagged
        // still grows the strip — and vice-versa.
        let width = Self.foldMarginWidth(forLexillaName: LexerCatalog.descriptor(for: doc).lexillaName)
        view.message(SCI.SETMARGINWIDTHN, wParam: margin, lParam: width)

        defineFoldMarkers(view)

        // A horizontal rule under a contracted header is the standard
        // "there's hidden content here" cue (Xcode / VSCode / SciTE).
        view.message(SCI.SETFOLDFLAGS, wParam: UInt(SC.FOLDFLAG_LINEAFTER_CONTRACTED))

        // Let Scintilla own click-toggle, reveal-on-caret, and re-fold-
        // on-edit. No SCN_MARGINCLICK handler needed.
        let automatic = SC.AUTOMATICFOLD_SHOW | SC.AUTOMATICFOLD_CLICK | SC.AUTOMATICFOLD_CHANGE
        view.message(SCI.SETAUTOMATICFOLD, wParam: UInt(automatic))
    }

    /// Define the seven fold marker glyphs as a box tree. Colours are
    /// applied separately by `applyFoldMarkerColors` so they can track
    /// theme changes without re-defining the glyphs.
    fileprivate func defineFoldMarkers(_ view: ScintillaView) {
        defineFoldMarker(view, num: SC.MARKNUM_FOLDEROPEN,    glyph: SC.MARK_BOXMINUS)
        defineFoldMarker(view, num: SC.MARKNUM_FOLDER,        glyph: SC.MARK_BOXPLUS)
        defineFoldMarker(view, num: SC.MARKNUM_FOLDERSUB,     glyph: SC.MARK_VLINE)
        defineFoldMarker(view, num: SC.MARKNUM_FOLDERTAIL,    glyph: SC.MARK_LCORNER)
        defineFoldMarker(view, num: SC.MARKNUM_FOLDEREND,     glyph: SC.MARK_BOXPLUSCONNECTED)
        defineFoldMarker(view, num: SC.MARKNUM_FOLDEROPENMID, glyph: SC.MARK_BOXMINUSCONNECTED)
        defineFoldMarker(view, num: SC.MARKNUM_FOLDERMIDTAIL, glyph: SC.MARK_TCORNER)
    }

    fileprivate func defineFoldMarker(_ view: ScintillaView, num: Int, glyph: Int) {
        view.message(SCI.MARKERDEFINE, wParam: UInt(num), lParam: glyph)
    }

    /// Colour the fold markers + the margin background from the active
    /// theme, re-applied on every theme change from `applyTheme`. Box-
    /// tree glyphs invert fore/back: the glyph's *foreground* (its
    /// outline) is painted in the margin background colour and its
    /// *background* (the +/− fill) in the margin foreground colour, so
    /// the symbol reads as a recessed control against the strip rather
    /// than a bright dot. The fold-margin colour itself is pinned to
    /// the line-number margin background so the two strips blend into
    /// one continuous gutter.
    func applyFoldMarkerColors(in view: ScintillaView, theme: Theme) {
        let glyphLine = sciColor(theme.marginBackground)
        let glyphFill = sciColor(theme.marginForeground)
        for num in Self.foldMarkerNumbers {
            view.message(SCI.MARKERSETFORE, wParam: UInt(num), lParam: glyphLine)
            view.message(SCI.MARKERSETBACK, wParam: UInt(num), lParam: glyphFill)
        }
        // wParam = 1 ⇒ "use this colour" (vs follow the default).
        view.message(SCI.SETFOLDMARGINCOLOUR,   wParam: 1, lParam: sciColor(theme.marginBackground))
        view.message(SCI.SETFOLDMARGINHICOLOUR, wParam: 1, lParam: sciColor(theme.marginBackground))
    }

    // MARK: - Commands

    /// Collapse the fold enclosing the caret. Works from anywhere
    /// inside a block (not just the header line) by walking up to the
    /// enclosing header first. No-op at top level / in unfoldable text.
    func foldAtCaret(in view: ScintillaView) {
        let header = enclosingFoldHeader(in: view)
        guard header >= 0 else { return }
        view.message(SCI.FOLDLINE, wParam: UInt(header), lParam: SC.FOLDACTION_CONTRACT)
        // The caret may have been inside the now-hidden body; pull it
        // back into view so the next keystroke isn't lost off-screen.
        view.message(SCI.SCROLLCARET)
    }

    /// Expand the fold enclosing the caret. Symmetric with foldAtCaret.
    func unfoldAtCaret(in view: ScintillaView) {
        let header = enclosingFoldHeader(in: view)
        guard header >= 0 else { return }
        view.message(SCI.FOLDLINE, wParam: UInt(header), lParam: SC.FOLDACTION_EXPAND)
    }

    /// Collapse every fold in the document.
    func foldAll(in view: ScintillaView) {
        view.message(SCI.FOLDALL, wParam: UInt(SC.FOLDACTION_CONTRACT))
    }

    /// Expand every fold in the document.
    func unfoldAll(in view: ScintillaView) {
        view.message(SCI.FOLDALL, wParam: UInt(SC.FOLDACTION_EXPAND))
        view.message(SCI.SCROLLCARET)
    }

    /// The fold header that owns the caret line. If the caret sits on a
    /// header itself, that's the answer; otherwise climb to the parent
    /// via SCI_GETFOLDPARENT. Returns -1 when the caret isn't inside
    /// any fold (top-level code, or a buffer with no fold levels).
    fileprivate func enclosingFoldHeader(in view: ScintillaView) -> Int {
        let pos = view.message(SCI.GETCURRENTPOS)
        let line = Int(view.message(SCI.LINEFROMPOSITION, wParam: UInt(pos), lParam: 0))
        let level = Int(view.message(SCI.GETFOLDLEVEL, wParam: UInt(line)))
        if level & SC.FOLDLEVELHEADERFLAG != 0 {
            return line
        }
        // SCI_GETFOLDPARENT returns -1 when the line has no parent.
        return Int(view.message(SCI.GETFOLDPARENT, wParam: UInt(line)))
    }
}
