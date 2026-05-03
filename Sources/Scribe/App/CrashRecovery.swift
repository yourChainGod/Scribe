//
//  CrashRecovery.swift
//  Phase 69 — detect leftover scratch snapshots from a previous
//  session that never reached a save or a clean close, present a
//  non-blocking sheet so the user can pick which to restore, and
//  apply the chosen entries back into the Workspace.
//
//  Contract:
//   - `detectPending` runs synchronously at launch and produces
//     the prompt payload the SwiftUI sheet binds to. Returns `nil`
//     when no recovery is needed so the caller avoids presenting
//     an empty sheet.
//   - `apply` is called from the sheet's "Restore selected" button;
//     it replaces any Session-Restore placeholder for the same URL
//     (so the user doesn't end up with two tabs for the same file)
//     and drops every entry from the store — both restored and
//     skipped — so the next launch isn't prompted again for the
//     same set.
//   - `discardAll` is the sheet's "Discard" button: drops every
//     entry without applying them.
//

import Foundation

/// Payload for the recovery sheet. `Identifiable` so
/// `.sheet(item:)` can attach.
struct CrashRecoveryPrompt: Identifiable, Equatable {
    let id = UUID()
    let items: [CrashRecoveryItem]
}

/// One row in the recovery sheet. Mirrors `ScratchEntry` but
/// enriches it with a computed flag for "original file was
/// modified externally after this scratch was taken" so the UI
/// can warn the user.
struct CrashRecoveryItem: Identifiable, Equatable {
    /// Matches the underlying `ScratchEntry.id` — used when the
    /// user taps "Restore selected" to look the entry back up.
    let id: UUID
    /// Title at capture time (original filename, or Untitled-N).
    let title: String
    /// nil ⇒ the scratch was for an Untitled document.
    let originalPath: String?
    /// When the snapshot was last written. Drives the relative-
    /// time label in the sheet ("2 minutes ago").
    let savedAt: Date
    /// True when the original file's current mtime or size
    /// differs from what `ScratchEntry` captured — meaning the
    /// user (or another process) wrote to the file after the
    /// scratch was taken. The sheet surfaces a badge so the user
    /// knows picking "Restore" will revive an in-flight edit that
    /// conflicts with whatever's on disk now.
    let externalChanged: Bool
    /// True when `originalPath` points at a file that no longer
    /// exists on disk. Restored entries fall back to an Untitled
    /// document so the user doesn't lose the text.
    let originalMissing: Bool
}

enum CrashRecovery {

    /// Synchronously inspect the store and build a prompt payload.
    /// Returns `nil` when there's nothing to restore so callers
    /// can short-circuit without touching the UI layer.
    @MainActor
    static func detectPending(store: ScratchBufferStore) -> CrashRecoveryPrompt? {
        guard !store.entries.isEmpty else { return nil }
        let fm = FileManager.default
        var items: [CrashRecoveryItem] = []
        for entry in store.entries {
            var externalChanged = false
            var originalMissing = false
            if let path = entry.originalPath {
                if fm.fileExists(atPath: path) {
                    if let attrs = try? fm.attributesOfItem(atPath: path) {
                        let mtime = attrs[.modificationDate] as? Date
                        let size = (attrs[.size] as? NSNumber)?.intValue
                        if mtime != entry.diskMTime || size != entry.diskSize {
                            externalChanged = true
                        }
                    }
                } else {
                    originalMissing = true
                }
            }
            items.append(CrashRecoveryItem(
                id: entry.id,
                title: entry.title,
                originalPath: entry.originalPath,
                savedAt: entry.savedAt,
                externalChanged: externalChanged,
                originalMissing: originalMissing))
        }
        // Sort newest-first so the most recent work floats to the
        // top of the sheet — matches what users expect after a
        // crash mid-edit.
        items.sort { $0.savedAt > $1.savedAt }
        return CrashRecoveryPrompt(items: items)
    }

    /// Apply the user's chosen subset. Entries not in
    /// `selectedIDs` are dropped from the store without touching
    /// the workspace (they'll never prompt again).
    ///
    /// For each selected entry:
    ///   - If the scratch points at a URL and a Session-Restore
    ///     placeholder tab for that URL exists (`isLoading == true`),
    ///     replace the placeholder with a freshly-built Document
    ///     carrying the scratch text + `isDirty = true`. The
    ///     placeholder's background Task returns silently when it
    ///     can't find its UUID in `documents` anymore.
    ///   - If the URL is already a fully-loaded tab (e.g. session
    ///     restore completed before recovery ran), overwrite its
    ///     `text` in place and flag dirty. Preserves the tab's
    ///     existing view state (caret, scroll).
    ///   - If there's no matching tab, append a new Document with
    ///     the URL (or Untitled when the original file is gone).
    @MainActor
    static func apply(selectedIDs: Set<UUID>,
                      store: ScratchBufferStore,
                      workspace: Workspace) {
        // Snapshot entries before we start mutating the store so a
        // mid-loop `drop` can't trip the iteration.
        let snapshot = store.entries

        for entry in snapshot {
            guard selectedIDs.contains(entry.id) else {
                store.drop(id: entry.id)
                continue
            }
            guard let text = store.readText(for: entry.id) else {
                // Torn write — no payload to restore. Drop the
                // index entry so the user isn't nagged next time.
                store.drop(id: entry.id)
                continue
            }

            if let rawPath = entry.originalPath {
                let url = URL(fileURLWithPath: rawPath).standardizedFileURL
                let fileExists = FileManager.default.fileExists(atPath: url.path)

                if let placeholderIdx = workspace.documents.firstIndex(where: {
                    $0.url?.standardizedFileURL == url && $0.isLoading
                }) {
                    // Session-Restore placeholder — swap it out for
                    // the recovered doc. The loader Task will fail
                    // the `id` lookup and exit silently.
                    workspace.documents.remove(at: placeholderIdx)
                    let doc = Document(title: url.lastPathComponent,
                                       text: text,
                                       url: fileExists ? url : nil)
                    doc.isDirty = true
                    workspace.documents.insert(doc, at: placeholderIdx)
                    workspace.selectedID = doc.id
                } else if let existing = workspace.documents.first(where: {
                    $0.url?.standardizedFileURL == url
                }) {
                    // Already fully loaded — overwrite in place.
                    existing.text = text
                    existing.isDirty = true
                    workspace.selectedID = existing.id
                } else {
                    // No matching tab. Open a new one carrying the
                    // URL when the file is still around, Untitled
                    // otherwise so the user gets save-as prompted.
                    let doc = Document(
                        title: fileExists ? url.lastPathComponent : entry.title,
                        text: text,
                        url: fileExists ? url : nil)
                    doc.isDirty = true
                    workspace.documents.append(doc)
                    workspace.selectedID = doc.id
                }
            } else {
                // Untitled scratch — always a fresh Untitled tab.
                let doc = Document(title: entry.title, text: text)
                doc.isDirty = true
                workspace.documents.append(doc)
                workspace.selectedID = doc.id
            }

            // The restored Document has a brand-new UUID, so the
            // old scratch entry is orphaned no matter what. Drop it
            // and let the Workspace's per-doc sink write a fresh
            // scratch keyed by the new UUID on the next debounce.
            store.drop(id: entry.id)
        }
    }

    /// Drop every entry without touching the workspace. Used by
    /// the sheet's "Discard" button.
    @MainActor
    static func discardAll(store: ScratchBufferStore) {
        store.clearAll()
    }
}
