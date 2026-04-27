//
//  ScintillaCodeEditor.swift
//  Phase 1.7 — Scintilla-backed editor view. Currently a *minimum viable*
//  bridge: doc.text and prefs.fontFamily/fontSize are pushed into the
//  ScintillaView one-way. Two-way sync (typing in the view writing back
//  into doc.text), cursor row/col, soft tabs, line-number margin, and
//  light/dark theming are still TODO.
//
//  The legacy NSTextView-based `CodeEditor` lives alongside this file and
//  remains the production path until this bridge reaches feature parity.
//  See HANDOFF.md section 7 for the migration checklist.
//

import AppKit
import SwiftUI
import Scintilla

struct ScintillaCodeEditor: NSViewRepresentable {
    @ObservedObject var doc: Document
    @ObservedObject var prefs: EditorPreferences

    func makeNSView(context: Context) -> ScintillaView {
        let view = ScintillaView(frame: .zero)
        view.setEditable(true)
        applyText(view, text: doc.text)
        applyFont(view, prefs: prefs)
        return view
    }

    func updateNSView(_ view: ScintillaView, context: Context) {
        // Only push if we'd actually change something. Once we add the
        // delegate-based change feedback (Phase 1.7b), this guard prevents a
        // feedback loop.
        if view.string() != doc.text {
            applyText(view, text: doc.text)
        }
        applyFont(view, prefs: prefs)
    }

    private func applyText(_ view: ScintillaView, text: String) {
        view.setString(text)
    }

    private func applyFont(_ view: ScintillaView, prefs: EditorPreferences) {
        // EditorPreferences.fontName uses an empty string to mean "system
        // monospaced". Scintilla's setFontName: needs a concrete PostScript
        // family, so fall back to Menlo (always available on macOS).
        let family = prefs.fontName.isEmpty ? "Menlo" : prefs.fontName
        view.setFontName(family,
                         size: Int32(prefs.fontSize.rounded()),
                         bold: false,
                         italic: false)
    }
}
