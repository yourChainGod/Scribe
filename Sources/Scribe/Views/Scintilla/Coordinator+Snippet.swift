//
//  Coordinator+Snippet.swift
//  Phase 63 — runtime integration for snippet placeholders. Picks
//  up `FindState.Command.insertSnippet(body)`, parses it through
//  `SnippetParser`, inserts the resulting plain text once at the
//  caret, and (when the snippet has placeholders) installs a
//  `SnippetSession` so Tab cycles between `${1}`, `${2}`, … `$0`.
//
//  Mechanics
//
//    1. Insertion is a single SCI_INSERTTEXT call wrapped in a
//       BEGINUNDOACTION group, so ⌘Z reverts the entire snippet
//       expansion as one operation.
//    2. The session stores byte ranges; SCN_MODIFIED is forwarded
//       into `apply(modificationAt:length:)` so each typed char
//       inside the active stop grows the range, and edits before
//       the snippet shift everything right uniformly.
//    3. A local NSEvent monitor catches Tab / ⇧Tab / Esc *only*
//       while the session is alive — Tab stops cycling the
//       moment the user moves past `$0`, so the editor's normal
//       Tab behaviour returns immediately.
//    4. The active stop is highlighted via Scintilla indicator
//       slot `SCIND.SNIPPET` (style INDIC_ROUNDBOX, theme-tinted)
//       so the user can see which placeholder is live without
//       having to follow the caret.
//
//  Multi-cursor caveat
//    With more than one caret active the snippet body is dropped
//    onto every caret as plain text (current Phase 33 behaviour);
//    no session is opened. Per-caret sessions are an obvious v2
//    extension once we have a way to keep them aligned.
//

import AppKit
import Combine
import Foundation
import Scintilla

extension ScintillaCodeEditor.Coordinator {

    // MARK: - Public entry point

    /// Phase 63 — replacement for the old "drop body verbatim" path
    /// in the `.insertSnippet(body)` dispatcher arm. Parses the
    /// body, inserts plain text at the caret, and (when the body
    /// has navigable placeholders) opens a session.
    func beginSnippetSession(body: String, in view: ScintillaView) {
        // End any prior session before opening a new one — nested
        // snippet expansion isn't supported in v1.
        endSnippetSession(in: view)

        // Multi-caret? Fall back to the unsessioned insertion path
        // so every caret still receives the body (matches the
        // pre-63 behaviour). The user can switch to a single
        // caret and re-trigger the snippet to get placeholder
        // navigation.
        let selectionCount = Int(view.message(SCI.GETSELECTIONS))
        if selectionCount > 1 {
            insertAtCarets(body, in: view)
            return
        }

        let parsed = SnippetParser.parse(body)
        // Insert the plainText as one undoable group. We always
        // do this — even snippets without placeholders — so the
        // dispatch path stays uniform between Phase 33's "static
        // body" snippets and Phase 63's templated ones.
        let caret = Int(view.message(SCI.GETCURRENTPOS))
        view.message(SCI.BEGINUNDOACTION)
        let bytes = Array(parsed.plainText.utf8) + [0]
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            view.message(SCI.INSERTTEXT,
                         wParam: UInt(bitPattern: caret),
                         lParam: Int(bitPattern: base))
        }
        view.message(SCI.ENDUNDOACTION)

        // Body had only the synthetic `$0` → no session, just
        // park the caret at the end of the inserted text and bail.
        guard let session = SnippetSession.make(parsed: parsed,
                                                insertedAt: caret) else {
            let endPos = caret + parsed.plainText.utf8.count
            view.message(SCI.SETSEL,
                         wParam: UInt(bitPattern: endPos),
                         lParam: endPos)
            view.message(SCI.SCROLLCARET)
            return
        }

        snippetSession = session
        // Re-tint the indicator to the *current* theme on every
        // session open. The slot was already configured at view
        // attach time (see `configureSnippetIndicator(in:)` called
        // from `makeNSView`), but the brace-light colour drives
        // our tint and changes with the theme — calling here
        // means a session opened right after a light↔dark flip
        // never paints with the previous theme's accent.
        configureSnippetIndicator(in: view)
        repaintSnippetIndicators(in: view)
        focusCurrentSnippetStop(in: view)
        installSnippetKeyMonitor()
    }

    /// SCN_MODIFIED dispatch — keep the session's byte ranges in
    /// sync with the user's edits. No-op when no session is live.
    /// Called from the main `notification(_:)` switch in
    /// ScintillaCodeEditor.
    func applySnippetSessionModification(position: Int,
                                         length: Int,
                                         modificationType: Int32,
                                         in view: ScintillaView) {
        guard var session = snippetSession else { return }
        let isInsert = (modificationType & SC_MOD.INSERT_TEXT) != 0
        let isDelete = (modificationType & SC_MOD.DELETE_TEXT) != 0
        guard isInsert || isDelete else { return }
        let signed = isInsert ? length : -length
        session.apply(modificationAt: position, length: signed)
        snippetSession = session
        // After a modification, repaint the indicator so the
        // caret-following highlight reflects the new live range.
        repaintSnippetIndicators(in: view)
    }

    /// Tab → advance to the next stop. Routed through here from
    /// the local NSEvent monitor; ⇧Tab routes to `retreat`. Both
    /// no-op cleanly when no session is active so the monitor's
    /// "did we consume the event?" check is a single nil-test.
    @discardableResult
    func advanceSnippetSession(in view: ScintillaView) -> Bool {
        guard var session = snippetSession else { return false }
        if !session.advance() {
            // We were already on (or past) the last stop. End the
            // session and let Tab fall through to its normal
            // (insert-tab / indent) behaviour next time.
            endSnippetSession(in: view)
            return false
        }
        snippetSession = session
        focusCurrentSnippetStop(in: view)
        repaintSnippetIndicators(in: view)
        // If we advanced *onto* the terminal `$0`, that's still a
        // valid focused stop for one round (the user can press
        // Esc to cancel, type final text, etc.) — we end the
        // session on the next Tab rather than immediately, which
        // matches Notepad++ / VSCode behaviour.
        return true
    }

    @discardableResult
    func retreatSnippetSession(in view: ScintillaView) -> Bool {
        guard var session = snippetSession else { return false }
        guard session.retreat() else { return false }
        snippetSession = session
        focusCurrentSnippetStop(in: view)
        repaintSnippetIndicators(in: view)
        return true
    }

    /// End the active session. Idempotent — safe to call from
    /// "did the user just navigate away?" guards without
    /// double-checking nil first.
    func endSnippetSession(in view: ScintillaView?) {
        guard snippetSession != nil else { return }
        snippetSession = nil
        if let view {
            clearSnippetIndicators(in: view)
        }
        removeSnippetKeyMonitor()
    }

    // MARK: - Internals

    /// Move the selection to the current stop's range. Zero-width
    /// stops collapse to a caret; non-zero stops select the
    /// default text so typing replaces it (Scintilla's standard
    /// type-replaces-selection behaviour).
    private func focusCurrentSnippetStop(in view: ScintillaView) {
        guard let stop = snippetSession?.current else { return }
        view.message(SCI.SETSEL,
                     wParam: UInt(bitPattern: stop.start),
                     lParam: stop.end)
        view.message(SCI.SCROLLCARET)
    }

    /// One-time / theme-driven configuration for indicator slot
    /// `SCIND.SNIPPET`. Called at view attach time alongside the
    /// match / colour-swatch indicator setup, and again from
    /// `beginSnippetSession` so a theme flip while the user
    /// expanded a new snippet still picks up the fresh tint.
    /// Module-internal so `makeNSView` can call it.
    func configureSnippetIndicator(in view: ScintillaView) {
        let slot = SCIND.SNIPPET
        view.message(SCI.INDICSETSTYLE,
                     wParam: slot,
                     lParam: SCIND.ROUNDBOX)
        view.message(SCI.INDICSETALPHA,
                     wParam: slot,
                     lParam: 60)
        view.message(SCI.INDICSETUNDER,
                     wParam: slot,
                     lParam: 1)        // draw under text so the chars stay legible
        // Tint follows the editor's accent colour so the highlight
        // reads as "selection-ish" without colliding with real
        // selection (which uses the system selection colour).
        let tint = bracketHighlightColorBGR()
        view.message(SCI.INDICSETFORE,
                     wParam: slot,
                     lParam: Int(tint))
    }

    /// Repaint the indicator over every live stop. The current
    /// stop gets the same fill as the others; the *real* visual
    /// "you are here" cue is the Scintilla selection that
    /// `focusCurrentSnippetStop` lays down. The indicator
    /// answers the related question "where will Tab take me
    /// next?".
    private func repaintSnippetIndicators(in view: ScintillaView) {
        clearSnippetIndicators(in: view)
        guard let session = snippetSession else { return }
        view.message(SCI.SETINDICCURRENT,
                     wParam: SCIND.SNIPPET,
                     lParam: 0)
        for stop in session.stops where stop.length > 0 {
            view.message(SCI.INDICFILLRANGE,
                         wParam: UInt(bitPattern: stop.start),
                         lParam: stop.length)
        }
    }

    private func clearSnippetIndicators(in view: ScintillaView) {
        view.message(SCI.SETINDICCURRENT,
                     wParam: SCIND.SNIPPET,
                     lParam: 0)
        let length = Int(view.message(SCI.GETLENGTH))
        view.message(SCI.INDICCLEARRANGE,
                     wParam: 0,
                     lParam: length)
    }

    /// Pick a tint for the placeholder indicator. We reuse the
    /// brace-highlight slot's foreground colour when the theme
    /// configures one, falling back to a system blue otherwise.
    /// Returned in BGR order — that's the byte order Scintilla's
    /// `INDICSETFORE` expects.
    private func bracketHighlightColorBGR() -> Int32 {
        let lParam = view?.message(SCI.STYLEGETFORE,
                                   wParam: UInt(SC.STYLE_BRACELIGHT)) ?? 0
        // STYLEGETFORE returns 0 when the slot hasn't been styled
        // yet (very new view, or theme not yet applied). Fall back
        // to a soft blue so the highlight still renders.
        if lParam != 0 {
            return Int32(truncatingIfNeeded: lParam)
        }
        // 0xRRGGBB → 0xBBGGRR. Soft blue (#3B82F6 in Tailwindish
        // terms) reads well against both light and dark themes.
        return 0x00F6823B
    }

    // MARK: - Local NSEvent monitor (Tab / ⇧Tab / Esc)

    private func installSnippetKeyMonitor() {
        guard snippetKeyMonitor == nil else { return }
        // AppKit's local monitor handler runs on the main thread
        // and is already implicitly `@MainActor` under Swift 6, so
        // we can read isolated state directly without an explicit
        // hop.
        snippetKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleSnippetKeyDown(event) ?? event
        }
    }

    func removeSnippetKeyMonitor() {
        if let monitor = snippetKeyMonitor {
            NSEvent.removeMonitor(monitor)
            snippetKeyMonitor = nil
        }
    }

    private func handleSnippetKeyDown(_ event: NSEvent) -> NSEvent? {
        // The monitor stays installed for the life of the session,
        // so we re-check liveness on every event in case something
        // else (focus loss, doc swap) has already torn it down.
        guard let view, snippetSession != nil else { return event }
        // Only intercept events targeting the editor's window — a
        // global monitor would otherwise swallow Tab in unrelated
        // panels (Quick Open, Find bar) while a session is open.
        guard event.window === view.window else { return event }
        // First-responder gate: Scintilla owns the editor; if the
        // user has tabbed into the find bar / palette / sidebar
        // we shouldn't steal Tab from them.
        if let firstResponder = view.window?.firstResponder,
           !(firstResponder === view || isDescendant(firstResponder,
                                                     of: view)) {
            return event
        }

        let keyCode = event.keyCode
        let shift = event.modifierFlags.contains(.shift)
        switch keyCode {
        case 48 /* Tab */:
            if shift {
                retreatSnippetSession(in: view)
            } else {
                advanceSnippetSession(in: view)
            }
            return nil   // swallow the event
        case 53 /* Escape */:
            endSnippetSession(in: view)
            return nil
        default:
            return event
        }
    }

    /// Helper for the firstResponder gate: ScintillaView nests an
    /// inner SCIContentView that owns the actual key focus, so a
    /// strict `===` check would fail even when the editor is the
    /// active responder. We accept any descendant of `view`.
    private func isDescendant(_ responder: NSResponder,
                              of view: NSView) -> Bool {
        var node: NSResponder? = responder
        while let n = node {
            if let v = n as? NSView, v.isDescendant(of: view) {
                return true
            }
            node = n.nextResponder
        }
        return false
    }
}

// MARK: - Coordinator stored state

/// Paired storage for the snippet feature. The properties live on
/// `Coordinator` (declared in `ScintillaCodeEditor.swift`) but the
/// feature needs them addressable here. We keep them on a private
/// extension-via-static-objc-association for the tiny amount of
/// state involved (one optional + one monitor handle), which lets
/// the Coordinator file stay focused on cross-feature plumbing.
extension ScintillaCodeEditor.Coordinator {
    /// Active session, or nil when there's no in-flight snippet.
    /// Stored via objc associated objects to avoid bloating the
    /// Coordinator declaration with feature-specific properties.
    var snippetSession: SnippetSession? {
        get { snippetSessionStorage.value }
        set { snippetSessionStorage.value = newValue }
    }

    /// Local NSEvent monitor handle for Tab / ⇧Tab / Esc.
    fileprivate var snippetKeyMonitor: Any? {
        get { snippetMonitorStorage.value }
        set { snippetMonitorStorage.value = newValue }
    }

    private var snippetSessionStorage: SnippetStorageBox<SnippetSession?> {
        if let existing = objc_getAssociatedObject(self, &snippetSessionKey)
            as? SnippetStorageBox<SnippetSession?> {
            return existing
        }
        let box = SnippetStorageBox<SnippetSession?>(value: nil)
        objc_setAssociatedObject(self,
                                 &snippetSessionKey,
                                 box,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return box
    }

    private var snippetMonitorStorage: SnippetStorageBox<Any?> {
        if let existing = objc_getAssociatedObject(self, &snippetMonitorKey)
            as? SnippetStorageBox<Any?> {
            return existing
        }
        let box = SnippetStorageBox<Any?>(value: nil)
        objc_setAssociatedObject(self,
                                 &snippetMonitorKey,
                                 box,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return box
    }
}

/// Reference-typed wrapper so associated-object storage round-trips
/// optionals cleanly (Swift's `Any?`-bridged AnyObject silently
/// turns `nil` into a non-optional NSNull, which would defeat the
/// "is the session nil?" check).
private final class SnippetStorageBox<T> {
    var value: T
    init(value: T) { self.value = value }
}

private nonisolated(unsafe) var snippetSessionKey: UInt8 = 0
private nonisolated(unsafe) var snippetMonitorKey: UInt8 = 0

// MARK: - SCN_MODIFIED bit constants

/// Subset of `SC_MOD_*` flags we test against the SCN_MODIFIED
/// modificationType bitmask. Mirroring them here (rather than
/// pulling Scintilla.h into the build) keeps the header surface
/// minimal — the snippet feature only cares about insert / delete.
enum SC_MOD {
    static let INSERT_TEXT: Int32 = 0x1
    static let DELETE_TEXT: Int32 = 0x2
}

// MARK: - Indicator slot

extension SCIND {
    /// Phase 63 — indicator slot for the active snippet placeholder.
    /// Indicators 0 and 1 are taken by find matches and color
    /// swatches respectively; slot 2 is the next free user-available
    /// index.
    static let SNIPPET: UInt = 2
}
