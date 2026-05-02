//
//  ActiveFileGitProbe.swift
//  Phase 48b — single-file fallback for the status-bar branch chip.
//
//  Why this exists:
//    `GitStatusEngine` (Phase 35b-1) only binds when the user opens
//    a *folder* — that's the workspace-anchored Source Control flow.
//    But Scribe is happy to open one-off files via ⌘O, drag-drop,
//    or `open file.swift` from a terminal; in those cases the active
//    doc may live deep inside a real git repo without the workspace
//    knowing about it. Phase 46f's branch chip stayed empty in that
//    mode because it read directly from `gitStatusEngine.branch`.
//
//  What it does:
//    Walks the active file's parent chain on every selection or
//    save tick, runs `git rev-parse` (`findRepoRoot`) to locate the
//    enclosing repo, then fetches `currentBranch` + `aheadBehind`
//    from `GitClient`. Results land on `@Published` so the
//    `StatusBarView` chip rerenders without any extra plumbing.
//
//  Concurrency:
//    @MainActor for the published mutations; the actual shell-out
//    happens inside `Task.detached(.userInitiated)` so a cold
//    monorepo `git` doesn't hitch typing in another tab.
//
//  Suspension:
//    When the workspace already has a folder bound, `GitStatusEngine`
//    is the canonical source of branch / aheadBehind info. The chip
//    prefers it. We pass `suspended: true` from Workspace in that
//    case so the probe clears its own cache and the UI doesn't have
//    to deduplicate two competing values.
//

import Foundation

@MainActor
final class ActiveFileGitProbe: ObservableObject {

    /// Branch name for the repo containing the active doc, or nil
    /// when the active doc is untitled / outside any repo / the
    /// probe is suspended (folder bound).
    @Published private(set) var branch: String?

    /// Local-vs-upstream divergence for that repo. Mirrors
    /// `GitStatusEngine.aheadBehind` semantics: nil ⇒ no upstream
    /// configured (or the lookup failed) ⇒ chip omits the indicator.
    @Published private(set) var aheadBehind: GitClient.AheadBehind?

    /// Repo root we last resolved. Held read-only for tests / future
    /// debug surfaces; the chip itself only reads `branch` /
    /// `aheadBehind`.
    @Published private(set) var repoRoot: URL?

    /// In-flight probe. Cancelled before kicking off a new one so
    /// rapid tab switching doesn't pile up shell-outs that would
    /// race to overwrite each other in the wrong order.
    private var currentTask: Task<Void, Never>?

    init() {}

    /// Phase 48b — refresh entry point. Drive from Workspace on
    /// `selectedID` change, save completion, folder bind/unbind,
    /// and external file change. `activeFileURL == nil` ⇒ active
    /// doc is untitled (or the workspace has no docs); `suspended`
    /// signals that GitStatusEngine has the floor and we should
    /// keep our outputs nil so the chip doesn't double up.
    func update(activeFileURL: URL?, suspended: Bool) {
        currentTask?.cancel()
        guard !suspended, let url = activeFileURL else {
            clear()
            return
        }
        let probeURL = url.standardizedFileURL
        currentTask = Task { [weak self] in
            // Off main: walk parents looking for `.git` and run
            // two cheap shell-outs. Both `findRepoRoot` and the
            // GitClient methods are nonisolated so the detached
            // closure compiles cleanly.
            let probed = await Task.detached(priority: .userInitiated) {
                () -> (URL?, String?, GitClient.AheadBehind?) in
                guard let root = GitClient.findRepoRoot(for: probeURL) else {
                    return (nil, nil, nil)
                }
                let br = GitClient.currentBranch(repo: root)
                let ab = GitClient.aheadBehind(repo: root)
                return (root, br, ab)
            }.value
            guard let self else { return }
            if Task.isCancelled { return }
            // Settle published values in one batch — fewer
            // objectWillChange ticks than three independent assigns.
            self.repoRoot = probed.0
            self.branch = probed.1
            self.aheadBehind = probed.2
        }
    }

    /// Wipe the cache (e.g. on suspension or untitled-doc selection)
    /// without firing redundant @Published ticks when we're already
    /// at the cleared state.
    private func clear() {
        if repoRoot != nil { repoRoot = nil }
        if branch != nil { branch = nil }
        if aheadBehind != nil { aheadBehind = nil }
    }
}
