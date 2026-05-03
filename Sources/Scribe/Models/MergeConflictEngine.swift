//
//  MergeConflictEngine.swift
//  Phase 68 — observes the active Document's text, runs the
//  conflict parser through a debounce, and publishes the result
//  for the editor overlay + the navigation menu items to consume.
//
//  Single-instance per Workspace — only the selected tab matters,
//  background tabs don't need their own scanner. Switching tabs
//  rebinds; closing the active tab unbinds and clears the list.
//

import Foundation
import Combine

@MainActor
final class MergeConflictEngine: ObservableObject {

    /// Latest list of conflicts in the bound document. Empty for
    /// "nothing bound" or "bound document has no markers". Editor
    /// overlay + navigation menu read this.
    @Published private(set) var conflicts: [MergeConflict] = []

    /// Identity of the currently-bound document. Lets observers
    /// gate "is this the doc I care about" without holding their
    /// own reference and racing GC.
    @Published private(set) var boundDocumentID: UUID?

    private var textSink: AnyCancellable?
    private weak var current: Document?

    /// Attach to `doc` (or detach when `nil`). Idempotent: calling
    /// twice with the same Document is a no-op so a tab-switch sink
    /// that re-runs on every emit doesn't churn the parser.
    ///
    /// Seeding behaviour: the first scan happens synchronously
    /// before this method returns so the overlay doesn't have to
    /// wait the debounce window for the first paint. Subsequent
    /// emits go through the debounce so a fast typing burst pays
    /// the parser cost at most once per quiet window.
    func bind(to doc: Document?) {
        if doc?.id == boundDocumentID { return }
        textSink = nil
        current = doc
        boundDocumentID = doc?.id
        guard let doc else {
            conflicts = []
            return
        }
        // Seed immediately so the overlay paints on the very first
        // tab-switch tick.
        conflicts = MergeConflictParser.parse(doc.text)
        textSink = doc.$text
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] newText in
                guard let self else { return }
                let parsed = MergeConflictParser.parse(newText)
                // Skip the @Published republish when the parse
                // result hasn't changed — saves SwiftUI rebuild
                // tax on documents that contain no markers and
                // get typed into in a tight loop.
                if parsed != self.conflicts {
                    self.conflicts = parsed
                }
            }
    }

    /// Force an immediate rescan of the currently-bound document.
    /// Used after the editor performs an in-place resolution: the
    /// Scintilla replaceTarget path mutates `doc.text` synchronously,
    /// but waiting for the debounce window would leave the overlay
    /// rendering already-resolved buttons for a beat. Calling this
    /// from the resolution path re-parses immediately so the just-
    /// patched conflict disappears in the same runloop turn.
    func refresh() {
        guard let doc = current else { return }
        conflicts = MergeConflictParser.parse(doc.text)
    }
}
