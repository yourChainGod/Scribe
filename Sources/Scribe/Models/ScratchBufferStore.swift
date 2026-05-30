//
//  ScratchBufferStore.swift
//  Phase 69 — dirty-buffer snapshotting on disk so a hard-kill /
//  crash / power loss doesn't lose unsaved text. Per-document
//  scratch files live under
//    ~/Library/Application Support/Scribe/scratch/<uuid>.txt
//  plus an index.json that records enough metadata to re-open each
//  entry on the next launch.
//
//  NOT an auto-save to the user's original file — ⌘S remains the
//  only thing that mutates the user's document. The scratch store
//  only answers "if the app died mid-edit, here is what the user
//  had typed". Saving the original file, or closing the tab while
//  discarding changes, drops the scratch entry immediately.
//

import Foundation

/// One scratch entry. Codable so the index round-trips as JSON.
/// `contentLength` is checked against the actual file size on
/// restore — mismatches mean the snapshot was torn mid-write (app
/// died between the text payload write and the index refresh) and
/// isn't safe to restore.
struct ScratchEntry: Codable, Sendable, Identifiable, Equatable {
    /// Document.id at capture time. Used as the scratch filename so
    /// a relaunched workspace can match the entry back to its tab
    /// if Session Restore has already re-opened the path.
    let id: UUID
    /// nil ⇒ Untitled at capture time. Non-nil paths are always the
    /// `standardizedFileURL.path` form for consistent comparison
    /// with Workspace's session restore bookkeeping.
    let originalPath: String?
    /// Tab title at capture time — shown in the recovery sheet when
    /// `originalPath` is nil so the user has something to identify
    /// the Untitled entry by.
    let title: String
    /// TextEncoding rawValue — re-applied when the doc is recreated.
    let encoding: String
    /// LineEnding rawValue — re-applied likewise. Purely metadata;
    /// the scratch text itself is always stored as-is.
    let lineEnding: String
    /// mtime of the on-disk file at capture time. Crash recovery
    /// compares this with the current mtime to flag "the user's
    /// file was also modified externally after the scratch was
    /// taken" so the user can make an informed choice.
    let diskMTime: Date?
    /// Size of the on-disk file at capture time. Used in tandem
    /// with diskMTime for the "external change after scratch"
    /// detector — some editors touch mtime without changing bytes
    /// and vice-versa, so we need both signals.
    let diskSize: Int?
    /// UTF-8 byte count of the scratch payload. Verified against
    /// the actual `<uuid>.txt` size on restore; mismatches are
    /// treated as corrupt (torn write) and silently skipped.
    let contentLength: Int
    /// When this snapshot was written. Drives both the relative
    /// time label in the recovery sheet ("2 minutes ago") and the
    /// retention sweep that prunes abandoned scratches.
    let savedAt: Date
}

/// Persistent dirty-buffer store. Single instance per workspace,
/// lives as long as the app. Writes are atomic (text payload and
/// index file each flip via `.atomic`), so a crash between two
/// writes at worst drops the most recent debounce window.
@MainActor
final class ScratchBufferStore: ObservableObject {

    /// Published catalogue of live scratch entries. Settings and
    /// the recovery sheet observe this; internal writers update in
    /// place so SwiftUI sees a single coherent state transition.
    @Published private(set) var entries: [ScratchEntry] = []

    /// Root directory. Injectable for tests so we can point at a
    /// tmp dir without touching the real Application Support tree.
    /// `nil` ⇒ persistence disabled (sandbox misconfig, read-only
    /// home) — every mutating call becomes a no-op.
    let root: URL?
    private let indexURL: URL?
    private let now: @Sendable () -> Date

    /// Phase 75 — invoked once per session when scratch writes have
    /// failed `maxConsecutiveFailures` times in a row (disk full,
    /// permission denied, read-only home). Lets the UI layer warn the
    /// user that crash recovery has silently stopped protecting their
    /// unsaved work; the store itself stays UI-agnostic.
    var onPersistentFailure: (@MainActor () -> Void)?

    /// Consecutive `record` write failures, reset to 0 on the first
    /// success. Crossing `maxConsecutiveFailures` fires
    /// `onPersistentFailure` exactly once per session.
    private let maxConsecutiveFailures: Int
    private var consecutiveFailures = 0
    private var didReportPersistentFailure = false

    init(root: URL? = ScratchBufferStore.defaultRoot(),
         now: @escaping @Sendable () -> Date = { Date() },
         maxConsecutiveFailures: Int = 3) {
        self.root = root
        self.indexURL = root?.appendingPathComponent("index.json",
                                                     isDirectory: false)
        self.now = now
        self.maxConsecutiveFailures = max(1, maxConsecutiveFailures)
        self.entries = Self.loadIndex(from: indexURL)
    }

    // MARK: - Public API

    /// Persist `text` as the scratch payload for `id`. Creates a
    /// new index entry if absent, otherwise updates the existing
    /// one in-place. Silent on failure so a transient IO hiccup
    /// doesn't surface to the user mid-typing; worst case a crash
    /// loses a single debounce window of work (~3 seconds under
    /// the default policy).
    ///
    /// Write order is deliberate: the text payload lands first so
    /// a crash between the two writes leaves a scratch file that
    /// the old index's `contentLength` mismatch will flag as
    /// corrupt — safer than having the index point at a payload
    /// that was never flushed.
    func record(id: UUID,
                text: String,
                originalPath: String?,
                title: String,
                encoding: String,
                lineEnding: String,
                diskMTime: Date?,
                diskSize: Int?) {
        guard let root else { return }
        let entry = ScratchEntry(
            id: id,
            originalPath: originalPath,
            title: title,
            encoding: encoding,
            lineEnding: lineEnding,
            diskMTime: diskMTime,
            diskSize: diskSize,
            contentLength: text.utf8.count,
            savedAt: now())

        let textURL = root.appendingPathComponent("\(id.uuidString).txt",
                                                  isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            let data = text.data(using: .utf8) ?? Data()
            try data.write(to: textURL, options: [.atomic])
        } catch {
            noteWriteFailure()
            return
        }

        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        if persistIndex() {
            noteWriteSuccess()
        } else {
            noteWriteFailure()
        }
    }

    /// Remove the scratch payload + index entry for `id`. Called on
    /// successful save, and on tab close when the user picked
    /// "Discard changes". Idempotent: unknown `id` is a no-op.
    func drop(id: UUID) {
        guard let root else {
            entries.removeAll { $0.id == id }
            return
        }
        let textURL = root.appendingPathComponent("\(id.uuidString).txt",
                                                  isDirectory: false)
        try? FileManager.default.removeItem(at: textURL)
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before {
            persistIndex()
        }
    }

    /// Wipe every scratch file and the index. Used by the
    /// "Discard All" button in the crash-recovery sheet and by the
    /// Settings → Storage → Clear Scratch button.
    func clearAll() {
        guard let root else {
            entries.removeAll()
            return
        }
        for entry in entries {
            let url = root.appendingPathComponent("\(entry.id.uuidString).txt",
                                                   isDirectory: false)
            try? FileManager.default.removeItem(at: url)
        }
        entries.removeAll()
        if let indexURL {
            try? FileManager.default.removeItem(at: indexURL)
        }
    }

    /// Read the persisted text for a scratch entry. Returns `nil`
    /// when the file is missing or its byte count doesn't match
    /// the metadata — either case means the snapshot was torn
    /// mid-write and isn't safe to restore. Does NOT consume the
    /// entry; callers call `drop(id:)` after a successful apply.
    func readText(for id: UUID) -> String? {
        guard let root,
              let entry = entries.first(where: { $0.id == id }) else { return nil }
        let textURL = root.appendingPathComponent("\(id.uuidString).txt",
                                                  isDirectory: false)
        guard let data = try? Data(contentsOf: textURL),
              data.count == entry.contentLength,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// Prune entries older than `retentionDays`. Callers pull the
    /// value from EditorPreferences; `0` disables the sweep. Runs
    /// once per launch from ScribeApp so a user who tweaks the
    /// knob sees the effect on the next start rather than
    /// mid-session.
    func pruneExpired(retentionDays: Int) {
        guard retentionDays > 0 else { return }
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        let stale = entries.filter { $0.savedAt < cutoff }
        for entry in stale {
            drop(id: entry.id)
        }
    }

    /// Phase 75 — delete `<uuid>.txt` payloads on disk that no index
    /// entry points at. `record` writes the text payload *before*
    /// `persistIndex`, so a crash in that window — for a brand-new id
    /// the index never knew about — strands an orphan file that the
    /// index-driven cleanup paths (drop / clearAll / pruneExpired) can
    /// never reclaim, accumulating without bound across repeated
    /// crashes. Run once per launch from ScribeApp. Only `.txt`
    /// payloads are swept; index.json and anything else are left alone.
    func reconcileOrphans() {
        guard let root,
              let names = try? FileManager.default.contentsOfDirectory(
                atPath: root.path) else { return }
        let live = Set(entries.map { "\($0.id.uuidString).txt" })
        for name in names where name.hasSuffix(".txt") && !live.contains(name) {
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent(name, isDirectory: false))
        }
    }

    // MARK: - Storage plumbing

    /// `~/Library/Application Support/Scribe/scratch/` — shares the
    /// top-level `Scribe` directory with clipboard-history.json and
    /// any future scribe-owned state so `rm -rf …/Scribe` wipes
    /// every piece of Scribe state in one gesture. Returns nil
    /// when the URL can't be resolved (sandbox misconfig, read-
    /// only home); the caller silently falls back to no-op.
    nonisolated static func defaultRoot() -> URL? {
        guard let root = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true) else { return nil }
        return root
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("scratch", isDirectory: true)
    }

    /// Decode the index. Returns `[]` on every error class (file
    /// absent, JSON corrupt, schema evolution) — matching the
    /// defensive stance in ClipboardHistoryStore / SnippetCatalog.
    /// Non-isolated because we call it during init before `self`
    /// is fully available.
    nonisolated static func loadIndex(from url: URL?) -> [ScratchEntry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ScratchEntry].self, from: data)) ?? []
    }

    @discardableResult
    private func persistIndex() -> Bool {
        guard let indexURL else { return true }
        do {
            try FileManager.default.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: indexURL, options: [.atomic])
            return true
        } catch {
            // Silent at the call site; a failed index write means the
            // next launch sees an older (or missing) catalogue — we'd
            // rather under-restore than over-restore. `record` folds
            // this into the consecutive-failure tally so a *persistent*
            // failure (disk full / read-only home) still surfaces a
            // one-shot warning via `onPersistentFailure`.
            return false
        }
    }

    /// Phase 75 — write-failure tally feeding `onPersistentFailure`.
    /// A single transient hiccup stays silent (the original Phase 69
    /// contract); only a sustained streak — the disk-full / read-only
    /// signature — trips the one-shot warning.
    private func noteWriteFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= maxConsecutiveFailures,
           !didReportPersistentFailure {
            didReportPersistentFailure = true
            onPersistentFailure?()
        }
    }

    private func noteWriteSuccess() {
        consecutiveFailures = 0
    }
}
