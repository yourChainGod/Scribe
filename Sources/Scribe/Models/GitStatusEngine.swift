//
//  GitStatusEngine.swift
//  Phase 35b-1 — backbone of the Source Control sidebar.
//
//  Mirrors the lifecycle shape of `GitGutterEngine`:
//    - One shared instance per workspace; `bind(repo:)` switches it
//      to a different repository (e.g. when the user opens a new
//      folder).
//    - `refresh()` schedules a detached task that shells out to
//      `git status` and writes the rows back on the main actor.
//    - Save paths (`Workspace.write`, `Workspace.handleExternalChange`)
//      already call into other refresh hooks; we hook the same code
//      paths so the sidebar stays in sync without polling.
//
//  Concurrency:
//    - The class is `@MainActor`; all reads and writes of `repo` /
//      `rows` / `state` happen on the main thread.
//    - The shell-out runs in `Task.detached(.userInitiated)` so a
//      slow status (e.g. a freshly-opened large monorepo) doesn't
//      hitch typing.
//    - We hop back to main to mutate `@Published`, which is what
//      SwiftUI's diff loop expects.
//
//  Why a state machine instead of bare `[GitFileStatus]?`:
//    The sidebar wants three distinct empty states ("no folder
//    open", "folder isn't a repo", "repo is clean") with different
//    copy. Threading a single optional array through the view would
//    erase those distinctions; the enum makes the empty state
//    surface explicit at every call site.
//

import Combine
import Foundation

@MainActor
final class GitStatusEngine: ObservableObject {

    /// Drives the Source Control sidebar's empty-state copy. We
    /// publish the state separately from `rows` so the view doesn't
    /// have to disambiguate "loaded with zero rows" from "still
    /// loading" by inspecting an array.
    enum State: Equatable, Sendable {
        /// No repo bound yet (no folder open, or workspace just
        /// launched).
        case idle
        /// `bind(repo:)` was called but the path turned out not to
        /// be inside a git repository.
        case notInRepo
        /// Most recent `git status` succeeded; `rows` reflects it.
        /// Could still be empty (clean working tree).
        case loaded
    }

    /// Latest porcelain output, as parsed rows. Always reflects the
    /// most recent successful refresh; transient git errors keep
    /// the previous value rather than blanking the sidebar (matches
    /// `GitGutterEngine`'s behaviour for the same reason).
    @Published private(set) var rows: [GitFileStatus] = []

    /// Empty-state classifier. The sidebar reads this to choose
    /// between "open a folder", "not a repo", "no changes", or the
    /// row list.
    @Published private(set) var state: State = .idle

    /// Currently-bound repo root (the path containing `.git`), or
    /// nil when no folder is open. Plain stored property — URL is
    /// a value type so there's no retain cycle to worry about.
    private(set) var repo: URL?

    /// In-flight `git status` task. Cancelled + replaced on every
    /// new `refresh()` so a save burst doesn't pile up shell-outs
    /// against the same repo.
    private var currentTask: Task<Void, Never>?

    /// Switch the engine to a different repo. Pass `nil` (or a
    /// non-repo URL) to clear. Always triggers a refresh — the
    /// caller doesn't have to remember to do it manually.
    func bind(repo: URL?) {
        if self.repo == repo { return }
        self.repo = repo
        refresh()
    }

    /// Kick a new `git status` cycle. Safe to call repeatedly.
    /// Cancels the previous in-flight task and replaces it.
    func refresh() {
        currentTask?.cancel()
        guard let repo else {
            // No bound repo ⇒ idle empty state. We zero out rows so
            // the sidebar doesn't briefly show stale data after a
            // closeFolder().
            rows = []
            state = .idle
            return
        }

        currentTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                GitClient.status(repo: repo)
            }.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .rows(let parsed):
                if self.rows != parsed { self.rows = parsed }
                self.state = .loaded
            case .notInRepo:
                if !self.rows.isEmpty { self.rows = [] }
                self.state = .notInRepo
            case .error:
                // Don't blank the sidebar on a transient error —
                // a flaky filesystem lock or a recursive git
                // operation in progress is enough to fail one
                // refresh, and clearing the panel mid-typing
                // would feel jumpy. Leave rows / state alone.
                break
            }
        }
    }
}
