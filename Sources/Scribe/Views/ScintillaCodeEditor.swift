//
//  ScintillaCodeEditor.swift
//  Default editor since Phase 1.7c. Wraps Scintilla's NSView-based
//  ScintillaView in a SwiftUI NSViewRepresentable.
//
//  Coordinator implements ScintillaNotificationProtocol for two-way sync:
//    SCN_MODIFIED  → view.string() is written back to doc.text + dirty flag
//    SCN_UPDATEUI  → cursor row/col is pushed to doc.cursorLine/Column
//  An isApplyingExternalUpdate guard breaks the doc → view → doc echo.
//
//  Themes track NSApp.effectiveAppearance via KVO; tab width / soft tabs
//  follow EditorPreferences live.
//

import AppKit
import SwiftUI
import Scintilla
import Lexilla

// MARK: - SCI_* / SCN_* numeric constants
//
// Scintilla.h defines these as plain `#define`d integers; Swift's clang
// importer doesn't always pick them up, so we mirror the ones we use.
// Values verified against Vendor/scintilla/include/Scintilla.h on Scintilla 5.6.1.
private enum SCI {
    // Queries
    static let GETLENGTH:        UInt32 = 2006
    static let GETCURRENTPOS:    UInt32 = 2008
    static let LINEFROMPOSITION: UInt32 = 2166
    static let GETCOLUMN:        UInt32 = 2129
    // Tabs
    static let SETTABWIDTH:      UInt32 = 2036
    static let SETUSETABS:       UInt32 = 2124
    // Margins
    static let SETMARGINTYPEN:   UInt32 = 2240
    static let SETMARGINWIDTHN:  UInt32 = 2242
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
}

private enum SC {
    static let MARGIN_NUMBER:    Int = 1
    static let STYLE_DEFAULT:    Int = 32
    static let STYLE_LINENUMBER: Int = 33
}

/// Lexilla SCE_C_* style indices used by the C/C++/JS/Swift lexers
/// (LexerCatalog falls back to lmCPP for these). Verified against
/// Vendor/lexilla/include/SciLexer.h.
private enum SCE_C {
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
private enum SCE_P {
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

private enum SCN {
    static let MODIFIED: UInt32 = 2008
    static let UPDATEUI: UInt32 = 2007
}

// MARK: - SwiftUI representable

struct ScintillaCodeEditor: NSViewRepresentable {
    @ObservedObject var doc: Document
    @ObservedObject var prefs: EditorPreferences

    func makeCoordinator() -> Coordinator {
        Coordinator(doc: doc, prefs: prefs)
    }

    func makeNSView(context: Context) -> ScintillaView {
        let view = ScintillaView(frame: .zero)
        view.setEditable(true)
        view.delegate = context.coordinator   // ScintillaNotificationProtocol
        context.coordinator.attach(view: view)

        // Initial state push. Lexer must precede font + theme so per-style
        // applies hit the right SCE_* indices.
        context.coordinator.applyText(doc.text, to: view, isExternal: true)
        context.coordinator.applyLexer(for: doc, to: view)
        context.coordinator.applyFont(prefs: prefs, to: view)
        context.coordinator.applyTabs(prefs: prefs, to: view)
        context.coordinator.applyLineNumberMargin(to: view)
        context.coordinator.applyTheme(to: view)
        return view
    }

    func updateNSView(_ view: ScintillaView, context: Context) {
        // Pick up SwiftUI-driven changes to doc/prefs. The coordinator's flag
        // is what stops the SCN_MODIFIED ↔ doc.text feedback loop.
        context.coordinator.doc = doc
        context.coordinator.prefs = prefs

        if view.string() != doc.text {
            context.coordinator.applyText(doc.text, to: view, isExternal: true)
        }
        context.coordinator.applyLexer(for: doc, to: view)
        context.coordinator.applyFont(prefs: prefs, to: view)
        context.coordinator.applyTabs(prefs: prefs, to: view)
        context.coordinator.applyTheme(to: view)
    }

    // MARK: - Coordinator (Scintilla delegate)

    @MainActor
    final class Coordinator: NSObject, @preconcurrency ScintillaNotificationProtocol {
        var doc: Document
        var prefs: EditorPreferences
        weak var view: ScintillaView?

        /// `true` while we are pushing doc → view; suppresses the SCN_MODIFIED
        /// echo that would otherwise overwrite doc.text with the same content.
        private var isApplyingExternalUpdate = false

        /// Lexer currently set on the view. Tracked so we only call
        /// `SCI_SETILEXER` when the language actually changes.
        private var currentLexer: String = ""

        private var appearanceObserver: NSKeyValueObservation?

        init(doc: Document, prefs: EditorPreferences) {
            self.doc = doc
            self.prefs = prefs
            super.init()
        }

        deinit {
            appearanceObserver?.invalidate()
        }

        func attach(view: ScintillaView) {
            self.view = view
            // Re-theme when the user toggles light/dark in System Settings.
            // We can't capture self in a Sendable closure under strict
            // concurrency, so use a weak NSApp KVO and dispatch onto main.
            appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self, weak view] _, _ in
                guard let self, let view else { return }
                Task { @MainActor in
                    self.applyTheme(to: view)
                }
            }
        }

        // MARK: doc → view

        func applyText(_ text: String, to view: ScintillaView, isExternal: Bool) {
            isApplyingExternalUpdate = isExternal
            view.setString(text)
            isApplyingExternalUpdate = false
        }

        func applyFont(prefs: EditorPreferences, to view: ScintillaView) {
            let family = prefs.fontName.isEmpty ? "Menlo" : prefs.fontName
            view.setFontName(family,
                             size: Int32(prefs.fontSize.rounded()),
                             bold: false,
                             italic: false)
        }

        func applyTabs(prefs: EditorPreferences, to view: ScintillaView) {
            view.message(SCI.SETTABWIDTH, wParam: UInt(prefs.tabWidth))
            view.message(SCI.SETUSETABS, wParam: prefs.softTabs ? 0 : 1)
        }

        func applyLineNumberMargin(to view: ScintillaView) {
            // Margin 0 = line numbers, ~44px wide.
            view.message(SCI.SETMARGINTYPEN, wParam: 0, lParam: Int(SC.MARGIN_NUMBER))
            view.message(SCI.SETMARGINWIDTHN, wParam: 0, lParam: 44)
        }

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

        func applyTheme(to view: ScintillaView) {
            let theme = Theme.resolved(for: NSApp.effectiveAppearance)

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

        /// Push token colours to the SCE_* style indices for the active
        /// lexer family. Adding a new family is two changes here:
        /// LexerCatalog mapping + a case in this switch.
        private func applyLanguageStyles(theme: Theme, lexer: String, to view: ScintillaView) {
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
        private func setStyleColor(_ view: ScintillaView, _ style: Int, fg rgb: Int) {
            view.message(SCI.STYLESETFORE, wParam: UInt(style), lParam: sciColor(rgb))
        }

        /// Scintilla packs colours as 0x00BBGGRR in an `sptr_t`. Argument
        /// is a plain 0xRRGGBB integer.
        private func sciColor(_ rgb: Int) -> Int {
            let r = (rgb >> 16) & 0xFF
            let g = (rgb >> 8)  & 0xFF
            let b =  rgb        & 0xFF
            return (b << 16) | (g << 8) | r
        }

        // MARK: view → doc (ScintillaNotificationProtocol)

        func notification(_ scn: UnsafeMutablePointer<SCNotification>?) {
            guard let scn else { return }
            let code = scn.pointee.nmhdr.code

            switch code {
            case SCN.MODIFIED:
                if !isApplyingExternalUpdate, let view {
                    let newText = view.string() ?? ""
                    if newText != doc.text {
                        doc.text = newText
                        if !doc.isDirty { doc.isDirty = true }
                    }
                }
            case SCN.UPDATEUI:
                if let view {
                    let pos = view.message(SCI.GETCURRENTPOS)
                    let line = view.message(SCI.LINEFROMPOSITION, wParam: UInt(pos))
                    let col = view.message(SCI.GETCOLUMN, wParam: UInt(pos))
                    let line1 = Int(line) + 1   // Scintilla is 0-based
                    let col1  = Int(col)  + 1
                    if doc.cursorLine != line1 { doc.cursorLine = line1 }
                    if doc.cursorColumn != col1 { doc.cursorColumn = col1 }
                }
            default:
                break
            }
        }
    }
}
