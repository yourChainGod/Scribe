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
    }
}
