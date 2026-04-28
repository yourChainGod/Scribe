//
//  SCIConstants.swift
//  Scintilla message IDs, search flags, indicator indices, style
//  indices, and notification codes mirrored from
//  Vendor/scintilla/include/Scintilla.h + Vendor/lexilla/include/SciLexer.h.
//
//  Why mirror them here instead of importing the headers:
//    Scintilla.h declares its IDs as plain `#define`d integers; Swift's
//    clang importer drops `#define`s without trailing-paren parameters,
//    so they don't appear in the auto-generated module. Mirroring keeps
//    the call sites readable (`SCI.GETLENGTH` reads as a verb) and lets
//    Coordinator+Theme / Coordinator+Find / Coordinator+MultiCursor
//    share one source of truth.
//
//  Visibility: `internal` so every file inside the Scribe target can
//  reach them. Outside the target there's no use case — the SCI
//  namespace is a Scintilla implementation detail.
//

import Foundation

// MARK: - Scintilla message IDs

/// Scintilla `SCI_*` message identifiers we actually call. Verified
/// against Vendor/scintilla/include/Scintilla.h on Scintilla 5.6.1.
enum SCI {
    // Queries
    static let GETLENGTH:        UInt32 = 2006
    static let GETCURRENTPOS:    UInt32 = 2008
    static let LINEFROMPOSITION: UInt32 = 2166
    static let GETCOLUMN:        UInt32 = 2129
    static let GETSELECTIONSTART:UInt32 = 2143
    static let GETSELECTIONEND:  UInt32 = 2145
    static let GETSELTEXT:       UInt32 = 2161
    static let POSITIONFROMLINE: UInt32 = 2167
    static let GETLINEENDPOSITION: UInt32 = 2136
    static let GOTOLINE:         UInt32 = 2024
    // Tabs
    static let SETTABWIDTH:      UInt32 = 2036
    static let SETUSETABS:       UInt32 = 2124
    // Margins
    static let SETMARGINTYPEN:   UInt32 = 2240
    static let SETMARGINWIDTHN:  UInt32 = 2242
    /// Phase 31 — `SCI_SETMARGINMASKN(margin, mask)` filters which
    /// marker numbers are allowed to render in the given margin.
    /// Without it Scintilla draws every marker (including system
    /// folding markers 25–31 if the lexer enables them) on every
    /// margin, which would make the git-gutter strip flicker with
    /// unrelated icons.
    static let SETMARGINMASKN:   UInt32 = 2244
    /// Phase 31 — marker setup. `MARKERDEFINE(num, type)` picks the
    /// glyph (FULLRECT, LEFTRECT, …); `MARKERSETBACK / FORE` colour
    /// it; `MARKERADD / DELETE(line, num)` paints / clears it.
    static let MARKERDEFINE:     UInt32 = 2040
    static let MARKERSETFORE:    UInt32 = 2041
    static let MARKERSETBACK:    UInt32 = 2042
    static let MARKERADD:        UInt32 = 2043
    static let MARKERDELETE:     UInt32 = 2044
    // Styles
    static let STYLECLEARALL:    UInt32 = 2050
    static let STYLESETFORE:     UInt32 = 2051
    static let STYLESETBACK:     UInt32 = 2052
    static let SETSELFORE:       UInt32 = 2067
    static let SETSELBACK:       UInt32 = 2068
    static let SETCARETFORE:     UInt32 = 2069
    static let STYLESETSIZE:     UInt32 = 2055
    static let STYLESETFONT:     UInt32 = 2056
    static let SETKEYWORDS:      UInt32 = 4005
    static let SETILEXER:        UInt32 = 4033
    // Selection / scrolling
    static let SETSEL:           UInt32 = 2160
    static let SCROLLCARET:      UInt32 = 2169
    // Search
    static let SETTARGETSTART:   UInt32 = 2190
    static let GETTARGETSTART:   UInt32 = 2191
    static let SETTARGETEND:     UInt32 = 2192
    static let GETTARGETEND:     UInt32 = 2193
    static let REPLACETARGET:    UInt32 = 2194
    static let REPLACETARGETRE:  UInt32 = 2195
    static let REPLACESEL:       UInt32 = 2170
    static let INSERTTEXT:       UInt32 = 2003
    static let SEARCHINTARGET:   UInt32 = 2197
    static let SETSEARCHFLAGS:   UInt32 = 2198
    // Indicators (for "highlight all matches")
    static let INDICSETSTYLE:    UInt32 = 2080
    static let INDICSETFORE:     UInt32 = 2082
    static let INDICSETALPHA:    UInt32 = 2523
    static let INDICSETUNDER:    UInt32 = 2510
    static let SETINDICCURRENT:  UInt32 = 2500
    static let INDICFILLRANGE:   UInt32 = 2504
    static let INDICCLEARRANGE:  UInt32 = 2505
    // Phase 20 — multi-cursor / multi-selection
    static let SETMULTIPLESELECTION:        UInt32 = 2563
    static let SETADDITIONALSELECTIONTYPING:UInt32 = 2565
    static let SETMULTIPASTE:               UInt32 = 2614
    static let SETSELECTIONMODE:            UInt32 = 2422
    /// Phase 23 — `SCI_GETSELECTIONMODE()` returns the current
    /// SelectionMode (stream / rectangular / lines / thin).
    static let GETSELECTIONMODE:            UInt32 = 2423
    /// Phase 23 — `SCI_CHANGESELECTIONMODE(mode)` switches the
    /// selection mode without touching MoveExtendsSelection,
    /// which `SETSELECTIONMODE` would also set. Cleaner for a
    /// pure toggle.
    static let CHANGESELECTIONMODE:         UInt32 = 2659
    /// Phase 23 — keyboard rectangular-extend verbs. Scintilla
    /// cocoa's default key map already binds ⇧⌥+arrow to these,
    /// so users get them "for free"; we expose them here so the
    /// verification hook can drive a rectangle without keystroke
    /// synthesis through System Events.
    static let LINEDOWNRECTEXTEND:          UInt32 = 2426
    static let LINEUPRECTEXTEND:            UInt32 = 2427
    static let CHARLEFTRECTEXTEND:          UInt32 = 2428
    static let CHARRIGHTRECTEXTEND:         UInt32 = 2429
    static let GETSELECTIONS:               UInt32 = 2570
    static let CLEARSELECTIONS:             UInt32 = 2571
    static let ADDSELECTION:                UInt32 = 2573
    // Selection N caret/anchor — message IDs verified against
    // Vendor/scintilla/include/Scintilla.h. Earlier phases of
    // this codebase had them swapped with the
    // *VIRTUALSPACE / *START variants, which presented as
    // GETSELECTIONNCARET returning the selection START instead
    // of the caret end. Phase 22 caught it because reading the
    // caret of a forward-anchored selection always returned
    // anchor+0, which broke the maxEnd computation in
    // selectNextOccurrence.
    static let SETSELECTIONNCARET:          UInt32 = 2576
    static let GETSELECTIONNCARET:          UInt32 = 2577
    static let SETSELECTIONNANCHOR:         UInt32 = 2578
    static let GETSELECTIONNANCHOR:         UInt32 = 2579
    static let SETMAINSELECTION:            UInt32 = 2574
    static let GETMAINSELECTION:            UInt32 = 2575
    /// Phase 22 — `SCI_DROPSELECTIONN(int selection)` removes the
    /// numbered selection from the multi-selection set without
    /// touching the others.
    static let DROPSELECTIONN:              UInt32 = 2671
    static let WORDSTARTPOSITION:           UInt32 = 2266
    static let WORDENDPOSITION:             UInt32 = 2267
    static let GETTEXTRANGE:                UInt32 = 2162
    static let GETLINECOUNT:                UInt32 = 2154
    /// Phase 21 — `SCI_FINDCOLUMN(line, column)` returns the byte
    /// position at the given visual column on the given line, or
    /// the line-end position if the line is shorter. Cleanest way
    /// to project a caret column onto an adjacent line.
    static let FINDCOLUMN:                  UInt32 = 2456
    /// Phase 27d — disable Scintilla's built-in right-click pop-up so
    /// SwiftUI's `.contextMenu` modifier on the wrapping view can
    /// take over. The built-in menu is hard-coded English in
    /// Vendor/scintilla and can't be themed without forking.
    /// `SCI_USEPOPUP(SC_POPUP_NEVER)` tells the lexer to leave the
    /// right-click event alone so the responder chain bubbles up.
    static let USEPOPUP:                    UInt32 = 2371
    /// Edit verbs we drive from the SwiftUI replacement context menu.
    /// Same numeric identifiers Scintilla itself uses internally.
    static let UNDO:        UInt32 = 2176
    static let REDO:        UInt32 = 2011
    static let CUT:         UInt32 = 2177
    static let COPY:        UInt32 = 2178
    static let PASTE:       UInt32 = 2179
    static let CLEAR:       UInt32 = 2180
    static let SELECTALL:   UInt32 = 2013
    /// Caret state queries used by the context-menu enable/disable
    /// logic. Returns 1 / 0 booleans cast as Int.
    static let CANUNDO:     UInt32 = 2174
    static let CANREDO:     UInt32 = 2016
    static let CANPASTE:    UInt32 = 2173
    /// Phase 34a — large-file streaming load. `SCI_CREATELOADER(initial,
    /// options)` returns an `ILoader *` (as sptr_t) we feed bytes into;
    /// `SCI_SETDOCPOINTER(0, doc)` swaps Scintilla's active document for
    /// the one the loader produced. Both bypass `setString` so a 1 GB
    /// file no longer round-trips through a Swift `String`.
    static let CREATELOADER:      UInt32 = 2632
    static let SETDOCPOINTER:     UInt32 = 2026
    static let RELEASEDOCUMENT:   UInt32 = 2377
    static let ADDREFDOCUMENT:    UInt32 = 2376

    // Phase 35c-ii-γ — EOL annotations (Scintilla 5.x feature).
    // Lets us paint a soft trailing label after a line's contents
    // without pushing the source text around. Used by the inline-
    // blame UI for the "Author, 3 days ago • SHA" caret label.
    /// `SCI_EOLANNOTATIONSETTEXT(line, text)` — set the trailing
    /// annotation for `line` (0-based). Empty string clears it.
    static let EOLANNOTATIONSETTEXT:    UInt32 = 2740
    /// `SCI_EOLANNOTATIONSETSTYLE(line, style)` — picks the style
    /// number to draw the annotation in (separate from the line's
    /// own lex styles).
    static let EOLANNOTATIONSETSTYLE:   UInt32 = 2742
    /// `SCI_EOLANNOTATIONCLEARALL()` — drop every EOL annotation
    /// in the buffer in one call. Cheaper than walking lines.
    static let EOLANNOTATIONCLEARALL:   UInt32 = 2744
    /// `SCI_EOLANNOTATIONSETVISIBLE(visibility)` — global toggle +
    /// shape selector. We pass `SC.EOLANNOTATION_STADIUM` so the
    /// label renders as a soft rounded chip à la zed.
    static let EOLANNOTATIONSETVISIBLE: UInt32 = 2745
    /// Style getter — used by the theme path to (un)apply colours
    /// without storing a separate "current foreground" value.
    static let STYLEGETFORE:            UInt32 = 2481
    /// Style setter — italic / bold / size for the inline-blame
    /// chip's typography.
    static let STYLESETITALIC:          UInt32 = 2053
}

// MARK: - Search flags

/// Scintilla `SCFIND_*` flags as documented in Scintilla.h.
enum SCFIND {
    static let MATCHCASE: UInt = 4
    static let WHOLEWORD: UInt = 2
    static let REGEXP:    UInt = 0x00200000
    static let CXX11REGEX:UInt = 0x00400000
}

// MARK: - Indicator indices

/// Indicator style indices we use for the find bar.
enum SCIND {
    /// Indicator index 0 (out of 0–7 user-available; 8–31 are reserved
    /// by Scintilla for things like decorations).
    static let MATCHES:   UInt = 0
    /// INDIC_ROUNDBOX = 7 — translucent rounded rectangle, common for
    /// "all matches" overlays.
    static let ROUNDBOX:  Int  = 7
}

// MARK: - Misc Scintilla constants

/// Misc `SC_*` constants that aren't message IDs — margin numbers,
/// reserved style indices, selection-mode enum values.
enum SC {
    static let MARGIN_NUMBER:    Int = 1
    /// Phase 31 — `SC_MARGIN_SYMBOL = 0`. Margin type that draws
    /// per-line markers added via `SCI_MARKERADD`. Margin 1 in the
    /// editor is dedicated to the git gutter strip.
    static let MARGIN_SYMBOL:    Int = 0
    /// Phase 31 — marker glyph types. `FULLRECT` paints the whole
    /// margin cell; `LEFTRECT` paints a thin sliver at the left.
    /// We pick FULLRECT for added/modified (loud, GitHub-style)
    /// and LEFTRECT for `deletedAbove` (subtle pointer that something
    /// disappeared just above this row).
    static let MARK_FULLRECT:    Int = 26
    static let MARK_LEFTRECT:    Int = 27
    /// Phase 34a — `SC_DOCUMENTOPTION_*` flags passed as the second
    /// argument to `SCI_CREATELOADER`. `TEXT_LARGE` enables 64-bit
    /// document positions so a > 2 GB file doesn't truncate (default
    /// is 32-bit positions); `STYLES_NONE` skips style-byte allocation
    /// for documents we never lex (cheaper on huge logs).
    static let DOCUMENTOPTION_DEFAULT:     Int = 0x000
    static let DOCUMENTOPTION_STYLES_NONE: Int = 0x001
    static let DOCUMENTOPTION_TEXT_LARGE:  Int = 0x100
    static let STYLE_DEFAULT:    Int = 32
    static let STYLE_LINENUMBER: Int = 33
    /// Phase 23 — `SelectionMode` enum values. Stream is the
    /// default; rectangle is what VSCode calls "Column Selection
    /// Mode". `lines` and `thin` are exposed by Scintilla but we
    /// don't bind them in the UI — `lines` doesn't fit the
    /// macOS editing model, `thin` is a Scintilla-internal
    /// stepping-stone of `rectangle`.
    static let SEL_STREAM:    Int = 0
    static let SEL_RECTANGLE: Int = 1

    // Phase 35c-ii-γ — EOL annotation visibility / shape constants.
    // `STADIUM` is the rounded-rectangle shape that reads cleanly
    // as a "chip" against editor body text — what zed and GitLens
    // both default to for inline blame.
    static let EOLANNOTATION_HIDDEN:   Int = 0x000
    static let EOLANNOTATION_STANDARD: Int = 0x001
    static let EOLANNOTATION_BOXED:    Int = 0x002
    static let EOLANNOTATION_STADIUM:  Int = 0x100

    /// Phase 35c-ii-γ — style index reserved for the inline-blame
    /// EOL annotation. Scintilla's predefined styles run 32–39;
    /// Lexilla emits 0–31. 40 is the first user-available slot
    /// for editor-controlled styling, so picking it can't collide
    /// with any lexer's per-language style indices.
    static let STYLE_INLINE_BLAME: Int = 40
}

// MARK: - Lexer style indices

/// Lexilla SCE_C_* style indices used by the C/C++/JS/Swift lexers
/// (LexerCatalog falls back to lmCPP for these). Verified against
/// Vendor/lexilla/include/SciLexer.h.
enum SCE_C {
    static let DEFAULT:      Int = 0
    static let COMMENT:      Int = 1
    static let COMMENTLINE:  Int = 2
    static let COMMENTDOC:   Int = 3
    static let NUMBER:       Int = 4
    static let WORD:         Int = 5
    static let STRING:       Int = 6
    static let CHARACTER:    Int = 7
    static let PREPROCESSOR: Int = 9
    static let OPERATOR:     Int = 10
    static let IDENTIFIER:   Int = 11
    static let WORD2:        Int = 16
    static let GLOBALCLASS:  Int = 19
}

/// Lexilla SCE_P_* style indices used by the Python lexer.
enum SCE_P {
    static let DEFAULT:      Int = 0
    static let COMMENTLINE:  Int = 1
    static let NUMBER:       Int = 2
    static let STRING:       Int = 3
    static let CHARACTER:    Int = 4
    static let WORD:         Int = 5
    static let TRIPLE:       Int = 6
    static let TRIPLEDOUBLE: Int = 7
    static let CLASSNAME:    Int = 8
    static let DEFNAME:      Int = 9
    static let OPERATOR:     Int = 10
    static let IDENTIFIER:   Int = 11
    static let COMMENTBLOCK: Int = 12
    static let WORD2:        Int = 14
    static let DECORATOR:    Int = 15
    static let FSTRING:      Int = 16
}

// MARK: - Notification codes

/// Scintilla notification codes — `SCN_*` values delivered through
/// `ScintillaNotificationProtocol.notification(_:)`.
enum SCN {
    static let MODIFIED: UInt32 = 2008
    static let UPDATEUI: UInt32 = 2007
}
