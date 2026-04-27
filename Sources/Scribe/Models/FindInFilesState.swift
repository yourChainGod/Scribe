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

    /// True if `url` is currently included in a Replace All pass.
    func isSelected(_ url: URL) -> Bool {
        !excludedURLs.contains(url)
    }

    /// Toggle a single file's inclusion.
    func toggleSelection(_ url: URL) {
        if excludedURLs.contains(url) {
            excludedURLs.remove(url)
        } else {
            excludedURLs.insert(url)
        }
    }

    /// Mark every current result as selected.
    func selectAll() {
        excludedURLs = []
    }

    /// Mark every current result as deselected.
    func deselectAll() {
        excludedURLs = Set(results.map(\.url))
    }

    /// URLs that will actually be touched by a Replace All right now.
    /// Drops the order from `results` so callers don't have to.
    var selectedURLs: [URL] {
        results.map(\.url).filter { !excludedURLs.contains($0) }
    }

    /// Aggregate match count across the currently-selected files only.
    /// Drives the "Replace N matches in M files" hint.
    var selectedMatchCount: Int {
        results.reduce(0) {
            excludedURLs.contains($1.url) ? $0 : $0 + $1.matches.count
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
        // "re-include itself" if it shows up again later.
        if !excludedURLs.isEmpty {
            let newURLs = Set(results.map(\.url))
            excludedURLs.formIntersection(newURLs)
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
    }
}
