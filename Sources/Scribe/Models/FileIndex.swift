//
//  FileIndex.swift
//  Phase 6 — keeps a flat list of every "interesting" file under the
//  current workspace root so Quick Open File (⌘P) can fuzzy-match
//  against it instantly. Walks off the main thread and republishes
//  results when the workspace root changes.
//
//  Not used for the file tree (that has its own lazy node model in
//  FileNode); this is purely the search index.
//

import Foundation

@MainActor
final class FileIndex: ObservableObject {
    /// Flat list of regular files under `rootURL`. Empty until the
    /// first scan completes; updates atomically when the scan finishes.
    @Published private(set) var files: [URL] = []

    /// True between `rebuild(at:)` and the corresponding scan finishing.
    @Published private(set) var isIndexing: Bool = false

    /// Current root the index reflects. nil if no folder is open.
    private(set) var rootURL: URL?

    /// Sanity cap so a misconfigured open of `/` doesn't burn unbounded
    /// memory. 200k is well past the size of any sensible repo and keeps
    /// the in-memory ScribeCommand[] under a few hundred MB even with
    /// long paths. nonisolated because `walk` runs off the main actor.
    nonisolated static let maxFiles: Int = 200_000

    private var rebuildTask: Task<Void, Never>?

    /// Workspace-wide FS watcher. Created when rebuild(at:) starts a
    /// fresh root and torn down by clear(). Triggers a debounced
    /// rebuild on any external file-tree change (`git checkout`,
    /// `mv`, an editor outside Scribe writing a new file, …).
    private var watcher: DirectoryWatcher?

    /// Hook for the host app to run extra work whenever the index
    /// gets refreshed because of a file-system change. Set by ScribeApp
    /// to also reload the FileNode tree so the sidebar stays in sync.
    var onFileSystemChange: (@MainActor () -> Void)?

    // MARK: - Public surface

    /// Kick off a (re)scan rooted at `root`. Cancels any in-flight scan
    /// and (re)attaches the FSEvents watcher so subsequent external
    /// changes auto-rebuild without needing the user to re-open the
    /// folder. Calling rebuild(at:) with the same root just refreshes
    /// the index — the watcher gets recreated either way to make
    /// filesystem-restart edge cases (network volume, encrypted disk
    /// mount) recoverable.
    func rebuild(at root: URL) {
        rebuildTask?.cancel()
        watcher = nil   // tear down the previous root's watcher first
        rootURL = root
        files = []
        isIndexing = true

        rebuildTask = Task { [weak self, root] in
            // Heavy lifting on a background thread — the walk is mostly
            // syscall-bound but the result array can be sizeable.
            let collected: [URL] = await Task.detached(priority: .userInitiated) {
                Self.walk(root: root)
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.rootURL == root else { return }   // stale scan
                self.files = collected
                self.isIndexing = false
            }
        }

        // Start the FS watcher AFTER kicking off the initial scan so
        // we don't miss files that landed in the millisecond between
        // `walk` reading the directory and the watcher activating.
        // FSEvents tolerates the ordering either way; we just stay on
        // the safe side.
        watcher = DirectoryWatcher(url: root) { [weak self] in
            self?.handleFSChange()
        }
    }

    /// Forget the current scan. Workspace closes the folder ⇒ index goes
    /// empty so ⌘P shows nothing.
    func clear() {
        rebuildTask?.cancel()
        rebuildTask = nil
        watcher = nil
        rootURL = nil
        files = []
        isIndexing = false
    }

    /// FSEvents → debounced → here. Re-walk the tree using the same
    /// root we already have, then notify the host app so it can
    /// refresh anything else that mirrors the workspace state
    /// (e.g. the FileNode-backed sidebar tree).
    private func handleFSChange() {
        guard let root = rootURL else { return }
        rebuildTask?.cancel()
        isIndexing = true
        rebuildTask = Task { [weak self, root] in
            let collected: [URL] = await Task.detached(priority: .userInitiated) {
                Self.walk(root: root)
            }.value
            await MainActor.run { [weak self] in
                guard let self, self.rootURL == root else { return }
                self.files = collected
                self.isIndexing = false
                self.onFileSystemChange?()
            }
        }
    }

    // MARK: - File walk

    /// Off-main file walker. Pure (no `self` reference) so it can run on
    /// a detached priority pool without crossing the @MainActor boundary.
    nonisolated static func walk(root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var out: [URL] = []
        out.reserveCapacity(2048)

        for case let url as URL in enumerator {
            if Task.isCancelled { return out }

            let name = url.lastPathComponent
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                if IgnoredPaths.shouldSkipDirectory(named: name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            // Skip hidden files at any depth — they almost never matter
            // for Quick Open and pollute the fuzzy match.
            if name.hasPrefix(".") { continue }

            out.append(url)
            if out.count >= maxFiles { break }
        }
        return out
    }
}
