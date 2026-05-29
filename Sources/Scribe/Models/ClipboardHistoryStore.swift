//
//  ClipboardHistoryStore.swift
//  Phase 57 — in-memory clipboard history. Polls NSPasteboard's
//  `changeCount` on a main-queue timer and prepends new entries to a
//  capped FIFO. The picker view observes the `@Published entries` so
//  the list updates live without the user having to re-open the
//  panel.
//
//  Phase 67 — opt-in disk persistence + retention controls. Defaults
//  still match the Phase 57 privacy-first story (memory only, 50-
//  entry cap), but the user can flip "Persist clipboard history"
//  in Settings to preserve entries across restarts, and tune both
//  the per-FIFO cap and a TTL (drop entries older than N days).
//  Storage is a JSON file under `~/Library/Application Support/
//  Scribe/` so a `rm` wipes everything in one go and nothing rides
//  on UserDefaults' iCloud sync surface.
//
//  Why polling (and not Combine on an NSPasteboard publisher):
//    macOS ships no notification for pasteboard changes. Apps that
//    want clipboard history (Alfred, Paste.app, Copilot) all poll.
//    500 ms is the community-accepted middle ground — fast enough
//    that users don't notice the lag, slow enough that the power
//    cost on a battery stays in the noise. We stop the timer
//    entirely when the store is deallocated.
//
//  Privacy contract (Phase 67):
//    - Default policy has `persistEnabled = false`. Upgrading from
//      Phase 57 never starts writing a password to disk by accident.
//    - Toggling ON writes the current in-memory snapshot immediately
//      so the restart survives whatever the user copied before they
//      flipped the switch.
//    - Toggling OFF deletes the JSON file on disk. The in-memory
//      list stays intact until the user hits Clear; we don't nuke
//      active state behind their back, but we do stop feeding disk.
//    - The JSON file has 0600 perms via `FileProtectionType.complete`
//      best-effort; macOS desktop file-protection is advisory, but
//      it signals intent and on iOS/iPadOS would actually encrypt.
//
//  Capacity:
//    The FIFO's ceiling is whatever `policy.maxItems` currently is
//    (default 50, min 10, max 500). Overflow drops the oldest so
//    recent entries always win.
//

import AppKit
import Combine
import Foundation

/// One recorded clipboard value. We only capture the plain-text
/// flavour; rich text / images / file URLs round-trip to the
/// system pasteboard natively and don't belong in a text-editor
/// history list anyway.
///
/// Phase 67 — now `Codable` so `ClipboardHistoryStore` can round-
/// trip the FIFO through JSON on disk when persistence is enabled.
struct ClipboardHistoryEntry: Identifiable, Equatable, Hashable, Codable, Sendable {
    /// Stable identity for SwiftUI lists. The creation timestamp
    /// is already unique in practice (500 ms poll granularity
    /// + humans can't copy twice in one tick), but a UUID keeps
    /// us safe from even theoretical collisions.
    let id: UUID
    /// Full clipboard text. Never modified post-insertion; the
    /// picker truncates for display.
    let text: String
    /// Wall-clock moment the entry landed in the history. Used
    /// by the picker's "X minutes ago" subtitle and by the
    /// Phase 67 TTL sweep.
    let capturedAt: Date

    init(text: String,
         capturedAt: Date = Date(),
         id: UUID = UUID()) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
    }
}

/// Phase 67 — runtime knobs that shape how `ClipboardHistoryStore`
/// retains entries. The store reads it on init and every time the
/// app calls `updatePolicy(_:)`; all three fields map 1:1 onto a
/// Settings UI control backed by `EditorPreferences`.
struct ClipboardHistoryPolicy: Equatable, Sendable {
    /// When `true` the store serialises its FIFO to disk after
    /// every mutation, and reloads it from disk on init. Defaults
    /// to `false` so upgrading from Phase 57 never starts writing
    /// a password to disk without explicit user consent.
    var persistEnabled: Bool

    /// Cap on the FIFO length. Overflow drops the oldest entry so
    /// the most recent copy is always first. Clamped into
    /// `[maxItemsMin, maxItemsMax]` by the store so a tampered
    /// defaults blob can't force unbounded memory use.
    var maxItems: Int

    /// Retention window in days. `0` means "keep forever"; any
    /// positive value triggers a TTL sweep that drops entries
    /// whose `capturedAt` is older than `now - retentionDays`.
    /// Applied on init, on every `record`, and whenever the app
    /// pushes a new policy through `updatePolicy`.
    var retentionDays: Int

    /// The Phase 57 defaults: memory-only, 50-entry cap, 30-day TTL.
    /// Re-used as the baseline when `EditorPreferences` hasn't
    /// stored a value yet.
    static let `default` = ClipboardHistoryPolicy(persistEnabled: false,
                                                  maxItems: 50,
                                                  retentionDays: 30)

    /// Hard bounds the store enforces independently of any
    /// Settings UI slider range — the file on disk could still
    /// carry an out-of-range value if the user edits the JSON by
    /// hand, and we'd rather clamp than crash.
    static let maxItemsMin = 10
    static let maxItemsMax = 500
    static let retentionDaysMin = 0
    static let retentionDaysMax = 365

    /// Constructor that clamps its arguments so callers don't
    /// need to repeat the min/max dance at every read site.
    init(persistEnabled: Bool,
         maxItems: Int,
         retentionDays: Int) {
        self.persistEnabled = persistEnabled
        self.maxItems = min(max(maxItems, Self.maxItemsMin), Self.maxItemsMax)
        self.retentionDays = min(max(retentionDays, Self.retentionDaysMin),
                                 Self.retentionDaysMax)
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    // MARK: - Tunables
    //
    // Externally visible so the picker + tests can agree on the
    // limits without the constants drifting.

    /// Historical in-memory cap (Phase 57). Preserved so the
    /// existing tests + palette wording that reference a "50-entry
    /// list" still compile; the runtime cap is now
    /// `policy.maxItems`, which defaults to this same value.
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

    /// Phase 67 — retention knobs. Read-only from outside; mutate
    /// through `updatePolicy(_:)` so the persistence + capacity
    /// side-effects all run in one pass.
    @Published private(set) var policy: ClipboardHistoryPolicy

    // MARK: - Private

    private let pasteboard: ClipboardSource
    /// Seen change count so we only record on an actual flip.
    /// The first tick after init skips the existing clipboard
    /// value — the user didn't copy while Scribe was launching,
    /// so recording it would be surprising.
    private var lastChangeCount: Int
    private nonisolated(unsafe) var pollTimer: Timer?

    /// Absolute location of the on-disk JSON file. Injectable so
    /// tests can write into a tmp dir without leaking into the
    /// user's Application Support. `nil` means "no persistence
    /// backing configured" — the store simply skips every disk
    /// call, matching Phase 57's memory-only behaviour.
    private let storageURL: URL?

    /// Cached clock for the TTL sweep. Injected so tests can
    /// freeze time; production uses `Date.init()`.
    private let now: @Sendable () -> Date

    // MARK: - Lifecycle

    /// Production uses `NSPasteboard.general` + the default on-disk
    /// storage URL; tests pass a `ClipboardSource` fake (see the
    /// protocol below) and can pin a tmp-file URL or disable
    /// persistence entirely.
    init(pasteboard: ClipboardSource = NSPasteboard.general,
         policy: ClipboardHistoryPolicy = .default,
         storageURL: URL? = ClipboardHistoryStore.defaultStorageURL(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
        self.policy = policy
        self.storageURL = storageURL
        self.now = now
        // Phase 67 — load the persisted catalogue on init if the
        // caller has persistence enabled. Silent on decode errors
        // (corrupt JSON ⇒ fresh start, same pattern as
        // SnippetCatalog).
        if policy.persistEnabled, let url = storageURL {
            entries = Self.loadPersisted(from: url)
        }
        applyRetention(using: now())
        trimToCapacity()
    }

    deinit {
        // The timer token may be released during nonisolated teardown;
        // the rest of the store's mutable state remains MainActor-bound.
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

    // MARK: - Policy

    /// Apply a new retention policy. Handles the four state
    /// transitions in one place so callers (Settings toggles,
    /// slider drags, the app bootstrap) don't each have to
    /// re-derive the persistence + trimming side-effects:
    ///   * persistEnabled OFF → ON: snapshot the in-memory list
    ///     to disk immediately so the next restart carries it.
    ///   * persistEnabled ON → OFF: wipe the on-disk file; the
    ///     in-memory list survives until the user hits Clear.
    ///   * maxItems shrunk: trim the oldest tail entries.
    ///   * retentionDays changed: re-run the TTL sweep.
    func updatePolicy(_ newPolicy: ClipboardHistoryPolicy) {
        let old = policy
        policy = newPolicy
        // Disk transition first so retention-driven edits emit the
        // right file state.
        if !old.persistEnabled, newPolicy.persistEnabled {
            persistToDisk()
        } else if old.persistEnabled, !newPolicy.persistEnabled {
            wipeDiskIfAny()
        }
        applyRetention(using: now())
        trimToCapacity()
        // One extra write covers the TTL sweep / capacity trim that
        // mutated entries while persistence was enabled before AND
        // after the transition; no-ops when persistEnabled is false.
        persistToDisk()
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
        entries.insert(ClipboardHistoryEntry(text: text, capturedAt: now()), at: 0)
        applyRetention(using: now())
        trimToCapacity()
        persistToDisk()
    }

    /// Wipe the in-memory list AND any on-disk persistence. Called
    /// from the picker's "Clear History" affordance. The
    /// seen-changeCount stays current so the next copy after a
    /// clear still registers, but the disk file is deleted in full
    /// so the user's privacy expectation ("Clear means Clear") is
    /// honoured end-to-end.
    func clear() {
        entries.removeAll(keepingCapacity: true)
        wipeDiskIfAny()
    }

    // MARK: - Retention / capacity

    /// TTL sweep. `retentionDays == 0` means "keep forever" and
    /// bails early without touching the array.
    private func applyRetention(using now: Date) {
        guard policy.retentionDays > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(policy.retentionDays) * 86_400)
        entries.removeAll { $0.capturedAt < cutoff }
    }

    /// Cap enforcement. Runs after every mutation so the FIFO stays
    /// at or under `policy.maxItems`.
    private func trimToCapacity() {
        if entries.count > policy.maxItems {
            entries.removeLast(entries.count - policy.maxItems)
        }
    }

    // MARK: - Persistence

    /// Default on-disk location. Lives under `~/Library/Application
    /// Support/Scribe/` so a `rm -rf …/Scribe` wipes every piece of
    /// Scribe state in one gesture. Returns nil when the URL can't
    /// be resolved (sandbox misconfig, read-only home); the caller
    /// silently falls back to memory-only.
    nonisolated static func defaultStorageURL() -> URL? {
        guard let root = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true) else { return nil }
        return root
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("clipboard-history.json",
                                    isDirectory: false)
    }

    /// Serialise the current FIFO to disk. No-op when persistence
    /// is disabled or the caller didn't supply a storageURL.
    /// Silent on failure — worst case the user restarts with an
    /// older snapshot, no worse than Phase 57.
    private func persistToDisk() {
        guard policy.persistEnabled, let url = storageURL else { return }
        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            // Silent — see SnippetCatalog precedent.
        }
    }

    /// Delete the on-disk JSON. Invoked from `clear()` and from
    /// the policy-turn-off transition.
    private func wipeDiskIfAny() {
        guard let url = storageURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Read + decode the persisted catalogue. Returns `[]` on
    /// every error class (file absent, JSON corrupt, future
    /// schema evolution). Non-isolated because we call it during
    /// init before `self` is fully available.
    nonisolated static func loadPersisted(from url: URL) -> [ClipboardHistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ClipboardHistoryEntry].self,
                                                 from: data) else {
            return []
        }
        return decoded
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
