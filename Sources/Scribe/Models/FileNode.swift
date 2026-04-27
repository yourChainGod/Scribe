//
//  FileNode.swift
//  Lazy file tree node — children loaded on demand.
//

import Foundation

final class FileNode: ObservableObject, Identifiable, @unchecked Sendable {
    let url: URL
    let isDirectory: Bool
    @Published var children: [FileNode]?
    @Published var isExpanded: Bool = false

    nonisolated var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.url = url
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
    }

    /// Lazily load children. Skips dotfiles by default.
    func loadChildren() {
        guard isDirectory, children == nil else { return }
        children = readChildren()
    }

    /// Recursively re-scan children, preserving the existing expansion
    /// state so a `git checkout` doesn't collapse every disclosure
    /// triangle the user had opened. New directories on disk show up
    /// collapsed; vanished ones drop out; existing-but-renamed kids
    /// look like a delete + an add (good enough — true diff-aware
    /// reconciliation is overkill for a sidebar).
    func reload() {
        guard isDirectory else { return }
        let oldByURL: [URL: FileNode] = Dictionary(
            uniqueKeysWithValues: (children ?? []).map { ($0.url, $0) }
        )
        let fresh = readChildren()
        for node in fresh {
            if let prior = oldByURL[node.url], prior.isExpanded {
                node.isExpanded = true
                // Preserve children if the prior load already expanded
                // them, then recurse to pick up nested external changes.
                node.children = prior.children
                node.reload()
            }
        }
        children = fresh
    }

    private func readChildren() -> [FileNode] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .map { FileNode(url: $0) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}
