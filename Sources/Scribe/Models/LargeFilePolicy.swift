//
//  LargeFilePolicy.swift
//  Phase 34a — central decision point for "is this a large file?"
//  and what concessions we make for it. Workspace.openFile consults
//  this so the threshold + side-effects move together.
//
//  Today's contract (v1):
//    - Files ≥ `thresholdBytes` (default 64 MiB) take the chunked
//      `LargeFileLoader` path. Smaller files keep the existing
//      Swift-`String` flow — the round-trip is cheap there and the
//      String-based code paths (Find-in-Files, syntax highlighting,
//      Markdown preview) keep working unchanged.
//    - Large-file documents disable lexer styling
//      (`SC_DOCUMENTOPTION_STYLES_NONE`). On a multi-hundred-MB log
//      file the lexer's styling pass dominates the loader time and
//      the user almost always wants the file legible *fast*, not
//      colourised.
//    - 64-bit positions (`SC_DOCUMENTOPTION_TEXT_LARGE`) flip on at
//      ≥ 1.5 GiB. The default 32-bit positions cap at ~2 GiB; we
//      switch a touch early so a file growing during the load
//      doesn't truncate.
//
//  Why not user-configurable yet:
//    Phase 34a is the foundation; the threshold + flags are
//    deliberately not exposed in Settings UI. A `defaults write`
//    escape hatch is fine for the rare power user; surfacing more
//    knobs before we've measured real workloads would just create
//    cargo-cult settings.
//

import Foundation

enum LargeFilePolicy {

    /// File-size threshold above which we take the chunked load
    /// path. Sized to comfortably contain the typical "I just
    /// got handed a giant log" case — a 60 MB README still loads
    /// the fast way.
    static let thresholdBytes: Int = 64 * 1024 * 1024     // 64 MiB

    /// Above this size we flip Scintilla into 64-bit document
    /// positions. The default 32-bit cap is 2 GiB; we leave a
    /// sizeable headroom so a streaming log can grow during the
    /// load without overflowing.
    static let textLargePositionsThreshold: Int = 1_536 * 1024 * 1024  // 1.5 GiB

    /// True when the file at `size` should bypass the Swift-String
    /// path. Pure function — no I/O, no UserDefaults — so call
    /// sites can be tested cheaply.
    static func shouldUseChunkedLoad(forSize size: Int) -> Bool {
        size >= thresholdBytes
    }

    /// Bitmask passed to `SCI_CREATELOADER` for a file of `size`.
    /// Always sets `STYLES_NONE` (the lexer pass dominates load
    /// time at this scale); flips `TEXT_LARGE` for multi-GB files.
    static func loaderOptions(forSize size: Int) -> Int {
        var opts = SC.DOCUMENTOPTION_STYLES_NONE
        if size >= textLargePositionsThreshold {
            opts |= SC.DOCUMENTOPTION_TEXT_LARGE
        }
        return opts
    }
}
