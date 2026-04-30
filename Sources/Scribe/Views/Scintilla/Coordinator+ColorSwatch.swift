//
//  Coordinator+ColorSwatch.swift
//  Phase 41f — paint inline color swatches behind every recognised
//  color literal. Powered by Scintilla indicator slot 1 with
//  `SC_INDICFLAG_VALUEFORE` so a single slot can host arbitrarily
//  many distinct colours.
//
//  Hot path
//    `applyColorSwatches(in:)` is called once in `makeNSView`
//    (after the initial document text lands) and once at the tail
//    of `updateNSView` (every SwiftUI tick). Real work — re-scan
//    + re-fill — runs only when the cheap signature
//    `(docLength, enabledFlag, fontHash)` actually changes;
//    otherwise we early-return.
//
//  Why the indicator approach
//    Scintilla has no native inline-image facility. Indicator
//    `INDIC_STRAIGHTBOX` paints a translucent rectangle behind the
//    indicated range — combined with the `VALUEFORE` flag the rect
//    can be tinted with the per-match colour read straight from
//    the literal. The literal text stays selectable / editable;
//    the swatch is just a visual overlay.
//
//  Large-file note
//    Scanning a 1 GB document on every keystroke would be
//    suicidal. We bail out for `Document.isLargeFile` documents
//    until a more incremental scanner exists (out of scope for
//    Phase 41f).
//

import AppKit
import Scintilla

extension ScintillaCodeEditor.Coordinator {

    /// One-time setup. Wires indicator slot 1 to use `STRAIGHTBOX`
    /// with the `VALUEFORE` flag, drawn under the text so the
    /// literal stays readable. The actual colours are supplied
    /// per-fill via `SETINDICATORVALUE`.
    func configureColorSwatchIndicator(to view: ScintillaView) {
        view.message(SCI.INDICSETSTYLE,
                     wParam: SCIND.COLOR_SWATCH,
                     lParam: SCIND.STRAIGHTBOX)
        view.message(SCI.INDICSETUNDER,
                     wParam: SCIND.COLOR_SWATCH,
                     lParam: 1)
        view.message(SCI.INDICSETALPHA,
                     wParam: SCIND.COLOR_SWATCH,
                     lParam: 200)
        view.message(SCI.INDICSETFLAGS,
                     wParam: SCIND.COLOR_SWATCH,
                     lParam: SCIND.FLAG_VALUEFORE)
    }

    /// Recompute swatches against the current document state. No-op
    /// when the cheap signature `(length, enabled, doc.id)` has not
    /// changed since the last paint — keeps the per-keystroke cost
    /// down to one O(1) Scintilla query.
    func applyColorSwatches(in view: ScintillaView) {
        guard !doc.isLargeFile else {
            // Large-file mode: clear any stale swatches and stop.
            clearColorSwatches(in: view)
            colorSwatchSignature = nil
            return
        }

        let enabled = prefs.inlineColorSwatchesEnabled
        let length = Int(view.message(SCI.GETLENGTH))
        let signature = ColorSwatchSignature(docID: doc.id,
                                             length: length,
                                             enabled: enabled)
        if signature == colorSwatchSignature { return }
        colorSwatchSignature = signature

        clearColorSwatches(in: view)
        guard enabled else { return }

        // Pull text once. For up to a few MB the `view.string()`
        // round-trip dominates — but it dominates regardless of
        // how we paint, and we already gate on `isLargeFile`.
        let text = view.string() ?? ""
        let hits = ColorScanner.scan(text)
        guard !hits.isEmpty else { return }

        view.message(SCI.SETINDICCURRENT, wParam: SCIND.COLOR_SWATCH)
        for match in hits {
            let value = SCIND.INDICVALUEBIT | UInt(match.color.sciBGR)
            view.message(SCI.SETINDICATORVALUE, wParam: value)
            let length = match.byteRange.upperBound - match.byteRange.lowerBound
            view.message(SCI.INDICFILLRANGE,
                         wParam: UInt(bitPattern: match.byteRange.lowerBound),
                         lParam: length)
        }
    }

    /// Clear any swatches the indicator currently owns. Used when
    /// the user toggles the feature off and when the underlying
    /// document is swapped (so a stale rectangle doesn't carry
    /// over to the next file).
    func clearColorSwatches(in view: ScintillaView) {
        let length = Int(view.message(SCI.GETLENGTH))
        guard length > 0 else { return }
        view.message(SCI.SETINDICCURRENT, wParam: SCIND.COLOR_SWATCH)
        view.message(SCI.INDICCLEARRANGE, wParam: 0, lParam: length)
    }
}

/// Cheap-equality cache key for the swatch repaint short-circuit.
/// Lives at file scope so it can be assigned to a stored property
/// declared on the Coordinator extension via the associated-object
/// trick is not needed — instead we add a real stored property
/// on the Coordinator (see ScintillaCodeEditor.swift).
struct ColorSwatchSignature: Equatable {
    let docID: UUID
    let length: Int
    let enabled: Bool
}
