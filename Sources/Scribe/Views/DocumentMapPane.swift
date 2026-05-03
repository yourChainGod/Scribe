//
//  DocumentMapPane.swift
//  Phase 56 — Notepad++-style Document Map (a.k.a. minimap). A read-only
//  ScintillaView rendered at a tiny font (2 pt) on the trailing edge of
//  the editor canvas, so the user gets a 30,000-foot view of the buffer
//  without paying for a separate code path.
//
//  Why a second ScintillaView (and not a custom NSView that paints text
//  by hand): re-using Scintilla's painter means we get syntax colouring,
//  word-wrap-off, EOL handling, and Unicode rendering for free, all
//  consistent with the main editor. The cost is one extra view per
//  document tab and a `setString` push every time `doc.text` changes.
//
//  Sync model — V1 (this file)
//    The minimap holds its own Scintilla buffer and pushes `doc.text`
//    on every `updateNSView` tick when the byte count differs from the
//    main editor. This is simpler than the doc-pointer-sharing route
//    (Phase 34a's SETDOCPOINTER plumbing) because:
//      - No Scintilla refcount juggling between the two views.
//      - No risk of the minimap holding a dangling Document* if SwiftUI
//        tears down the main editor first.
//      - The push is throttled by SwiftUI's own update cadence, which
//        already follows the SCN_MODIFIED → doc.text 50 ms debounce.
//    Per-keystroke cost is one O(N) `setString` on a buffer that's
//    typically the same size as the main editor's; for the 100 KB
//    Markdown / source files Scribe targets this is a no-op on a
//    modern Mac. Phase 56b will swap in real doc-pointer sharing for
//    the multi-MB case if profiling demands it.
//
//  Click-to-jump
//    Mouse-down on the minimap converts the local Y coordinate to a
//    document line via `SCI_LINEFROMPOSITION` ∘ `SCI_POSITIONFROMPOINT`,
//    then writes a `PendingScrollTarget(line:)` to `doc.pendingScroll`.
//    The main editor's existing `consumePendingScroll(in:)` consumer
//    drains it on the very next `updateNSView`, scrolling the caret
//    into view and selecting the destination line — same affordance
//    the cross-file find / outline / CLI-jump paths use.
//

import AppKit
import SwiftUI
import Scintilla
import Lexilla

struct DocumentMapPane: NSViewRepresentable {
    @ObservedObject var doc: Document
    @ObservedObject var prefs: EditorPreferences
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme

    /// Phase 56 — visual budget. 120 pt is wide enough to read at
    /// 2 pt font (~30 chars), narrow enough that an editor with a
    /// minimap still shows generous editor real estate at typical
    /// window widths. Notepad++ uses ~100 px; VSCode ~120 px.
    static let preferredWidth: CGFloat = 120

    /// Phase 56 — the literal "tiny" font size. 2 pt is the
    /// smallest size where Scintilla's painter still produces
    /// readable line shapes (1 pt collapses to a single pixel
    /// row). Tested against Menlo + system mono.
    static let minimapFontSize: Int32 = 2

    func makeCoordinator() -> Coordinator {
        Coordinator(doc: doc, prefs: prefs)
    }

    func makeNSView(context: Context) -> ScintillaView {
        let view = ScintillaView(frame: .zero)
        view.delegate = context.coordinator
        context.coordinator.attach(view: view)

        // Initial state push. Order matters: lexer first so the
        // theme's per-style colours land on the right SCE_* indices.
        view.setEditable(true)   // setString needs writability
        if !doc.text.isEmpty {
            view.setString(doc.text)
        }
        context.coordinator.applyLexer(to: view)
        context.coordinator.applyMinimapStyling(to: view, isDark: colorScheme == .dark)
        // Lock the buffer once the first paint has the right
        // styling — `applyMinimapStyling` calls `STYLECLEARALL`
        // and `STYLESETSIZE`, both of which Scintilla's
        // SETREADONLY happily lets through, but rejecting all
        // user input keeps the minimap from accidentally
        // accepting drag-drop / paste / typing when focused.
        view.setEditable(false)

        // Suppress the built-in English right-click menu — the
        // minimap has no useful context actions of its own and
        // Scribe routes context menus through SwiftUI elsewhere.
        view.message(SCI.USEPOPUP, wParam: UInt(0))   // SC_POPUP_NEVER

        return view
    }

    static func dismantleNSView(_ view: ScintillaView, coordinator: Coordinator) {
        // Mirror ScintillaCodeEditor.dismantleNSView's `unsafe_unretained`
        // delegate-clear, defending against Scintilla's NSNotificationCenter
        // observers calling back into a freed Coordinator. See the
        // long-form comment over there for the full rationale.
        view.delegate = nil
    }

    func updateNSView(_ view: ScintillaView, context: Context) {
        context.coordinator.doc = doc
        context.coordinator.prefs = prefs

        // Resync only when the byte count differs — `setString` is
        // O(N) and SwiftUI calls `updateNSView` on every keystroke
        // tick. The byte-count cheap-signature is the same trick
        // ScintillaCodeEditor uses; the minimap doesn't have to be
        // pixel-accurate every keystroke (the throttled main-editor
        // sync drives the 50 ms debounce upstream of us).
        let viewLen = Int(view.message(SCI.GETLENGTH))
        let docLen = doc.text.utf8.count
        if viewLen != docLen {
            view.setEditable(true)
            view.setString(doc.text)
            view.setEditable(false)
        }
        context.coordinator.applyLexer(to: view)
        context.coordinator.applyMinimapStyling(to: view, isDark: colorScheme == .dark)
        context.coordinator.applyViewportHighlight(to: view)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, @preconcurrency ScintillaNotificationProtocol {
        var doc: Document
        var prefs: EditorPreferences
        weak var view: ScintillaView?

        /// Last lexer name actually applied. Same gating trick as
        /// the main editor's `currentLexer` — calling SETILEXER on
        /// every tick rebuilds the keyword tables, so we no-op
        /// when the resolved lexer matches what we last set.
        private var currentLexer: String = ""

        /// Click handler installed on the underlying NSView. Lives
        /// here (not on the SwiftUI representable) so dismantle
        /// can pull it cleanly via `monitor` removal.
        private var clickMonitor: Any?

        init(doc: Document, prefs: EditorPreferences) {
            self.doc = doc
            self.prefs = prefs
            super.init()
        }

        deinit {
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func attach(view: ScintillaView) {
            self.view = view
            installClickToJump(in: view)
        }

        // MARK: - Lexer

        /// Mirror the main editor's lexer choice so the minimap's
        /// styling tracks code structure (keyword colour blocks
        /// give the user a recognisable shape to scroll towards).
        func applyLexer(to view: ScintillaView) {
            let descriptor = LexerCatalog.descriptor(for: doc)
            guard descriptor.lexillaName != currentLexer else { return }
            currentLexer = descriptor.lexillaName
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

        // MARK: - Styling

        /// Tiny font + zero margins + no scrollbars + softened
        /// per-style foregrounds so the minimap reads as a
        /// thumbnail rather than a normal editor crammed into a
        /// narrow column.
        func applyMinimapStyling(to view: ScintillaView, isDark: Bool) {
            // Reach directly for the two canonical built-in themes
            // — the minimap doesn't honour user theme overrides in
            // v1 because the tiny font size renders custom colours
            // mostly illegible. Inkwell / Daylight are the Phase 39a
            // dark / light presets the rest of Scribe defaults to.
            let theme: Theme = isDark ? .inkwell : .daylight
            let bg = sciColor(rgb: theme.background)
            let fg = sciColor(rgb: theme.foreground)

            // Default style first — STYLECLEARALL copies it to
            // every other style index, then per-style colours
            // re-overlay the keyword / comment / string slots.
            view.message(SCI.STYLESETBACK, wParam: UInt(SC.STYLE_DEFAULT), lParam: bg)
            view.message(SCI.STYLESETFORE, wParam: UInt(SC.STYLE_DEFAULT), lParam: fg)
            view.setFontName("Menlo",
                             size: DocumentMapPane.minimapFontSize,
                             bold: false,
                             italic: false)
            view.message(SCI.STYLECLEARALL)

            // Hide every margin (line numbers, fold, git gutter
            // bars). Each margin index defaults to non-zero
            // widths in vanilla Scintilla.
            for idx: UInt in 0...3 {
                view.message(SCI.SETMARGINWIDTHN,
                             wParam: idx,
                             lParam: 0)
            }

            // No scrollbars on a 120 pt strip — the user navigates
            // by clicking, not by dragging. Scintilla will still
            // truncate at the right edge for over-long lines,
            // which is exactly what we want for a thumbnail.
            view.message(SCI.SETHSCROLLBAR, wParam: 0)
            view.message(SCI.SETVSCROLLBAR, wParam: 0)

            // Caret invisibility — minimap shouldn't blink. A
            // CARETPERIOD of 0 freezes the caret; CARETSTYLE 0
            // (CARETSTYLE_INVISIBLE) keeps it from drawing at
            // all. Both together, just to be safe.
            view.message(SCI.SETCARETPERIOD, wParam: 0)
            view.message(SCI.SETCARETSTYLE, wParam: 0)
        }

        // MARK: - Viewport overlay

        /// Phase 56 v1 leaves the viewport-rectangle painting to a
        /// future iteration (it requires per-pixel coordinate
        /// math against `SCI_POINTXFROMPOSITION`, plus a custom
        /// NSView overlay to draw the rect). For now we just
        /// scroll the minimap to keep the main editor's caret
        /// roughly centered — gives the user enough orientation
        /// to confirm "yes, the minimap follows me".
        func applyViewportHighlight(to view: ScintillaView) {
            let mainTopLine0 = max(0, doc.viewportTopLine - 1)
            let totalLines = view.message(SCI.GETLINECOUNT)
            // Scroll only when the main editor is past the
            // minimap's last fully visible line by enough that the
            // caret would be off-screen. Cheap O(1) compares.
            let onScreen = view.message(SCI.LINESONSCREEN)
            let mapFirst = view.message(SCI.GETFIRSTVISIBLELINE)
            let mapLast = mapFirst + max(0, onScreen)
            if mainTopLine0 < Int(mapFirst) || mainTopLine0 > Int(mapLast) {
                let target = max(0,
                                 min(Int(totalLines) - 1,
                                     mainTopLine0 - Int(onScreen) / 2))
                view.message(SCI.SETFIRSTVISIBLELINE, wParam: UInt(target))
            }
        }

        // MARK: - Click-to-jump

        /// Install a local NSEvent monitor that intercepts left
        /// mouse-down events landing inside the minimap. Local
        /// monitors stay scoped to the current process, so we
        /// don't inadvertently swallow clicks elsewhere.
        private func installClickToJump(in view: ScintillaView) {
            // Already installed — guard against re-attach.
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak view] event in
                guard let self, let view, let window = view.window,
                      event.window === window else { return event }
                // Only intercept clicks inside this minimap's bounds.
                let pointInWindow = event.locationInWindow
                let pointInView = view.convert(pointInWindow, from: nil)
                guard view.bounds.contains(pointInView) else { return event }

                // Convert the click's Y to a document line. Scintilla's
                // position lookup needs the point in *view* coordinates
                // with origin at the top-left, which is what convert(…)
                // returns on a layer-backed Cocoa view.
                let pos = view.message(SCI.POSITIONFROMPOINT,
                                       wParam: UInt(bitPattern: Int(pointInView.x)),
                                       lParam: Int(pointInView.y))
                let line0 = view.message(SCI.LINEFROMPOSITION,
                                         wParam: UInt(bitPattern: Int(pos)))
                let line1 = max(1, Int(line0) + 1)
                Task { @MainActor in
                    self.doc.pendingScroll = PendingScrollTarget(line: line1)
                }
                // Swallow the event — the click was a navigation
                // gesture, not text input. Returning nil tells
                // AppKit to stop the event propagation.
                return nil
            }
        }

        // MARK: - ScintillaNotificationProtocol

        /// Phase 56 — minimap is read-only and ignores every
        /// upstream notification (no caret tracking, no Find
        /// highlight, no GitGutter). Keeping the conformance
        /// satisfied with a no-op handler is the cheapest path.
        func notification(_ scn: UnsafeMutablePointer<SCNotification>?) {
            // Intentionally empty.
        }

        // MARK: - Helpers

        /// Same colour packing the main editor uses (BGR order
        /// because that's what Scintilla expects). Re-implemented
        /// here rather than reaching into ScintillaCodeEditor so
        /// the minimap stays self-contained. `Theme.background`
        /// etc. already store the literals as `Int` (0xFFFFFF), so
        /// the signature matches without the caller having to cast.
        private func sciColor(rgb: Int) -> Int {
            let r = (rgb >> 16) & 0xFF
            let g = (rgb >>  8) & 0xFF
            let b =  rgb        & 0xFF
            return (b << 16) | (g << 8) | r
        }
    }
}
