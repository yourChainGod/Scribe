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

import AppKit
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

    /// Phase 35b-2b — currently-checked-out branch (or `nil` for
    /// detached HEAD / pre-first-commit repos). Refreshed on every
    /// `refresh()` cycle alongside the row list because checkout /
    /// commit / merge all may change the branch and we already have
    /// the trigger plumbing.
    @Published private(set) var branch: String?

    /// Phase 35b-2b — subject of the HEAD commit, used to pre-fill
    /// the message textarea when the user toggles "Amend". Read-
    /// once on demand rather than tracked continuously: a commit
    /// changes HEAD but the textarea hides until the user opens it,
    /// so a stale value here is harmless until they look.
    var headSubject: String? {
        guard let repo else { return nil }
        return GitClient.headSubject(repo: repo)
    }

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

    // MARK: - Phase 35b-2a · file-level write ops

    /// Stage every change for `row.path`. Runs `git add -- <path>`
    /// on a background task (the binary is binary-stable and
    /// nonisolated) and refreshes once it returns. On failure we
    /// surface the git error as an `NSAlert`; the previous status
    /// stays visible so the user can retry without losing context.
    ///
    /// We accept a `GitFileStatus` rather than just a path so the
    /// caller can't accidentally pass an absolute URL into a
    /// command that needs a repo-relative one.
    func stage(_ row: GitFileStatus) async {
        guard let repo else { return }
        let result = await Task.detached(priority: .userInitiated) {
            GitClient.stage(path: row.path, repo: repo)
        }.value
        handleWriteResult(result, action: .stage)
    }

    /// Unstage. Symmetrical to `stage` — see its comment for the
    /// reasoning behind running on a background task.
    func unstage(_ row: GitFileStatus) async {
        guard let repo else { return }
        let result = await Task.detached(priority: .userInitiated) {
            GitClient.unstage(path: row.path, repo: repo)
        }.value
        handleWriteResult(result, action: .unstage)
    }

    /// Discard working-tree changes. Untracked files have no index
    /// version to restore from, so we delete the file outright via
    /// `FileManager`; tracked ones go through `git restore`.
    /// Caller is expected to have already shown a confirmation
    /// dialog (the operation is destructive — restoring an
    /// untracked file is impossible).
    func discard(_ row: GitFileStatus) async {
        guard let repo else { return }
        let result = await Task.detached(priority: .userInitiated) {
            () -> GitClient.WriteResult in
            if row.isUntracked {
                // git has nothing to restore; remove the file.
                // `removeItem` returns void / throws — convert to
                // the same WriteResult shape.
                do {
                    try FileManager.default.removeItem(at: row.url)
                    return .ok
                } catch {
                    return .error(error.localizedDescription)
                }
            } else {
                return GitClient.discardWorkingTree(path: row.path, repo: repo)
            }
        }.value
        handleWriteResult(result, action: .discard)
    }

    /// Phase 35b-2b — record a commit with `message`. `amend == true`
    /// rewrites the HEAD commit instead. We don't validate `message`
    /// up front (empty-string commit, leading-whitespace, etc.) —
    /// `git commit -F -` already rejects empties with a clear error
    /// that we surface verbatim, and treating "looks empty after
    /// trim" as our own validation would diverge from git's
    /// (`--cleanup=strip` — currently set — strips comments + blank
    /// lines, so what counts as "empty" depends on git config).
    func commit(message: String, amend: Bool) async {
        guard let repo else { return }
        let result = await Task.detached(priority: .userInitiated) {
            GitClient.commit(message: message, repo: repo, amend: amend)
        }.value
        handleWriteResult(result, action: .commit)
    }

    /// Internal — write-op kinds used to label the failure alert.
    /// The `failureKey` indirection feeds L10n at the time the
    /// alert is built so the message follows the system language.
    private enum WriteAction {
        case stage, unstage, discard, commit

        var failureKey: String {
            switch self {
            case .stage:   return "sourceControl.alert.stageFailed"
            case .unstage: return "sourceControl.alert.unstageFailed"
            case .discard: return "sourceControl.alert.discardFailed"
            case .commit:  return "sourceControl.alert.commitFailed"
            }
        }
    }

    /// Show an `NSAlert` for the failure case, then refresh
    /// regardless of outcome — even a failed git command may have
    /// partially mutated state, and the next refresh is the
    /// authoritative source of truth.
    private func handleWriteResult(_ result: GitClient.WriteResult,
                                   action: WriteAction) {
        if case .error(let message) = result {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.t(action.failureKey)
            // git errors can be multi-line; show them verbatim so
            // a power user can copy-paste into a terminal.
            alert.informativeText = message
            alert.addButton(withTitle: L10n.t("alert.button.ok"))
            alert.runModal()
        }
        refresh()
    }

    /// Kick a new `git status` cycle. Safe to call repeatedly.
    /// Cancels the previous in-flight task and replaces it.
    /// Phase 35b-2b — also pulls the current branch in the same
    /// detached pass so the sidebar's branch indicator tracks
    /// checkouts and commits without an extra refresh hook.
    func refresh() {
        currentTask?.cancel()
        guard let repo else {
            // No bound repo ⇒ idle empty state. We zero out rows so
            // the sidebar doesn't briefly show stale data after a
            // closeFolder().
            rows = []
            branch = nil
            state = .idle
            return
        }

        currentTask = Task { [weak self] in
            let (result, branchName) = await Task.detached(priority: .userInitiated) {
                () -> (GitClient.StatusResult, String?) in
                let status = GitClient.status(repo: repo)
                let br = GitClient.currentBranch(repo: repo)
                return (status, br)
            }.value
            guard !Task.isCancelled, let self else { return }
            if self.branch != branchName { self.branch = branchName }
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
