//
//  IgnoredPaths.swift
//  Phase 6 — single source of truth for "directories Scribe should not
//  traverse during workspace-wide operations". Used by Find-in-Files,
//  Quick Open File, and (eventually) the file-watcher.
//
//  Keeping this list in one place avoids the bug where one feature
//  picks up node_modules but another doesn't.
//

import Foundation

enum IgnoredPaths {
    /// Last-path-component matches that prune the whole subtree.
    static let directories: Set<String> = [
        ".git", ".svn", ".hg", ".jj",
        ".build", ".swiftpm", "DerivedData", "Pods",
        "node_modules", ".next", ".nuxt", ".turbo", ".cache",
        "target", "dist", "build", "out",
        "__pycache__", ".venv", "venv",
        ".idea", ".vscode"
    ]

    /// True when a directory's last path component should be skipped
    /// outright. Covers both the curated set above and any dotfile
    /// directory (`.git`, `.cache`, …) regardless of whether it's in
    /// the curated list — workspace operations rarely benefit from
    /// recursing into hidden directories.
    static func shouldSkipDirectory(named name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        return directories.contains(name)
    }
}
