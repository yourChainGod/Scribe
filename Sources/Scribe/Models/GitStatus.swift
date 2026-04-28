//
//  GitStatus.swift
//  Phase 35b-1 — model types behind the Source Control sidebar.
//  zed surfaces a "Git Panel" that lists every changed file in the
//  repo with stage/unstage/discard affordances; this commit ships the
//  read-only data layer (parser + engine + view) so the writes from
//  35b-2 land on a stable foundation.
//
//  Why a separate file (not piggy-backed onto GitClient):
//    `GitClient` is a thin shell-out facade; everything in there is
//    `nonisolated` + sync. The model types here are pure value types
//    that other Sources can reference without dragging git CLI
//    semantics into their type space.
//

import Foundation

/// One row in the porcelain v1 output of `git status -z`. Each
/// physical file in the repo with any deviation from HEAD shows up
/// once; rename detection coalesces both halves of a rename into
/// the same status (origin path is captured for display).
///
/// `Identifiable` keys off `path` rather than `url` so SwiftUI
/// `ForEach` keeps stable row identity even if the same path moves
/// between sections (e.g. modified → staged) on refresh.
struct GitFileStatus: Equatable, Sendable, Identifiable {

    /// Repo-relative POSIX path. Always forward-slash separated and
    /// matches what `git status` printed verbatim (no normalisation),
    /// so re-feeding this to `git apply --cached` round-trips.
    let path: String

    /// Absolute file URL on disk. Resolved against the repo root at
    /// parse time so the sidebar's "click to open" doesn't have to
    /// re-stat the path. nil when the file was renamed *out* of
    /// disk (rename / delete combinations).
    let url: URL

    /// Status code from the X (index / staged) column of porcelain.
    let staged: GitChangeKind

    /// Status code from the Y (working tree / unstaged) column.
    let unstaged: GitChangeKind

    /// Original repo-relative path for renames / copies. nil for
    /// every other status. The sidebar shows it as `oldName → newName`
    /// when present.
    let originalPath: String?

    /// `true` iff XY indicates an active merge conflict. The full
    /// conflict matrix from gitdocs:
    ///   DD UD AU UD UA AA UU
    /// We compute it once at parse time so the SwiftUI view stays
    /// trivial.
    var isConflict: Bool {
        switch (staged, unstaged) {
        case (.deleted, .deleted),
             (.added, .added),
             (.unmerged, .unmerged),
             (.unmerged, _), (_, .unmerged):
            return true
        default:
            return false
        }
    }

    /// True iff the file has staged changes (X column ≠ unmodified
    /// and ≠ untracked). Drives whether the row appears in the
    /// "Staged" section of the sidebar.
    var hasStagedChanges: Bool {
        switch staged {
        case .unmodified, .untracked, .ignored: return false
        default: return true
        }
    }

    /// True iff the file has working-tree changes (Y column ≠
    /// unmodified). Drives whether the row appears in the "Changes"
    /// section.
    var hasUnstagedChanges: Bool {
        switch unstaged {
        case .unmodified, .ignored: return false
        default: return true
        }
    }

    /// True iff X is `?`. Untracked files get their own section in
    /// the sidebar so a fresh `mkdir foo && touch foo/bar` doesn't
    /// drown the actually-modified list.
    var isUntracked: Bool {
        staged == .untracked
    }

    var id: String { path }
}

/// Single-character change kinds from porcelain v1. Two of these
/// stack into a row's XY pair (X = staged, Y = unstaged).
///
/// The unknown case absorbs any future git versions adding new
/// codes; we'd rather render a row as "unknown change" than crash
/// the sidebar on an unrecognised glyph.
enum GitChangeKind: Sendable, Equatable, Hashable {
    case unmodified     // ' '
    case modified       // 'M'
    case added          // 'A'
    case deleted        // 'D'
    case renamed        // 'R'
    case copied         // 'C'
    case typeChanged    // 'T'  (e.g. file → symlink)
    case unmerged       // 'U'
    case untracked      // '?'
    case ignored        // '!'
    case unknown(Character)

    init(porcelain code: Character) {
        switch code {
        case " ": self = .unmodified
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .unmerged
        case "?": self = .untracked
        case "!": self = .ignored
        default:  self = .unknown(code)
        }
    }

    /// Single-character glyph used in the sidebar. Mirrors what
    /// `git status -s` prints so users coming from the CLI don't
    /// have to learn a second vocabulary.
    var glyph: String {
        switch self {
        case .unmodified:        return " "
        case .modified:          return "M"
        case .added:             return "A"
        case .deleted:           return "D"
        case .renamed:           return "R"
        case .copied:            return "C"
        case .typeChanged:       return "T"
        case .unmerged:          return "U"
        case .untracked:         return "?"
        case .ignored:           return "!"
        case .unknown(let ch):   return String(ch)
        }
    }
}

/// Phase 35b-4-b — one file's contribution to the Project Diff
/// multibuffer. Carries both the staged (index-vs-HEAD) and the
/// working-tree (working-vs-index) hunk lists so the multibuffer
/// view can render them in two visually-distinct strips per file
/// without re-running git itself. Files with no hunks on either
/// side never end up in `GitStatusEngine.projectDiff()`'s output —
/// the filter happens upstream so the SwiftUI side stays trivial.
///
/// `Identifiable` keys off `path` so a file moving between staged-
/// only and unstaged-only between refreshes still keeps the same
/// SwiftUI row identity (and any expand / scroll state attached
/// to it).
struct ProjectDiffEntry: Equatable, Sendable, Identifiable {
    /// Repo-relative POSIX path (matches `GitFileStatus.path`).
    let path: String
    /// Absolute file URL — handy for the "Open File" jump button
    /// without re-resolving against the repo root.
    let url: URL
    /// Hunks reported by `git diff --cached` for this file. Apply-
    /// reverse on these unstages them.
    let stagedHunks: [GitClient.Hunk]
    /// Hunks reported by `git diff` (no `--cached`) for this file.
    /// Apply-forward on these stages them.
    let workingHunks: [GitClient.Hunk]

    var id: String { path }

    /// True when neither hunk list has anything — used by the
    /// engine to drop entries before they reach the view.
    var isEmpty: Bool {
        stagedHunks.isEmpty && workingHunks.isEmpty
    }
}
