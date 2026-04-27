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
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let nodes = contents
            .map { FileNode(url: $0) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        self.children = nodes
    }
}
