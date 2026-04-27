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
