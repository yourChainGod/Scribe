//
//  Coordinator+Theme.swift
//  Phase 28d — Theme + Lexer cluster, lifted out of
//  ScintillaCodeEditor.swift so the main file no longer carries
//  every concern of the editor coordinator at once. Visibility
//  contract: only `currentLexer` is module-internal — every
//  helper here is `private` to this file via `fileprivate`.
//
//  Why split: applyTheme + applyLanguageStyles together are ~70
//  lines of switch + per-style colour pushes. Sharing a file with
//  multi-cursor command handlers, find/replace, and the
//  notification dispatch made each cluster harder to navigate.
//  This extension is the smallest self-contained slice — it
//  reads `prefs`, `currentLexer`, and `view`; it doesn't touch
//  any other coordinator state.
//

import AppKit
import Scintilla
import Lexilla

extension ScintillaCodeEditor.Coordinator {

    // MARK: - Lexer

    /// Apply the Lexilla lexer matching this document. No-op when the
    /// resolved lexer matches `currentLexer`, so SwiftUI's frequent
    /// `updateNSView` calls don't churn the keyword tables.
    func applyLexer(for doc: Document, to view: ScintillaView) {
        let descriptor = LexerCatalog.descriptor(for: doc)
        guard descriptor.lexillaName != currentLexer else { return }
        currentLexer = descriptor.lexillaName

        // Empty name ⇒ leave Scintilla on its default null lexer.
        if descriptor.lexillaName.isEmpty {
            view.setReferenceProperty(Int32(SCI.SETILEXER), parameter: 0, value: nil)
            return
        }
        if let lexerPtr = LexillaBridgeCreateLexer(descriptor.lexillaName) {
            view.setReferenceProperty(Int32(SCI.SETILEXER), parameter: 0, value: lexerPtr)
            for (idx, words) in descriptor.keywords.enumerated() {
                view.setStringProperty(Int32(SCI.SETKEYWORDS),
                                       parameter: idx,
                                       value: words)
            }
        }
    }

    // MARK: - Theme

    /// Resolve the user-chosen theme (or `.system` follow-NSAppearance
    /// fallback) and push every relevant SCE_* style into the view.
    /// Idempotent — Scintilla's STYLECLEARALL gives us a clean slate
    /// before per-token colours are layered on top.
    func applyTheme(to view: ScintillaView) {
        // Phase 36: read `effectiveEditorThemeID` so the editor
        // honours the "follow UI theme" toggle. When the toggle is
        // on (default), this returns `uiThemeID`; when off, it
        // returns `editorThemeID`. `.system` still falls back to
        // NSAppearance for either path.
        //
        // Phase 39b — layer per-theme user slot overrides on top.
        // Doing the merge here (not just in ThemeHost) is what makes
        // the KVO appearance observer in ScintillaCodeEditor — which
        // calls into us outside the SwiftUI graph on Light/Dark flips
        // — pick up the user's overrides too.
        let editorID = prefs.effectiveEditorThemeID
        let baseTheme = editorID.resolve(appearance: NSApp.effectiveAppearance)
        let theme = baseTheme.applying(prefs.overrides(for: editorID))

        // STYLE_DEFAULT first — STYLECLEARALL copies it to every other style.
        view.message(SCI.STYLESETBACK, wParam: UInt(SC.STYLE_DEFAULT), lParam: sciColor(theme.background))
        view.message(SCI.STYLESETFORE, wParam: UInt(SC.STYLE_DEFAULT), lParam: sciColor(theme.foreground))
        view.message(SCI.STYLECLEARALL)

        // Line-number margin.
        view.message(SCI.STYLESETBACK, wParam: UInt(SC.STYLE_LINENUMBER), lParam: sciColor(theme.marginBackground))
        view.message(SCI.STYLESETFORE, wParam: UInt(SC.STYLE_LINENUMBER), lParam: sciColor(theme.marginForeground))

        // Selection + caret.
        view.message(SCI.SETSELBACK, wParam: 1, lParam: sciColor(theme.selectionBackground))
        view.message(SCI.SETCARETFORE, wParam: UInt(bitPattern: sciColor(theme.caret)))

        // Per-token colours depend on which lexer family is active.
        applyLanguageStyles(theme: theme, lexer: currentLexer, to: view)
    }

    // MARK: - Per-language style mapping

    /// Push token colours to the SCE_* style indices for the active
    /// lexer family. Adding a new family is two changes here:
    /// LexerCatalog mapping + a case in this switch.
    fileprivate func applyLanguageStyles(theme: Theme, lexer: String, to view: ScintillaView) {
        switch lexer {
        case "cpp", "javascript":
            setStyleColor(view, SCE_C.WORD,         fg: theme.keyword)
            setStyleColor(view, SCE_C.WORD2,        fg: theme.type)
            setStyleColor(view, SCE_C.STRING,       fg: theme.string)
            setStyleColor(view, SCE_C.CHARACTER,    fg: theme.string)
            setStyleColor(view, SCE_C.COMMENT,      fg: theme.comment)
            setStyleColor(view, SCE_C.COMMENTLINE,  fg: theme.comment)
            setStyleColor(view, SCE_C.COMMENTDOC,   fg: theme.comment)
            setStyleColor(view, SCE_C.NUMBER,       fg: theme.number)
            setStyleColor(view, SCE_C.PREPROCESSOR, fg: theme.preprocessor)
            setStyleColor(view, SCE_C.IDENTIFIER,   fg: theme.identifier)
            setStyleColor(view, SCE_C.GLOBALCLASS,  fg: theme.type)
        case "python":
            setStyleColor(view, SCE_P.WORD,         fg: theme.keyword)
            setStyleColor(view, SCE_P.WORD2,        fg: theme.type)
            setStyleColor(view, SCE_P.STRING,       fg: theme.string)
            setStyleColor(view, SCE_P.CHARACTER,    fg: theme.string)
            setStyleColor(view, SCE_P.TRIPLE,       fg: theme.string)
            setStyleColor(view, SCE_P.TRIPLEDOUBLE, fg: theme.string)
            setStyleColor(view, SCE_P.FSTRING,      fg: theme.string)
            setStyleColor(view, SCE_P.COMMENTLINE,  fg: theme.comment)
            setStyleColor(view, SCE_P.COMMENTBLOCK, fg: theme.comment)
            setStyleColor(view, SCE_P.NUMBER,       fg: theme.number)
            setStyleColor(view, SCE_P.CLASSNAME,    fg: theme.type)
            setStyleColor(view, SCE_P.DEFNAME,      fg: theme.type)
            setStyleColor(view, SCE_P.DECORATOR,    fg: theme.preprocessor)
            setStyleColor(view, SCE_P.IDENTIFIER,   fg: theme.identifier)
        default:
            break
        }
    }

    /// Convenience: set foreground for a SCE_* style index.
    fileprivate func setStyleColor(_ view: ScintillaView, _ style: Int, fg rgb: Int) {
        view.message(SCI.STYLESETFORE, wParam: UInt(style), lParam: sciColor(rgb))
    }

    /// Scintilla packs colours as 0x00BBGGRR in an `sptr_t`. Argument
    /// is a plain 0xRRGGBB integer.
    /// `internal` (no `fileprivate`) because `configureMatchIndicator`
    /// in the main editor file also feeds the indicator colour through
    /// this BGR-swizzle helper. Keeping one canonical implementation
    /// avoids two copies drifting apart.
    func sciColor(_ rgb: Int) -> Int {
        let r = (rgb >> 16) & 0xFF
        let g = (rgb >> 8)  & 0xFF
        let b =  rgb        & 0xFF
        return (b << 16) | (g << 8) | r
    }
}
