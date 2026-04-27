//
//  FindInFilesState.swift
//  Phase 4b — observable state behind ⌘⇧F. The engine that does the
//  actual searching lives in FindInFilesEngine; this struct is purely
//  the UI mirror.
//

import Foundation

/// One match inside a single file, scoped to one source line.
struct LineMatch: Identifiable, Hashable, Sendable {
    let lineNumber: Int               // 1-based, matches Scintilla
    let lineText: String              // already trimmed of trailing CR/LF
    /// Character offsets (UTF-16 indices into `lineText`) of the matched
    /// span. SwiftUI AttributedString handles them natively.
    let matchRanges: [Range<Int>]

    var id: String { "\(lineNumber)-\(matchRanges.first?.lowerBound ?? 0)" }
}

/// All matches discovered inside a single file.
struct FileResult: Identifiable, Hashable, Sendable {
    let url: URL
    let matches: [LineMatch]
    var id: URL { url }
}

@MainActor
final class FindInFilesState: ObservableObject {
    @Published var query: String = ""
    @Published var matchCase: Bool = false
    @Published var wholeWord: Bool = false
    @Published var regex: Bool = false

    /// Replace text. Empty ⇒ Replace-All button is disabled. The sidebar
    /// also collapses the row into the search box when this is empty so
    /// the UI doesn't grow vertically until the user actually wants to
    /// replace.
    @Published var replacement: String = ""

    /// True while replaceAll is in flight. Locks out new searches and
    /// shows a different progress indicator.
    @Published private(set) var isReplacing: Bool = false

    /// Plain-text summary of the most recent replace pass — populated
    /// by FindInFilesSidebar after the engine reports back. Cleared
    /// when a new search starts.
    @Published var lastReplaceSummary: String? = nil

    /// Glob-style include / exclude patterns, comma-separated. Empty
    /// fields disable the filter.
    @Published var includeGlob: String = ""
    @Published var excludeGlob: String = ""

    @Published private(set) var results: [FileResult] = []
    @Published private(set) var totalMatches: Int = 0
    @Published private(set) var filesScanned: Int = 0
    @Published private(set) var filesWithMatches: Int = 0
    @Published private(set) var isSearching: Bool = false
    @Published var error: String? = nil

    /// True after the user runs at least one search this session — drives
    /// the empty-state copy in the sidebar.
    @Published private(set) var hasRun: Bool = false

    /// Per-file expanded state in the result tree. Defaulted to `true`;
    /// users can collapse a noisy file from the disclosure header.
    @Published var expanded: Set<URL> = []

    /// Phase 16 — files the user has explicitly opted OUT of replace.
    /// Default is "everything is selected": empty set ⇒ Replace acts on
    /// every result. Storing the *negation* keeps a fresh search from
    /// silently leaving every result unselected — newly-discovered
    /// files are included by default, which matches what users expect
    /// from the Code/Sublime equivalents.
    @Published var excludedURLs: Set<URL> = []

    /// Phase 17 — line-level inclusion overrides. Keyed by URL ⇒
    /// 1-based line numbers the user opted OUT of within that file.
    /// Same negation convention as `excludedURLs`. A file with every
    /// line unticked is *not* automatically promoted into
    /// `excludedURLs`; the file checkbox stays as the user left it,
    /// the per-row checkboxes drive the "what gets touched" count.
    @Published var excludedLines: [URL: Set<Int>] = [:]

    /// True if `url` is currently included in a Replace All pass.
    func isSelected(_ url: URL) -> Bool {
        !excludedURLs.contains(url)
    }

    /// True if a specific line within `url` is currently slated for
    /// replacement. Excluding the parent file shadows any line state.
    func isLineSelected(_ url: URL, line: Int) -> Bool {
        if excludedURLs.contains(url) { return false }
        return !(excludedLines[url]?.contains(line) ?? false)
    }

    /// Toggle a single file's inclusion.
    func toggleSelection(_ url: URL) {
        if excludedURLs.contains(url) {
            excludedURLs.remove(url)
        } else {
            excludedURLs.insert(url)
        }
    }

    /// Toggle a specific line's inclusion within a file. The file's
    /// own selection bit is left alone — the user can opt back into
    /// "include the file but skip these N lines" by unticking the
    /// rows individually.
    func toggleLineSelection(_ url: URL, line: Int) {
        var set = excludedLines[url] ?? []
        if set.contains(line) {
            set.remove(line)
        } else {
            set.insert(line)
        }
        if set.isEmpty {
            excludedLines.removeValue(forKey: url)
        } else {
            excludedLines[url] = set
        }
    }

    /// Mark every current result as selected.
    func selectAll() {
        excludedURLs = []
        excludedLines = [:]
    }

    /// Mark every current result as deselected.
    func deselectAll() {
        excludedURLs = Set(results.map(\.url))
    }

    /// URLs that will actually be touched by a Replace All right now.
    /// A file is "touched" when (a) the file checkbox is on AND
    /// (b) at least one of its lines is also on.
    var selectedURLs: [URL] {
        results.compactMap { file in
            guard !excludedURLs.contains(file.url) else { return nil }
            let excludedSet = excludedLines[file.url] ?? []
            let anyLineKept = file.matches.contains { !excludedSet.contains($0.lineNumber) }
            return anyLineKept ? file.url : nil
        }
    }

    /// Per-URL set of line numbers to skip during Replace. Driven by
    /// `excludedLines` on selected files only — a file whose top-level
    /// checkbox is off doesn't need an entry here because the engine
    /// won't be called against it in the first place.
    var excludedLinesByURL: [URL: Set<Int>] {
        var out: [URL: Set<Int>] = [:]
        for (url, set) in excludedLines where !set.isEmpty {
            if !excludedURLs.contains(url) {
                out[url] = set
            }
        }
        return out
    }

    /// Aggregate match count across the currently-selected files /
    /// lines. Drives the "Replace N matches in M files" hint.
    var selectedMatchCount: Int {
        results.reduce(0) { acc, file in
            guard !excludedURLs.contains(file.url) else { return acc }
            let excludedSet = excludedLines[file.url] ?? []
            return acc + file.matches.reduce(0) { lineAcc, match in
                excludedSet.contains(match.lineNumber)
                    ? lineAcc
                    : lineAcc + match.matchRanges.count
            }
        }
    }

    /// Set by the engine while it streams results in. The state object
    /// just owns the storage so the engine can be a plain actor.
    func update(results: [FileResult],
                totalMatches: Int,
                filesScanned: Int,
                filesWithMatches: Int) {
        self.results = results
        self.totalMatches = totalMatches
        self.filesScanned = filesScanned
        self.filesWithMatches = filesWithMatches
        // A fresh result set invalidates the previous selection. Drop
        // any excluded URLs that aren't represented in the new tree
        // so an unrelated file from a prior search doesn't quietly
        // "re-include itself" if it shows up again later. Same
        // pruning logic applies to `excludedLines` — both URL keys
        // that vanished and line numbers that no longer match the
        // new result must be cleared so the next search starts
        // from a coherent baseline.
        let newURLs = Set(results.map(\.url))
        if !excludedURLs.isEmpty {
            excludedURLs.formIntersection(newURLs)
        }
        if !excludedLines.isEmpty {
            // Drop URLs that vanished entirely.
            excludedLines = excludedLines.filter { newURLs.contains($0.key) }
            // For URLs still present, intersect line numbers with the
            // new result's line set so a re-run that produces a
            // different match layout doesn't carry over stale rows.
            for file in results {
                guard var lines = excludedLines[file.url] else { continue }
                let newLineSet = Set(file.matches.map(\.lineNumber))
                lines.formIntersection(newLineSet)
                if lines.isEmpty {
                    excludedLines.removeValue(forKey: file.url)
                } else {
                    excludedLines[file.url] = lines
                }
            }
        }
    }

    func setSearching(_ value: Bool) {
        isSearching = value
        if value { hasRun = true }
    }

    /// Engine-facing flag. The summary text is published separately
    /// once the replace pass completes (see `lastReplaceSummary`).
    func setReplacing(_ value: Bool) {
        isReplacing = value
    }

    func reset() {
        results = []
        totalMatches = 0
        filesScanned = 0
        filesWithMatches = 0
        error = nil
        lastReplaceSummary = nil
        excludedURLs = []
        excludedLines = [:]
    }
}
