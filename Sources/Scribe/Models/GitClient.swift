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
