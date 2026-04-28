//
//  GitClient.swift
//  Phase 8 — minimal git CLI wrapper. We shell out rather than link
//  against libgit2 because:
//    1. The user already has git installed on any dev machine.
//    2. /usr/bin/git is binary-stable and SwiftPM-friendly without
//       extra system packages.
//    3. We only need three operations: locate the repo, read a HEAD
//       blob, ask if a path is tracked. That's ~20 lines of glue.
//
//  All entry points are nonisolated + sync. Callers run them on a
//  background task if they need to keep the main thread responsive.
//

import Foundation

enum GitClient {

    /// Outcome of `headBlob(of:)`.
    enum HeadBlobResult {
        case success(blob: String, shortSHA: String)
        case untracked          // file is in the repo dir but never committed
        case notInRepo          // path doesn't have any git ancestor
        case error(String)      // any other git failure (corrupt HEAD, …)
    }

    /// Outcome of `unifiedDiff(of:)`. Phase 31 git-gutter input.
    enum UnifiedDiffResult {
        case diff(String)       // the raw unified-diff text; empty = identical
        case untracked          // file isn't tracked at HEAD
        case notInRepo
        case error(String)
    }

    /// Outcome of `status(repo:)`. Phase 35b-1 — Source Control
    /// sidebar input. `notInRepo` and `error` collapse to "no
    /// rows" in the UI rather than firing an alert; status fetch is
    /// a periodic background task and a transient failure shouldn't
    /// surface.
    enum StatusResult {
        case rows([GitFileStatus])
        case notInRepo
        case error(String)
    }

    // MARK: - Public

    /// Return the textual contents of `file` as it exists in HEAD.
    /// `shortSHA` is the 7-char hash of the HEAD commit, useful for
    /// labelling the diff pane.
    nonisolated static func headBlob(of file: URL) -> HeadBlobResult {
        let path = file.standardizedFileURL.path
        guard let repoRoot = findRepoRoot(for: file) else {
            return .notInRepo
        }
        // Path relative to the repo root — git show wants
        // "HEAD:<repo-relative-path>".
        let relative = relativize(path: path, from: repoRoot)
        // 1. Is the file tracked at HEAD?
        switch run(["ls-files", "--error-unmatch", "--", relative],
                   cwd: repoRoot) {
        case .failure:
            return .untracked
        case .success:
            break
        }
        // 2. Read the blob.
        let blobResult = run(["show", "HEAD:\(relative)"], cwd: repoRoot)
        guard case .success(let blob) = blobResult else {
            if case .failure(let message) = blobResult {
                return .error(message)
            }
            return .error("git show failed")
        }
        // 3. Short SHA for the header.
        let shortSHA: String
        switch run(["rev-parse", "--short", "HEAD"], cwd: repoRoot) {
        case .success(let s): shortSHA = s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failure:        shortSHA = "HEAD"
        }
        return .success(blob: blob, shortSHA: shortSHA)
    }

    /// Phase 31 — return `git diff -U0 HEAD -- <file>` so the gutter
    /// engine can map every changed line back to a +/− status. We
    /// pin `-U0` (zero context) so the unified hunks describe only
    /// the actually-changed lines: any "unchanged" line that would
    /// otherwise pad the hunk for human readability would just be
    /// noise to the parser.
    ///
    /// Caveat: `git diff` works against the *working tree* as it
    /// exists on disk, not the buffer the user is editing. We re-run
    /// after every save (Workspace.write) so the gutter catches up
    /// whenever the file becomes save-able. A buffer-aware variant
    /// (HEAD blob ↔ in-memory text) is Phase 31b material.
    nonisolated static func unifiedDiff(of file: URL) -> UnifiedDiffResult {
        let path = file.standardizedFileURL.path
        guard let repoRoot = findRepoRoot(for: file) else {
            return .notInRepo
        }
        let relative = relativize(path: path, from: repoRoot)
        // Tracked check first — `git diff` on an untracked file
        // returns nothing, which would silently render as "no
        // changes" instead of "no gutter at all".
        switch run(["ls-files", "--error-unmatch", "--", relative],
                   cwd: repoRoot) {
        case .failure: return .untracked
        case .success: break
        }
        switch run(["diff",
                    "--no-color",
                    "--no-ext-diff",
                    "-U0",
                    "HEAD",
                    "--",
                    relative],
                   cwd: repoRoot) {
        case .success(let out): return .diff(out)
        case .failure(let err): return .error(err)
        }
    }

    /// Phase 35b-1 — list every changed file in `repo` for the
    /// Source Control sidebar. Uses `git status -z --porcelain=v1`:
    ///   - `-z`         NUL-separated entries, paths round-trip
    ///                  losslessly even with whitespace.
    ///   - `--porcelain=v1`  Stable wire format git pins forever.
    ///   - `--ignored=no`    Skip ignored files; the sidebar would
    ///                       otherwise drown in `node_modules` /
    ///                       `.build` rows. v2 lets the user toggle.
    nonisolated static func status(repo: URL) -> StatusResult {
        switch run(["status",
                    "--porcelain=v1",
                    "-z",
                    "--ignored=no",
                    "--untracked-files=all"],
                   cwd: repo) {
        case .success(let raw):
            let rows = GitStatusParser.parse(raw, repoRoot: repo)
            return .rows(rows)
        case .failure(let err):
            // git emits an exit-128 with "fatal: not a git
            // repository" outside any repo; surface as the
            // structured case so the UI can render its empty state.
            if err.lowercased().contains("not a git repository") {
                return .notInRepo
            }
            return .error(err)
        }
    }

    /// Outcome of a write operation (`stage` / `unstage` / `discard`).
    /// Phase 35b-2a — the Source Control sidebar's row buttons run
    /// these and surface the failure as an `NSAlert` so users see
    /// what git complained about (e.g. dirty index, file moved).
    enum WriteResult: Sendable, Equatable {
        case ok
        case error(String)
    }

    /// Phase 35b-2a — stage `path` in `repo`. `git add` rather than
    /// `git update-index` because `add` handles new files,
    /// modifications, and deletions uniformly; the latter only
    /// stages the index against an existing tree entry.
    nonisolated static func stage(path: String, repo: URL) -> WriteResult {
        switch run(["add", "--", path], cwd: repo) {
        case .success: return .ok
        case .failure(let err): return .error(err)
        }
    }

    /// Unstage `path` — `git restore --staged` matches what zed and
    /// modern git docs recommend over the deprecated `git reset HEAD`
    /// dance. Effect is identical: tree entry stays, index goes back
    /// to HEAD's view of the file.
    nonisolated static func unstage(path: String, repo: URL) -> WriteResult {
        switch run(["restore", "--staged", "--", path], cwd: repo) {
        case .success: return .ok
        case .failure(let err): return .error(err)
        }
    }

    /// Discard working-tree changes for a tracked file —
    /// `git restore` (no `--staged`) overwrites the on-disk content
    /// with the index version. Untracked files don't fit this
    /// command; `Workspace.discardFile` handles them via
    /// `FileManager.removeItem` instead.
    nonisolated static func discardWorkingTree(path: String, repo: URL) -> WriteResult {
        switch run(["restore", "--", path], cwd: repo) {
        case .success: return .ok
        case .failure(let err): return .error(err)
        }
    }

    /// Phase 35b-2b — record a commit. `amend == true` rewrites the
    /// HEAD commit instead of creating a new one (`git commit
    /// --amend`). We pass the message via stdin to sidestep argv
    /// limits + quoting hazards: a commit message can be tens of
    /// kilobytes (think Linux kernel patches with full changelogs)
    /// and embedding multi-line text into argv is asking for a
    /// shell-injection-shaped bug even when we control the spawn.
    ///
    /// Why not `-m <msg>`:
    ///   `-m` joins repeated values into paragraph separators, but
    ///   a single `-m` with a long body is still passed via argv,
    ///   capped at ~256 KiB on macOS. `-F -` reads from stdin and
    ///   has no such cap. zed and the GitHub Desktop both use the
    ///   stdin path for the same reason.
    nonisolated static func commit(message: String,
                                   repo: URL,
                                   amend: Bool) -> WriteResult {
        var args = ["commit", "-F", "-", "--cleanup=strip"]
        if amend { args.append("--amend") }
        switch runWithStdin(args, stdin: message, cwd: repo) {
        case .success: return .ok
        case .failure(let err): return .error(err)
        }
    }

    /// Phase 35b-2b — current branch name. `git branch --show-current`
    /// is the dedicated porcelain for this; it returns empty when
    /// HEAD is detached, which we surface as nil so the sidebar
    /// can fall back to the short SHA.
    nonisolated static func currentBranch(repo: URL) -> String? {
        switch run(["branch", "--show-current"], cwd: repo) {
        case .success(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .failure: return nil
        }
    }

    /// Subject (first line) of the HEAD commit. Powers the "Amend"
    /// toggle: enabling it pre-fills the textarea with the previous
    /// message so the user can edit instead of retyping. Returns
    /// nil for an empty repo (no commits yet) or any git error.
    nonisolated static func headSubject(repo: URL) -> String? {
        switch run(["log", "-1", "--pretty=%B"], cwd: repo) {
        case .success(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .failure: return nil
        }
    }

    // MARK: - Phase 35b-2c · remote sync

    /// Snapshot of "how out-of-sync are we with our upstream".
    /// Both counts are zero when up-to-date; ahead > 0 means we
    /// have local commits to publish, behind > 0 means upstream
    /// has commits we haven't pulled. Diverged → both > 0.
    struct AheadBehind: Equatable, Sendable {
        var ahead: Int
        var behind: Int

        var isUpToDate: Bool { ahead == 0 && behind == 0 }
        var diverged: Bool   { ahead > 0 && behind > 0 }
    }

    /// Phase 35b-2c — `git fetch` against the default upstream.
    /// We don't pass an explicit remote/refspec because that would
    /// silently bypass the user's `branch.<name>.remote` config; the
    /// porcelain default is "fetch the upstream of the current
    /// branch" which is exactly what the sidebar's Fetch button
    /// should do.
    nonisolated static func fetch(repo: URL) -> WriteResult {
        switch run(["fetch", "--quiet"], cwd: repo) {
        case .success: return .ok
        case .failure(let err): return .error(err)
        }
    }

    /// `git pull --ff-only` — refuses to merge or rebase if local
    /// has diverged. zed picked this default for the same reason:
    /// any pull that *isn't* fast-forwardable should be a deliberate
    /// choice (rebase vs merge), not a button click. The user gets
    /// a clear "not possible to fast-forward" error and can decide
    /// from a terminal.
    nonisolated static func pull(repo: URL) -> WriteResult {
        switch run(["pull", "--ff-only", "--quiet"], cwd: repo) {
        case .success: return .ok
        case .failure(let err): return .error(err)
        }
    }

    /// `git push` — pushes the current branch to its upstream. We
    /// don't pass `--force` or `--force-with-lease`; if the upstream
    /// rejects the push (non-fast-forward, protected branch, etc.)
    /// the user sees the error verbatim and can sort it from a
    /// terminal where the recovery options are richer.
    nonisolated static func push(repo: URL) -> WriteResult {
        switch run(["push", "--quiet"], cwd: repo) {
        case .success: return .ok
        case .failure(let err): return .error(err)
        }
    }

    /// Phase 35b-4-a — `git push --force-with-lease`. The lease is
    /// the safety net: git refuses to push if the remote ref has
    /// moved since our last fetch, which protects against stomping
    /// a teammate's commits when an out-of-date local rebase is
    /// pushed. We deliberately never expose plain `--force` from
    /// the UI — when force-with-lease itself rejects, the user can
    /// drop to a terminal and decide explicitly.
    nonisolated static func pushForceWithLease(repo: URL) -> WriteResult {
        switch run(["push", "--force-with-lease", "--quiet"], cwd: repo) {
        case .success: return .ok
        case .failure(let err): return .error(err)
        }
    }

    /// `git rev-list --left-right --count HEAD...@{upstream}`. The
    /// porcelain returns `<ahead>\t<behind>\n`. Returns nil when no
    /// upstream is configured (the command exits non-zero with
    /// "no upstream configured for branch") — the sidebar treats
    /// nil as "hide the indicator" rather than as an error.
    nonisolated static func aheadBehind(repo: URL) -> AheadBehind? {
        switch run(["rev-list", "--left-right", "--count",
                    "HEAD...@{upstream}"], cwd: repo) {
        case .success(let raw):
            return parseAheadBehind(raw)
        case .failure:
            return nil
        }
    }

    /// Pure parser for the rev-list count output. Split out so it
    /// can be unit-tested without spawning git: the surface is small
    /// but easy to get wrong (whitespace separator vs tab, trailing
    /// newline, leading spaces from git's column alignment).
    nonisolated static func parseAheadBehind(_ raw: String) -> AheadBehind? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // git emits counts as `<ahead>\t<behind>` but older versions
        // align to a fixed column with extra spaces. Use whitespace-
        // splitting so both shapes parse identically.
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 2,
              let ahead = Int(parts[0]),
              let behind = Int(parts[1]) else { return nil }
        return AheadBehind(ahead: ahead, behind: behind)
    }

    // MARK: - Phase 35b-4-a · branches & remote-tracking refs

    /// One entry from `branches(repo:)`. Local branches have
    /// `isRemote == false` and may carry an upstream pointer (the
    /// short name of `@{upstream}`, e.g. "origin/main"); remote-
    /// tracking branches have `isRemote == true` and `upstream ==
    /// nil` (a remote ref doesn't itself track another ref).
    /// Equatable + Hashable for SwiftUI ForEach without manual ID,
    /// Sendable so we can hand it across actor boundaries inside
    /// the engine.
    struct Branch: Equatable, Hashable, Sendable {
        var name: String        // "main" or "origin/main"
        var isCurrent: Bool     // git's HEAD pointer ("*")
        var isRemote: Bool      // true iff under refs/remotes/
        var upstream: String?   // local-only: short name of @{upstream}
    }

    /// `git for-each-ref` over both refs/heads and refs/remotes —
    /// one process call gets us the full picker payload (local +
    /// remote-tracking branches, current-branch flag, upstream
    /// pointers). The pipe-delimited format is safe because git
    /// rejects `|` in ref names; if a future git relaxes that we
    /// can switch to ASCII unit-separator (\u{1F}) without
    /// changing the parser shape.
    nonisolated static func branches(repo: URL) -> [Branch] {
        let format = "%(refname)|%(HEAD)|%(upstream:short)|%(symref)"
        switch run(["for-each-ref",
                    "--format=" + format,
                    "refs/heads", "refs/remotes"],
                   cwd: repo) {
        case .success(let raw):
            return parseBranches(raw)
        case .failure:
            return []
        }
    }

    /// Pure parser for the for-each-ref output above. Filters out
    /// symbolic refs like `refs/remotes/origin/HEAD` (they alias
    /// another ref and would just be noise in a picker) and
    /// classifies the remainder by namespace prefix.
    nonisolated static func parseBranches(_ raw: String) -> [Branch] {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> Branch? in
                let parts = line.split(separator: "|",
                                       maxSplits: 3,
                                       omittingEmptySubsequences: false)
                                .map(String.init)
                guard parts.count >= 3 else { return nil }
                let refname = parts[0]
                let isHead = parts[1] == "*"
                let upstreamRaw = parts[2]
                let symref = parts.count >= 4 ? parts[3] : ""
                // Skip symbolic refs (origin/HEAD → origin/main, etc.).
                guard symref.isEmpty else { return nil }
                let name: String
                let isRemote: Bool
                if refname.hasPrefix("refs/heads/") {
                    name = String(refname.dropFirst("refs/heads/".count))
                    isRemote = false
                } else if refname.hasPrefix("refs/remotes/") {
                    name = String(refname.dropFirst("refs/remotes/".count))
                    isRemote = true
                } else {
                    return nil
                }
                return Branch(name: name,
                              isCurrent: isHead,
                              isRemote: isRemote,
                              upstream: upstreamRaw.isEmpty
                                        ? nil : upstreamRaw)
            }
    }

    /// Switch to a branch. For a local branch this is a plain
    /// `git switch <name>`. For a remote-tracking branch we strip
    /// the `<remote>/` prefix and run `git switch <basename>` —
    /// modern git auto-creates a tracking local branch on a
    /// unique remote match. If the remote prefix yields a
    /// duplicate (multiple remotes shadowing the same name) the
    /// command fails with git's own diagnostic and we surface it
    /// verbatim; the user can decide explicitly from a terminal.
    nonisolated static func checkoutBranch(_ branch: Branch,
                                           repo: URL) -> WriteResult {
        let target: String
        if branch.isRemote {
            // "origin/main" → "main". split(maxSplits: 1) means
            // a name like "origin/feat/x" still produces "feat/x".
            target = String(branch.name.split(separator: "/",
                                              maxSplits: 1)
                                       .last ?? Substring(branch.name))
        } else {
            target = branch.name
        }
        switch run(["switch", target], cwd: repo) {
        case .success: return .ok
        case .failure(let err): return .error(err)
        }
    }

    // MARK: - Phase 35b-3 · per-hunk staging plumbing

    /// One unified-diff hunk with full body lines preserved. Unlike
    /// `GitDiffParser.parse`, which collapses hunks to a per-line
    /// `[Int: GitGutterStatus]` map (sufficient for the gutter), the
    /// per-hunk staging path needs the *original* body so we can
    /// rebuild a self-contained `git apply --cached` patch.
    ///
    /// `bodyLines` keeps the leading ' ' / '+' / '-' character intact
    /// — `git apply` parses by the same convention. The "\ No newline
    /// at end of file" sentinel line is also preserved verbatim (it
    /// belongs to the body in unified-diff syntax).
    struct Hunk: Sendable, Equatable {
        var oldStart: Int
        var oldLen: Int
        var newStart: Int
        var newLen: Int
        /// Trailing "@@ section heading" emitted by git to identify
        /// the enclosing function/symbol. Preserved so a rebuilt
        /// patch matches the original byte-for-byte; not used for
        /// any logic.
        var section: String?
        var bodyLines: [String]

        /// `@@ -OLDSTART,OLDLEN +NEWSTART,NEWLEN @@ optional-section`
        /// — exact shape git emits. We always use the explicit
        /// length form (`,LEN`) even when LEN is 1; older git
        /// implementations accept both, but pinning the explicit
        /// form keeps the rebuild deterministic.
        var headerLine: String {
            var line = "@@ -\(oldStart),\(oldLen) +\(newStart),\(newLen) @@"
            if let s = section, !s.isEmpty { line += " \(s)" }
            return line
        }

        /// Build a self-contained patch that applies *just this hunk*
        /// to the file at `path` (relative to the repo root). The
        /// minimum git apply needs is the `--- a/<path>` + `+++ b/<path>`
        /// pair followed by the hunk; we don't include the
        /// `diff --git`/`index ...` preamble because those are
        /// metadata that don't affect the apply.
        func minimalPatch(forFilePath path: String) -> String {
            var lines: [String] = []
            lines.append("--- a/\(path)")
            lines.append("+++ b/\(path)")
            lines.append(headerLine)
            lines.append(contentsOf: bodyLines)
            // Trailing newline matters for `git apply` — without it
            // the last body line gets clipped on some git versions.
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Parse a unified-diff text into hunks with full body lines.
    /// Pure: nonisolated, no I/O. Anything outside `@@`-bounded
    /// hunks (the `diff --git` preamble, `Binary files differ`
    /// lines, etc.) is ignored — the caller already knows which
    /// file the diff is for, so file-level headers are noise here.
    nonisolated static func parseHunks(_ diff: String) -> [Hunk] {
        var hunks: [Hunk] = []
        var current: Hunk?
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@ ") {
                if let finished = current { hunks.append(finished) }
                current = parseHunkHeaderForApply(line)
                continue
            }
            // Only collect body lines once a hunk header has opened.
            // This filters out the file-level preamble (`diff --git`,
            // `index abc..def`, `--- a/`, `+++ b/`) before the first
            // `@@`, and any tail noise after the diff ends.
            guard current != nil else { continue }
            if line.hasPrefix(" ") || line.hasPrefix("+") || line.hasPrefix("-")
                || line.hasPrefix("\\") {
                current?.bodyLines.append(line)
            }
        }
        if let last = current { hunks.append(last) }
        return hunks
    }

    /// Header parser shared by `parseHunks` (this file) and the
    /// gutter parser (`GitDiffParser`). They each need slightly
    /// different output — the gutter only wants coords, this path
    /// also needs the section heading — so we keep two parsers
    /// rather than cross-coupling them.
    fileprivate nonisolated static func parseHunkHeaderForApply(_ line: String) -> Hunk? {
        // "@@ -O,L +N,L @@ optional heading"
        let body = line.dropFirst(3)
        guard let endRange = body.range(of: " @@") else { return nil }
        let coords = body[..<endRange.lowerBound]
        let after = body[endRange.upperBound...]
        let parts = coords.split(separator: " ")
        guard parts.count == 2,
              parts[0].hasPrefix("-"),
              parts[1].hasPrefix("+") else { return nil }
        guard let oldPair = parseLengthPair(String(parts[0].dropFirst())),
              let newPair = parseLengthPair(String(parts[1].dropFirst())) else {
            return nil
        }
        let section = after.trimmingCharacters(in: .whitespaces)
        return Hunk(oldStart: oldPair.start,
                    oldLen: oldPair.len,
                    newStart: newPair.start,
                    newLen: newPair.len,
                    section: section.isEmpty ? nil : section,
                    bodyLines: [])
    }

    /// "5,3" → (5, 3); "5" → (5, 1); "5,0" → (5, 0). Same shape
    /// `GitDiffParser` uses; duplicated here because `GitDiffParser`'s
    /// version is fileprivate and we want to keep both modules
    /// independently testable.
    fileprivate nonisolated static func parseLengthPair(_ s: String) -> (start: Int, len: Int)? {
        let parts = s.split(separator: ",")
        guard let first = parts.first, let start = Int(first) else { return nil }
        if parts.count == 1 { return (start, 1) }
        guard parts.count == 2, let len = Int(parts[1]) else { return nil }
        return (start, len)
    }

    /// `git diff [--cached] -U3 -- <path>`. Phase 35b-3 — per-hunk
    /// stage needs the **context-bearing** form so a hunk extracted
    /// from one place in the file can be located by `git apply`.
    /// `cached: true` diffs index-vs-HEAD (the source of "unstage
    /// hunk"); `cached: false` diffs working-tree-vs-index (the
    /// source of "stage hunk").
    nonisolated static func diffForApply(path: String,
                                         repo: URL,
                                         cached: Bool) -> UnifiedDiffResult {
        var args: [String] = ["diff", "--no-color", "--no-ext-diff", "-U3"]
        if cached { args.append("--cached") }
        args.append(contentsOf: ["--", path])
        switch run(args, cwd: repo) {
        case .success(let out): return .diff(out)
        case .failure(let err): return .error(err)
        }
    }

    /// Apply `patch` against the repo's *index* (not the working
    /// tree). `reverse == true` undoes a hunk that's already in the
    /// index — that's the unstage path. We always go through the
    /// stdin pipe (`-`) so multi-line / Unicode patches don't
    /// collide with macOS argv limits.
    nonisolated static func applyPatch(_ patch: String,
                                       repo: URL,
                                       reverse: Bool) -> WriteResult {
        var args: [String] = ["apply", "--cached", "--whitespace=nowarn"]
        if reverse { args.append("--reverse") }
        args.append("-")    // read patch from stdin
        let result = runWithStdin(args, stdin: patch, cwd: repo)
        switch result {
        case .success: return .ok
        case .failure(let err): return .error(err)
        }
    }

    /// Walk parent directories until we find one containing `.git`.
    /// `.git` may be a directory (normal repo) or a regular file
    /// (worktree / submodule pointing back to the gitdir).
    nonisolated static func findRepoRoot(for url: URL) -> URL? {
        let fm = FileManager.default
        var dir = url
        // Start from the file's parent if `url` itself is a file.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir),
           !isDir.boolValue {
            dir = dir.deletingLastPathComponent()
        }
        // Bound the walk so a path with no git ancestor doesn't spin
        // up the whole filesystem.
        for _ in 0..<64 {
            let candidate = dir.appendingPathComponent(".git")
            if fm.fileExists(atPath: candidate.path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }   // hit /
            dir = parent
        }
        return nil
    }

    // MARK: - Internals

    private enum RunResult {
        case success(String)
        case failure(String)    // git's stderr / "non-zero exit" message
    }

    /// Run `git <args>` with cwd `cwd`. Captures stdout on success and
    /// stderr on failure; both are stripped of the trailing newline that
    /// every git command appends.
    private nonisolated static func run(_ args: [String],
                                        cwd: URL) -> RunResult {
        let task = Process()
        task.currentDirectoryURL = cwd
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        task.standardInput = FileHandle.nullDevice
        // Don't let the user's GIT_PAGER or rebase-in-progress hooks
        // hijack our subprocess.
        var env = ProcessInfo.processInfo.environment
        env["GIT_PAGER"] = "cat"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        task.environment = env

        do {
            try task.run()
        } catch {
            return .failure("Couldn't launch git: \(error.localizedDescription)")
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        if task.terminationStatus == 0 {
            return .success(String(data: outData, encoding: .utf8) ?? "")
        }
        let msg = String(data: errData, encoding: .utf8) ?? ""
        return .failure(msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Phase 35b-2b — like `run` but pipes `stdin` into the spawned
    /// process. Used for `git commit -F -` so the message round-
    /// trips losslessly even when it's many KiB or contains
    /// arbitrary multi-byte text. Caller passes the raw message
    /// string; UTF-8 encoding happens here once.
    ///
    /// Why not just expand `run` to take an optional stdin:
    ///   `run` is on every read code path (status / diff / blob)
    ///   and adding a parameter would force every existing call
    ///   to carry an extra `nil`. Splitting keeps the read API
    ///   pristine.
    private nonisolated static func runWithStdin(_ args: [String],
                                                 stdin input: String,
                                                 cwd: URL) -> RunResult {
        let task = Process()
        task.currentDirectoryURL = cwd
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        task.standardInput = stdin
        var env = ProcessInfo.processInfo.environment
        env["GIT_PAGER"] = "cat"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        task.environment = env

        do {
            try task.run()
        } catch {
            return .failure("Couldn't launch git: \(error.localizedDescription)")
        }
        // Feed the message in, then close the write end so git sees EOF
        // and stops reading. Closing matters: without it `git commit -F -`
        // would block forever waiting for more input.
        if let data = input.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        try? stdin.fileHandleForWriting.close()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        if task.terminationStatus == 0 {
            return .success(String(data: outData, encoding: .utf8) ?? "")
        }
        let msg = String(data: errData, encoding: .utf8) ?? ""
        return .failure(msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Repo-relative path. Falls back to the absolute path if the file
    /// somehow isn't inside the repo (shouldn't happen since
    /// findRepoRoot already returned that root, but defensive).
    private nonisolated static func relativize(path: String,
                                               from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        if path.hasPrefix(rootPath) {
            return String(path.dropFirst(rootPath.count))
        }
        return path
    }
}
