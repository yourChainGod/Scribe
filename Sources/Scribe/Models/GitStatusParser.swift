//
//  GitStatusParser.swift
//  Phase 35b-1 — pure parser for `git status -z --porcelain=v1`.
//  Mirrors how Phase 31 split GitDiffParser out of GitClient: the
//  string transform is fully testable without a live filesystem,
//  and the engine that drives it stays trivially small.
//
//  Why porcelain v1 + `-z`:
//    - v1 is the only stable porcelain format git promises across
//      versions.
//    - `-z` separates entries with NUL instead of newline so paths
//      containing whitespace / quoted characters round-trip
//      losslessly. The default newline-separated output mangles such
//      paths and we'd have to re-implement git's quoting reverse.
//
//  Output format (one entry):
//      XY <space> path \0
//  Renames / copies expand to two NUL-terminated tokens:
//      XY <space> new_path \0 old_path \0
//  We detect the rename/copy case by inspecting X (staged column)
//  and consume the orig path from the same iterator.
//

import Foundation

enum GitStatusParser {

    /// Parse the raw stdout of `git status -z --porcelain=v1` (or
    /// `--porcelain` — same format).
    /// `repoRoot` is used to resolve repo-relative paths to absolute
    /// URLs at parse time so callers don't have to re-stat. Returns
    /// an empty array when input is empty or malformed; we'd rather
    /// silently render an empty sidebar than crash on unexpected git
    /// output (the same robustness contract GitDiffParser has).
    static func parse(_ raw: String, repoRoot: URL) -> [GitFileStatus] {
        guard !raw.isEmpty else { return [] }

        // `-z` separates entries with NUL. The trailing entry also
        // ends with NUL, so split keeps a final empty component we
        // strip via the `omittingEmptySubsequences` filter.
        let parts = raw.split(separator: "\0",
                              omittingEmptySubsequences: true)
        var iter = parts.makeIterator()
        var out: [GitFileStatus] = []

        while let chunk = iter.next() {
            // Each entry must be at least 4 chars: "XY <sp> p".
            guard chunk.count >= 4 else { continue }
            let xy = chunk.prefix(2)
            // Skip the single space after XY; from index 3 to end
            // is the (possibly-renamed) path.
            let pathStart = chunk.index(chunk.startIndex, offsetBy: 3)
            let path = String(chunk[pathStart...])

            let xChar = xy[xy.startIndex]
            let yChar = xy[xy.index(after: xy.startIndex)]
            let staged   = GitChangeKind(porcelain: xChar)
            let unstaged = GitChangeKind(porcelain: yChar)

            // Renames / copies bring an additional original-path
            // token. Either column can carry the indicator (R in X
            // for staged renames, R in Y for unstaged renames; the
            // latter requires `core.renames=true` plus a working-
            // tree rename detection, which is git's default).
            var originalPath: String? = nil
            if staged == .renamed || staged == .copied
                || unstaged == .renamed || unstaged == .copied,
               let origin = iter.next() {
                originalPath = String(origin)
            }

            let absURL = repoRoot.appendingPathComponent(path)
                .standardizedFileURL

            out.append(GitFileStatus(
                path: path,
                url: absURL,
                staged: staged,
                unstaged: unstaged,
                originalPath: originalPath
            ))
        }
        return out
    }
}
