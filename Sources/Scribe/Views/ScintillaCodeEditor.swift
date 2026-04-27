//
//  ScintillaCodeEditor.swift
//  Phase 1.7b — Scintilla-backed editor view. Two-way sync via the
//  ScintillaNotificationProtocol delegate. Soft tabs, line-number margin,
//  and light/dark theming included.
//
//  The legacy NSTextView-based `CodeEditor` lives alongside this file and
//  remains the production path until 1.7c removes the SCRIBE_USE_SCINTILLA
//  hatch and deletes the old bridge. See HANDOFF.md section 7.
//

import AppKit
import SwiftUI
import Scintilla

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
}

private enum SC {
    static let MARGIN_NUMBER:   Int = 1
    static let STYLE_DEFAULT:   Int = 32
    static let STYLE_LINENUMBER: Int = 33
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

        // Initial state push.
        context.coordinator.applyText(doc.text, to: view, isExternal: true)
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

        func applyTheme(to view: ScintillaView) {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            // STYLE_DEFAULT first — STYLECLEARALL copies it to every other style.
            let bg = dark ? sciColor(0x1E1E1E) : sciColor(0xFFFFFF)
            let fg = dark ? sciColor(0xD4D4D4) : sciColor(0x1F1F1F)
            view.message(SCI.STYLESETBACK, wParam: UInt(SC.STYLE_DEFAULT), lParam: bg)
            view.message(SCI.STYLESETFORE, wParam: UInt(SC.STYLE_DEFAULT), lParam: fg)
            view.message(SCI.STYLECLEARALL)

            // Line-number margin gets its own muted look.
            let lnBg = dark ? sciColor(0x252526) : sciColor(0xF5F5F5)
            let lnFg = dark ? sciColor(0x858585) : sciColor(0x9A9A9A)
            view.message(SCI.STYLESETBACK, wParam: UInt(SC.STYLE_LINENUMBER), lParam: lnBg)
            view.message(SCI.STYLESETFORE, wParam: UInt(SC.STYLE_LINENUMBER), lParam: lnFg)

            // Selection + caret.
            let selBg = dark ? sciColor(0x264F78) : sciColor(0xADD6FF)
            view.message(SCI.SETSELBACK, wParam: 1, lParam: selBg)
            view.message(SCI.SETCARETFORE, wParam: UInt(bitPattern: Int(fg)))
        }

        /// Scintilla packs colours as 0x00BBGGRR in an `sptr_t`.
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
