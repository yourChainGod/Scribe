//
//  SessionRestore.swift
//  Phase 67d — re-open the document tabs the user had loaded at
//  the last clean (or unclean) shutdown. Mirrors the Phase 27
//  `StartupAutoOpen` shape so ScribeApp's init reads as one
//  consistent dispatch chain:
//
//      let env = StartupEnvironment.current()
//      let ws  = Workspace(prefs:, openInitialUntitled: …)
//      StartupAutoOpen.apply(env, to: ws)
//      SessionRestore.apply(prefs: prefs, to: ws,
//                           skip: !env.autoOpenURLs.isEmpty)
//
//  Skipping rules — `apply` is a no-op when:
//    * The CLI / `SCRIBE_AUTO_OPEN` already gave us files; the
//      user's "this run" intent overrides what was open last
//      session.
//    * `prefs.sessionOpenFilePaths` is empty (no previous session,
//      or every tab was Untitled).
//    * Every persisted path has been deleted between sessions.
//
//  Otherwise it streams the persisted URL list through
//  `Workspace.openFile`, one file per `DispatchQueue.main.async`
//  hop so the SwiftUI view tree gets a chance to settle between
//  loads. The active selection (`prefs.sessionSelectedFilePath`)
//  is restored last so it isn't clobbered by each `openFile`'s
//  default "select the freshly-opened tab" behaviour.
//

import Foundation
import AppKit

@MainActor
enum SessionRestore {
    /// Filter the persisted path list down to URLs whose backing
    /// file still exists. Standardises both ends so a path that
    /// round-tripped through `~` expansion still matches.
    /// Pulled out of `apply` so `ScribeApp.init` can probe the same
    /// "is there anything to restore" answer when deciding whether
    /// to seed the default Untitled tab.
    static func usableRestorePaths(prefs: EditorPreferences) -> [URL] {
        let fm = FileManager.default
        return prefs.sessionOpenFilePaths.compactMap { raw -> URL? in
            let url = URL(fileURLWithPath: raw).standardizedFileURL
            return fm.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Apply a saved session to a freshly-constructed Workspace.
    /// Caller is responsible for skipping when the env / CLI
    /// already populated the workspace; we only check whether the
    /// pref blob carries anything worth restoring.
    static func apply(prefs: EditorPreferences,
                      to workspace: Workspace,
                      skip: Bool) {
        guard !skip else { return }
        let usable = usableRestorePaths(prefs: prefs)
        guard !usable.isEmpty else { return }

        // Defer to the next runloop turn so the WindowGroup has a
        // chance to materialise its NSWindow before we start
        // mutating @Published state — same precaution
        // `StartupAutoOpen.apply` takes for the SCRIBE_AUTO_OPEN
        // path. Without the hop, macOS 14+ / SwiftUI sometimes
        // skips the initial NSWindow creation entirely.
        // Capture the selection target *before* dispatching openFile,
        // because the openFile sinks will overwrite
        // prefs.sessionSelectedFilePath as each new tab gets
        // selected by Workspace's "select what I just opened"
        // default, leaving us no way to read the original choice
        // back at the end of the loop.
        let originalSelectedPath = prefs.sessionSelectedFilePath
        DispatchQueue.main.async {
            for url in usable {
                workspace.openFile(at: url)
            }
            // Restore the active tab last so the openFile loop's
            // implicit "select what we just appended" doesn't
            // win over the user's persisted choice. Falls back
            // to the first usable path when the recorded
            // selection is missing or no longer in the list (the
            // file was deleted, or the user closed it via the
            // tab strip after the snapshot).
            let restored = SessionRestore.selectionTarget(
                from: originalSelectedPath,
                in: usable)
            if let target = restored,
               let doc = workspace.documents.first(where: {
                   $0.url?.standardizedFileURL == target
               }) {
                workspace.selectedID = doc.id
            }
        }
    }

    /// Resolve which restored URL should win the active tab. Pulled
    /// out so the unit tests can verify the fallback rules without
    /// spinning up a Workspace.
    static func selectionTarget(from rawSelectedPath: String?,
                                in usable: [URL]) -> URL? {
        guard let raw = rawSelectedPath, !raw.isEmpty else {
            return usable.first
        }
        let target = URL(fileURLWithPath: raw).standardizedFileURL
        if usable.contains(where: { $0 == target }) {
            return target
        }
        return usable.first
    }
}
