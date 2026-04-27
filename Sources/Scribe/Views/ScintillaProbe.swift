//
//  ScintillaProbe.swift
//  Phase 1.6 — Smoke test that ScintillaView builds, links and runs from Swift.
//  Not yet wired into the main editor; this is purely a "does the bridge work"
//  probe. Will be removed when CodeEditor is migrated to Scintilla in
//  Phase 1.7.
//

import AppKit
import SwiftUI
import Scintilla

@MainActor
enum ScintillaProbe {
    /// Build a freshly constructed ScintillaView so we can confirm the symbol
    /// is reachable. Touching this triggers a link of the C++ runtime.
    static func makeView() -> ScintillaView {
        let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // ScintillaView declares `- (void) setString: (NSString *)` and
        // `- (NSString *) string` separately rather than as a synthesized
        // property, so Swift sees both as methods.
        v.setString("// Scintilla 5.6.1 — Phase 1 wiring smoke test.\n// 你好，世界。\nfor i in 0..<10 {\n    print(i)\n}\n")
        v.setEditable(true)
        return v
    }
}

/// SwiftUI wrapper for the probe view. Shown only when the user opens the
/// hidden Window > Scintilla Probe menu item (TODO).
struct ScintillaProbeView: NSViewRepresentable {
    func makeNSView(context: Context) -> ScintillaView { ScintillaProbe.makeView() }
    func updateNSView(_ nsView: ScintillaView, context: Context) {}
}
