//
//  ClipboardHistoryController.swift
//  Phase 57 — drives the ⌥⌘V clipboard-history picker. Same shape as
//  SnippetController: wraps each `ClipboardHistoryEntry` as a
//  `ScribeCommand` so the existing CommandPalette UI (fuzzy match,
//  keyboard nav, dismiss-on-resign-key) renders the list verbatim.
//
//  Why a wrapper, not a brand-new picker:
//    The palette already nails every micro-interaction we'd otherwise
//    rebuild by hand (Esc dismiss, ↑↓ nav, Return commit, focus
//    on type). Wrapping clipboard entries as commands inherits all
//    of it for free; the only delta vs. SnippetController is what the
//    perform block does — write into `NSPasteboard.general`, then
//    forward an AppKit `paste:` action so the active responder
//    (Scintilla, a text field, anything) handles the paste through
//    its normal route.
//
//  Why we don't bypass the system pasteboard:
//    Calling `paste:` (instead of poking Scintilla directly) means
//    every macOS responder along the chain — Scintilla view, NSText
//    field, web view input boxes inside the markdown preview, etc.
//    — gets the standard "incoming clipboard" UX. Undo, autocomplete,
//    smart-quote substitution, and the multi-cursor multi-paste path
//    (Phase 20) all keep working without a special case.
//

import AppKit
import Foundation

@MainActor
final class ClipboardHistoryController {
    static let shared = ClipboardHistoryController()

    /// Private registry rebuilt every time the picker opens so the
    /// snapshot reflects the freshly-polled history. Long-lived
    /// because PaletteWindowController identifies the active palette
    /// by reference equality on the registry instance.
    private let registry = CommandRegistry()

    /// Toggle for menu / palette / shortcut bindings. Same registry-
    /// equality semantics as `PaletteWindowController.toggle(...)`:
    /// pressing ⌥⌘V again while the picker is up closes it.
    func toggle(store: ClipboardHistoryStore) {
        rebuild(store: store)
        PaletteWindowController.shared.toggle(
            registry: registry,
            placeholder: placeholder(for: store)
        )
    }

    /// Force-show variant for the Palette `view.openClipboardHistory`
    /// command (it needs the picker open even if the user already
    /// has it visible from elsewhere).
    func show(store: ClipboardHistoryStore) {
        rebuild(store: store)
        PaletteWindowController.shared.show(
            registry: registry,
            placeholder: placeholder(for: store)
        )
    }

    // MARK: - Internals

    private func rebuild(store: ClipboardHistoryStore) {
        // Empty history ⇒ a single hint command pointing the user
        // at the polling rationale. Keeps the panel useful (and
        // dismissible) on first launch when nobody's copied yet.
        guard !store.entries.isEmpty else {
            registry.commands = [
                ScribeCommand(
                    id: "clipboard.empty",
                    title: L10n.t("clipboard.picker.empty.title"),
                    subtitle: L10n.t("clipboard.picker.empty.subtitle"),
                    keywords: [],
                    perform: { /* no-op */ }
                )
            ]
            return
        }

        let now = Date()
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated

        let commands: [ScribeCommand] = store.entries.enumerated().map { idx, entry in
            // Subtitle: relative timestamp ("3m ago"). Cheap and
            // gives the user a recency cue without a tooltip.
            let timestamp = formatter.localizedString(for: entry.capturedAt, relativeTo: now)
            // Keywords: the entry's first 80 characters so fuzzy
            // search finds a copy by content. Truncated because
            // long entries (e.g. a 5 KB code paste) would balloon
            // the palette index for marginal recall benefit.
            let keywords: [String] = [
                String(entry.text.prefix(80)),
                "clipboard",
                "history",
                "paste"
            ]
            return ScribeCommand(
                id: "clipboard:\(entry.id.uuidString)",
                title: previewLine(of: entry.text),
                subtitle: "\(timestamp) · #\(idx + 1)",
                keywords: keywords,
                perform: { [weak store] in
                    Self.commitPaste(of: entry.text, into: store)
                }
            )
        }
        registry.commands = commands
    }

    /// Re-paste path:
    ///   1. Promote `text` to the system pasteboard so the upcoming
    ///      `paste:` action sees it.
    ///   2. Promote the entry inside our own history so the most
    ///      recently chosen value bubbles to the top of the next
    ///      picker invocation. Without this, `Cmd+V` paths and
    ///      ⌥⌘V paths would diverge in their notion of "most
    ///      recent".
    ///   3. Fire `paste:` through the responder chain. The active
    ///      Scintilla view (or any other text-input responder) will
    ///      take it from there. We deliberately keep `to: nil` so
    ///      the chain finds the first responder for us; hard-wiring
    ///      to the editor's Coordinator would skip text fields in
    ///      sheets / find bar / sidebar.
    private static func commitPaste(of text: String,
                                    into store: ClipboardHistoryStore?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        store?.record(text: text)
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
    }

    // MARK: - Placeholder + preview helpers

    private func placeholder(for store: ClipboardHistoryStore) -> String {
        if store.entries.isEmpty {
            return L10n.t("clipboard.picker.placeholder.empty")
        }
        return String(format: L10n.t("clipboard.picker.placeholder"),
                      NSNumber(value: store.entries.count))
    }

    /// Reduce a possibly-multiline entry to a single readable line
    /// for the picker title. We strip leading whitespace so an
    /// indented code block doesn't show as a wall of empty space,
    /// then collapse trailing whitespace + tag the multi-line
    /// hint so the user knows there's more to the value.
    private func previewLine(of text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let firstNonEmpty = lines.first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) ?? lines.first ?? ""
        let trimmed = firstNonEmpty.trimmingCharacters(in: .whitespaces)
        let head = trimmed.count > 120
            ? String(trimmed.prefix(120)) + "…"
            : trimmed
        let extraLines = lines.count - 1
        if extraLines > 0 {
            return "\(head) ↵ +\(extraLines) more"
        }
        return head
    }
}
