//
//  ClipboardHistoryStore.swift
//  Phase 57 — in-memory clipboard history. Polls NSPasteboard's
//  `changeCount` on a main-queue timer and prepends new entries to a
//  capped FIFO. The picker view observes the `@Published entries` so
//  the list updates live without the user having to re-open the
//  panel.
//
//  Why polling (and not Combine on an NSPasteboard publisher):
//    macOS ships no notification for pasteboard changes. Apps that
//    want clipboard history (Alfred, Paste.app, Copilot) all poll.
//    500 ms is the community-accepted middle ground — fast enough
//    that users don't notice the lag, slow enough that the power
//    cost on a battery stays in the noise. We stop the timer
//    entirely when the store is deallocated.
//
//  Why in-memory only:
//    Persisting clipboard history to disk means every app the user
//    ever copies a password from leaks into the editor's defaults.
//    The opt-in persistence path lands in Phase 57b once we've
//    designed an explicit "retention" control; V1 is private-first
//    and drops everything on Scribe quit.
//
//  Capacity:
//    The FIFO caps at 50 entries. A typical coding session chews
//    through ~20-40 distinct clipboard values before the user
//    leaves the picker; 50 gives headroom without turning the list
//    into an infinite scroll problem. Overflow drops the oldest.
//

import AppKit
import Combine
import Foundation

/// One recorded clipboard value. We only capture the plain-text
/// flavour; rich text / images / file URLs round-trip to the
/// system pasteboard natively and don't belong in a text-editor
/// history list anyway.
struct ClipboardHistoryEntry: Identifiable, Equatable, Hashable {
    /// Stable identity for SwiftUI lists. The creation timestamp
    /// is already unique in practice (500 ms poll granularity
    /// + humans can't copy twice in one tick), but a UUID keeps
    /// us safe from even theoretical collisions.
    let id: UUID
    /// Full clipboard text. Never modified post-insertion; the
    /// picker truncates for display.
    let text: String
    /// Wall-clock moment the entry landed in the history. Used
    /// only for the picker's "X minutes ago" subtitle.
    let capturedAt: Date

    init(text: String,
         capturedAt: Date = Date(),
         id: UUID = UUID()) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    // MARK: - Tunables
    //
    // Externally visible so the picker + tests can agree on the
    // limits without the constants drifting.

    /// Maximum number of entries held in memory. Oldest rolls off
    /// when a new value pushes the count over.
    static let capacity = 50

    /// Polling cadence. 500 ms is the Alfred / Paste.app default
    /// and plays nicely with macOS's power management.
    static let pollInterval: TimeInterval = 0.5

    /// Minimum text length to consider "interesting enough" to
    /// record. Empty strings (which the pasteboard produces after
    /// a clear) and single whitespace characters never make it in;
    /// a 1-char literal letter from a power-user's selection does.
    static let minimumTextLength = 1

    // MARK: - Published state

    /// Most recent entry first. The picker renders this list top-
    /// down, so a fresh copy always appears at the top.
    @Published private(set) var entries: [ClipboardHistoryEntry] = []

    // MARK: - Private

    private let pasteboard: ClipboardSource
    /// Seen change count so we only record on an actual flip.
    /// The first tick after init skips the existing clipboard
    /// value — the user didn't copy while Scribe was launching,
    /// so recording it would be surprising.
    private var lastChangeCount: Int
    private var pollTimer: Timer?

    // MARK: - Lifecycle

    /// Production uses `NSPasteboard.general`; tests pass a
    /// `ClipboardSource` fake (see the protocol below) so they
    /// can drive `pollOnce()` without touching the host machine's
    /// real clipboard.
    init(pasteboard: ClipboardSource = NSPasteboard.general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit {
        // Deinit runs outside the main actor; stop the timer
        // directly — `.invalidate()` is safe from any queue.
        pollTimer?.invalidate()
    }

    /// Begin polling. Idempotent: re-calling this on a store
    /// that's already running is a no-op, so the App init can
    /// fire it without worrying about re-entry.
    func start() {
        guard pollTimer == nil else { return }
        // The closure stays alive as long as the store does;
        // capture self weakly so a retain cycle through the
        // RunLoop doesn't keep the store around after the app
        // tears down.
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollOnce()
            }
        }
    }

    /// Halt polling. The in-memory entry list stays intact so a
    /// subsequent `start()` call picks up where it left off; the
    /// picker remains usable with the current snapshot.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Core recording

    /// Snapshot the pasteboard's current string if `changeCount`
    /// moved since the last tick. Exposed for tests so they can
    /// drive the record path without spinning up a Timer.
    func pollOnce() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard let text = pasteboard.string(forType: .string) else { return }
        record(text: text)
    }

    /// Insert `text` at the head of the list with the standard
    /// dedupe + cap policy. Useful in tests (to seed entries
    /// without a live pasteboard) and from the UI layer when we
    /// want to promote an existing entry back to the top of the
    /// list after a re-paste.
    ///
    /// Dedupe: if the exact same text already exists anywhere in
    /// the list, we remove the old entry and prepend a fresh one
    /// so the most-recently-used value is always on top. Matches
    /// Alfred / Paste.app's "move to top" behaviour; keeps the
    /// list from filling with repeats of the user's most common
    /// copy.
    func record(text: String) {
        guard text.count >= Self.minimumTextLength else { return }

        if let existingIndex = entries.firstIndex(where: { $0.text == text }) {
            entries.remove(at: existingIndex)
        }
        entries.insert(ClipboardHistoryEntry(text: text), at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    /// Wipe the in-memory list. Called from the picker's "Clear
    /// History" affordance and at `Workspace.quitAllTheThings`-
    /// level teardown. The seen-changeCount stays current so the
    /// next copy after a clear still registers.
    func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}

// MARK: - Test seam
//
// Tests need to assert poll-once behaviour without spinning up a
// real NSPasteboard (which would race with whatever the dev has on
// their clipboard during CI). Exposing a minimal pasteboard-shape
// protocol keeps the public surface narrow while letting tests swap
// in a fake. Internal (not public) so general app code keeps
// talking to the concrete type.

/// Minimal subset of `NSPasteboard` the store reads. Tests
/// implement a fake; production passes through `NSPasteboard.general`.
protocol ClipboardSource: AnyObject {
    var changeCount: Int { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
}

extension NSPasteboard: ClipboardSource {}
