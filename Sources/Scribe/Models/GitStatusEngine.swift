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

    /// Phase 35b-2c — local-vs-upstream divergence. `nil` means
    /// either no upstream is configured (fresh branch the user
    /// hasn't pushed yet) or the lookup failed; either way the
    /// sidebar hides the indicator. Refreshed alongside `branch`
    /// in the same detached pass.
    @Published private(set) var aheadBehind: GitClient.AheadBehind?

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

    /// Phase 35b-2c — `git fetch`. Detached pipeline mirrors the
    /// other write helpers; the only twist is fetch can take
    /// noticeably longer than a status refresh (network roundtrip),
    /// so users see the sidebar momentarily show stale data while
    /// the spinner runs in the toolbar — that's intentional.
    func fetch() async {
        guard let repo else { return }
        let result = await Task.detached(priority: .userInitiated) {
            GitClient.fetch(repo: repo)
        }.value
        handleWriteResult(result, action: .fetch)
    }

    /// Phase 35b-2c — `git pull --ff-only`. Refusing non-fast-forwards
    /// at the engine level means the user can never accidentally
    /// merge from a button click; if the pull fails the alert is
    /// surfaced verbatim and they decide rebase vs. merge in a
    /// terminal.
    func pull() async {
        guard let repo else { return }
        let result = await Task.detached(priority: .userInitiated) {
            GitClient.pull(repo: repo)
        }.value
        handleWriteResult(result, action: .pull)
    }

    /// Phase 35b-2c — `git push`. No `--force` on this path; rejected
    /// pushes produce a clear stderr (e.g. "non-fast-forward") that
    /// our alert surfaces unmodified.
    func push() async {
        guard let repo else { return }
        let result = await Task.detached(priority: .userInitiated) {
            GitClient.push(repo: repo)
        }.value
        handleWriteResult(result, action: .push)
    }

    /// Phase 35b-4-a — list branches (local + remote-tracking) for
    /// the picker. Returns an empty array on any git failure so
    /// the menu just goes empty rather than alert-spamming —
    /// the user retries by re-opening the menu.
    func branches() async -> [GitClient.Branch] {
        guard let repo else { return [] }
        return await Task.detached(priority: .userInitiated) {
            GitClient.branches(repo: repo)
        }.value
    }

    /// Switch to a branch. Refresh always runs after, regardless
    /// of outcome — even a failed switch may have side-effected
    /// (left the index in a partially-checked state) and we want
    /// the sidebar to reflect ground truth.
    func checkoutBranch(_ branch: GitClient.Branch) async {
        guard let repo else { return }
        let result = await Task.detached(priority: .userInitiated) {
            GitClient.checkoutBranch(branch, repo: repo)
        }.value
        handleWriteResult(result, action: .checkout)
    }

    /// Phase 35b-4-a — `git push --force-with-lease`. The lease
    /// guard is non-negotiable from the UI: if it rejects, the
    /// user gets the verbatim error and decides explicitly from
    /// a terminal.
    func pushForceWithLease() async {
        guard let repo else { return }
        let result = await Task.detached(priority: .userInitiated) {
            GitClient.pushForceWithLease(repo: repo)
        }.value
        handleWriteResult(result, action: .pushForce)
    }

    /// Phase 35b-4-b — full Project Diff payload. Walks every row
    /// in the current `state` and pulls staged + working hunks for
    /// each one; entries whose hunk lists are both empty (e.g. a
    /// pure untracked row whose `git diff` produces nothing) are
    /// filtered out so the multibuffer view stays trivial.
    ///
    /// Returns an empty array when:
    ///   - no repo is bound (`repo == nil`)
    ///   - status hasn't loaded yet (`rows.isEmpty` is fine —
    ///     callers refresh on a polling interval)
    ///
    /// We deliberately call `hunks(forPath:cached:)` per row
    /// sequentially rather than fanning out via `withTaskGroup`.
    /// Each call already detaches its own work, and a 50-file
    /// dirty tree resolves in well under 200 ms in practice; if a
    /// future repo has thousands of dirty files the bottleneck is
    /// the SwiftUI render of that many hunks, not the diff pulls.
    func projectDiff() async -> [ProjectDiffEntry] {
        guard repo != nil else { return [] }
        var out: [ProjectDiffEntry] = []
        for row in rows {
            // Short-circuit on the per-column flags so untracked
            // rows don't pay for two no-op git diffs.
            let staged: [GitClient.Hunk] = row.hasStagedChanges
                ? await hunks(forPath: row.path, cached: true)
                : []
            let working: [GitClient.Hunk] = row.hasUnstagedChanges
                ? await hunks(forPath: row.path, cached: false)
                : []
            guard !(staged.isEmpty && working.isEmpty) else { continue }
            out.append(ProjectDiffEntry(path: row.path,
                                        url: row.url,
                                        stagedHunks: staged,
                                        workingHunks: working))
        }
        return out
    }

    /// Phase 35b-4-c — path-keyed counterpart to `stage(_:)` for the
    /// Project Diff multibuffer. The view holds `ProjectDiffEntry`
    /// (path-only) rather than the underlying `GitFileStatus` to
    /// keep its own data shape lean; this helper does the row
    /// lookup so the view stays decoupled from the engine's
    /// internal model. Returns silently when the row is no longer
    /// present (e.g. concurrent refresh removed it after a commit).
    func stagePath(_ path: String) async {
        guard let row = rows.first(where: { $0.path == path }) else {
            return
        }
        await stage(row)
    }

    /// Phase 35b-4-c — path-keyed counterpart to `unstage(_:)`.
    /// Same lookup contract as `stagePath` — we deliberately don't
    /// surface a "row not found" error because the multibuffer
    /// always reloads after the action regardless of outcome, so
    /// a vanished row simply won't reappear.
    func unstagePath(_ path: String) async {
        guard let row = rows.first(where: { $0.path == path }) else {
            return
        }
        await unstage(row)
    }

    /// Phase 35b-3-ii — fetch hunks for a single file. `cached: false`
    /// returns working-tree-vs-index hunks (the source of "stage
    /// hunk"); `cached: true` returns index-vs-HEAD hunks (the
    /// source of "unstage hunk"). Returns an empty array on any git
    /// failure so the sidebar's expand-to-show-hunks affordance just
    /// collapses gracefully — a transient git error mid-typing
    /// shouldn't pop an alert.
    func hunks(forPath path: String, cached: Bool) async -> [GitClient.Hunk] {
        guard let repo else { return [] }
        return await Task.detached(priority: .userInitiated) {
            () -> [GitClient.Hunk] in
            switch GitClient.diffForApply(path: path,
                                          repo: repo,
                                          cached: cached) {
            case .diff(let raw):
                return GitClient.parseHunks(raw)
            case .untracked, .notInRepo, .error:
                return []
            }
        }.value
    }

    /// Stage one hunk from the working tree into the index. The hunk
    /// must originate from a `cached: false` diff — applying a hunk
    /// extracted from somewhere else won't locate cleanly because
    /// the line numbers and context strings are tied to the working
    /// tree's current state.
    func stageHunk(_ hunk: GitClient.Hunk, path: String) async {
        guard let repo else { return }
        let patch = hunk.minimalPatch(forFilePath: path)
        let result = await Task.detached(priority: .userInitiated) {
            GitClient.applyPatch(patch, repo: repo, reverse: false)
        }.value
        handleWriteResult(result, action: .stageHunk)
    }

    /// Unstage one hunk from the index back into the working tree.
    /// `hunk` must originate from a `cached: true` diff for the
    /// same reason — its line numbers describe the index, and
    /// reverse-apply needs that context to find the right slice.
    func unstageHunk(_ hunk: GitClient.Hunk, path: String) async {
        guard let repo else { return }
        let patch = hunk.minimalPatch(forFilePath: path)
        let result = await Task.detached(priority: .userInitiated) {
            GitClient.applyPatch(patch, repo: repo, reverse: true)
        }.value
        handleWriteResult(result, action: .unstageHunk)
    }

    /// Phase 35b-4-d — discard one working-tree hunk (the
    /// `git checkout -p` selecting-just-this-hunk equivalent).
    /// `hunk` must originate from a `cached: false` diff because
    /// its line numbers describe the working tree, and reverse-
    /// apply on the working tree (no `--cached`) needs that
    /// context to locate the right slice.
    ///
    /// **Destructive**: there is no analogue of `git reflog` for
    /// working-tree changes — once reverted, the hunk's contents
    /// are gone. Callers MUST gate this behind a confirmation;
    /// the engine deliberately doesn't enforce confirmation here
    /// (the modal lives at the SwiftUI layer where it can pull
    /// the right localised copy and parent window).
    func revertHunk(_ hunk: GitClient.Hunk, path: String) async {
        guard let repo else { return }
        let patch = hunk.minimalPatch(forFilePath: path)
        let result = await Task.detached(priority: .userInitiated) {
            GitClient.applyPatch(patch, repo: repo,
                                 reverse: true, cached: false)
        }.value
        handleWriteResult(result, action: .revertHunk)
    }

    /// Internal — write-op kinds used to label the failure alert.
    /// The `failureKey` indirection feeds L10n at the time the
    /// alert is built so the message follows the system language.
    private enum WriteAction {
        case stage, unstage, discard, commit, fetch, pull, push,
             stageHunk, unstageHunk, revertHunk, checkout, pushForce

        var failureKey: String {
            switch self {
            case .stage:        return "sourceControl.alert.stageFailed"
            case .unstage:      return "sourceControl.alert.unstageFailed"
            case .discard:      return "sourceControl.alert.discardFailed"
            case .commit:       return "sourceControl.alert.commitFailed"
            case .fetch:        return "sourceControl.alert.fetchFailed"
            case .pull:         return "sourceControl.alert.pullFailed"
            case .push:         return "sourceControl.alert.pushFailed"
            case .stageHunk:    return "sourceControl.alert.stageHunkFailed"
            case .unstageHunk:  return "sourceControl.alert.unstageHunkFailed"
            case .revertHunk:   return "sourceControl.alert.revertHunkFailed"
            case .checkout:     return "sourceControl.alert.checkoutFailed"
            case .pushForce:    return "sourceControl.alert.pushForceFailed"
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
    /// Phase 35b-2b/2c — also pulls the current branch + ahead/
    /// behind counts in the same detached pass so the sidebar
    /// indicators track checkouts/commits/fetches without extra
    /// refresh hooks.
    func refresh() {
        currentTask?.cancel()
        guard let repo else {
            // No bound repo ⇒ idle empty state. We zero out rows so
            // the sidebar doesn't briefly show stale data after a
            // closeFolder().
            rows = []
            branch = nil
            aheadBehind = nil
            state = .idle
            return
        }

        currentTask = Task { [weak self] in
            let (result, branchName, ab) = await Task.detached(priority: .userInitiated) {
                () -> (GitClient.StatusResult, String?, GitClient.AheadBehind?) in
                let status = GitClient.status(repo: repo)
                let br = GitClient.currentBranch(repo: repo)
                let ab = GitClient.aheadBehind(repo: repo)
                return (status, br, ab)
            }.value
            guard !Task.isCancelled, let self else { return }
            if self.branch != branchName { self.branch = branchName }
            if self.aheadBehind != ab { self.aheadBehind = ab }
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
