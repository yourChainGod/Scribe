//
//  GitGutterEngine.swift
//  Phase 31 — drives `git diff -U0 HEAD -- <file>` for the active
//  document and writes the per-line status back into
//  `Document.gitGutter`. The Scintilla coordinator (separately, via
//  Coordinator+GitGutter.swift) reads that map and renders the
//  added / modified / deleted strip in the editor's left margin.
//
//  Lifecycle:
//    - Workspace owns one shared engine across the whole window.
//      `bind(to:)` switches the engine to a new doc; previous-doc
//      state is left intact (we don't clear it — the next switch
//      back will refresh anyway).
//    - `refresh()` schedules a detached `Task` that runs the git
//      shell-out off-main and writes the resulting `[Int:
//      GitGutterStatus]` into the bound doc's `@Published gitGutter`.
//    - `refresh()` is called on bind, after a save (`Workspace.write`)
//      and after an external file change (`handleExternalChange`).
//      We don't poll — git-state edits the disk and we already have
//      hooks for both write paths.
//
//  Threading:
//    - The class is `@MainActor`. Reads + writes of `bound` and
//      `currentTask` are all main-actor.
//    - The shell-out itself runs in `Task.detached(.userInitiated)`
//      via `GitClient.unifiedDiff(of:)`, which is `nonisolated`.
//    - We hop back to main to write `doc.gitGutter`.
//
//  Why one engine per workspace, not per-doc:
//    - One git invocation in flight at a time keeps the on-disk lock
//      contention down for monorepo-sized repos. A user with 30 tabs
//      open shouldn't see 30 simultaneous `git diff`s on save.
//    - Token-cancellation also gets simpler — we just cancel the
//      outstanding Task before kicking the next one.
//

import Combine
import Foundation

@MainActor
final class GitGutterEngine: ObservableObject {

    /// Currently-bound document. We hold weakly so a closed tab
    /// doesn't keep the engine pinned.
    weak var bound: Document?

    /// In-flight `git diff` task. Cancelled + replaced on every new
    /// `refresh()` call so a save burst doesn't stack up shell-outs.
    private var currentTask: Task<Void, Never>?

    /// Switch the engine to a different document. Always triggers a
    /// refresh so the gutter for the newly-active tab is current.
    func bind(to doc: Document?) {
        if bound === doc { return }
        bound = doc
        refresh()
    }

    /// Kick a new git-diff cycle for the bound document. Safe to
    /// call repeatedly — each call cancels the previous in-flight
    /// task and replaces it.
    func refresh() {
        guard let doc = bound else {
            currentTask?.cancel()
            currentTask = nil
            return
        }
        // No URL ⇒ untitled buffer. Nothing for git to compare.
        guard let url = doc.url else {
            doc.gitGutter = [:]
            return
        }

        currentTask?.cancel()
        currentTask = Task { [weak self, weak doc] in
            // Off-main: run git, parse the unified diff. Both calls
            // are `nonisolated` and pure.
            let map = await Task.detached(priority: .userInitiated) {
                () -> [Int: GitGutterStatus] in
                let result = GitClient.unifiedDiff(of: url)
                switch result {
                case .diff(let raw):
                    return GitDiffParser.parse(raw)
                case .untracked, .notInRepo, .error:
                    // Untracked / outside-repo / git error all
                    // collapse to "no gutter" so the margin stays
                    // clean. Errors are intentionally swallowed —
                    // a missing git binary or transient lock isn't
                    // user-actionable from the editor surface.
                    return [:]
                }
            }.value
            // Hop back to main to write the @Published.
            guard !Task.isCancelled,
                  let self,
                  let doc,
                  // Re-check binding: the user may have switched
                  // tabs while git was running. We still write the
                  // value to the doc whose URL we computed for —
                  // the current bound doc gets its own refresh on
                  // bind() — but skip the ceremony if doc was
                  // closed in the meantime.
                  doc.url == url
            else { return }
            if doc.gitGutter != map {
                doc.gitGutter = map
            }
            _ = self   // keep weakly-held self alive across the await
        }
    }
}
