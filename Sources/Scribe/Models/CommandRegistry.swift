//
//  CommandRegistry.swift
//  Phase 3 — central registry of user-invokable actions surfaced through
//  the Command Palette (⌘⇧P). Also drives a Sublime-style fuzzy search
//  against `title` + `subtitle` + `keywords`.
//
//  We deliberately keep "command" plain Swift values rather than tying
//  them to SwiftUI Commands so that they can be invoked from anywhere
//  (palette, status bar, future scripting) without the SwiftUI
//  environment chain.
//

import Foundation

/// One user-invokable action.
struct ScribeCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let keywords: [String]
    let perform: @MainActor () -> Void

    init(id: String,
         title: String,
         subtitle: String? = nil,
         keywords: [String] = [],
         perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.perform = perform
    }
}

/// Result of `CommandRegistry.search` — keeps the matched ranges so the
/// palette UI can highlight them in the title.
struct CommandMatch: Identifiable {
    let command: ScribeCommand
    let score: Double
    /// Indices into `command.title` where the query characters landed.
    /// `nil` for matches that come from `keywords` only.
    let highlightedRanges: [Range<String.Index>]?

    var id: String { command.id }
}

/// Routes a query starting with `prefix` to a different CommandRegistry.
/// Used by Phase 11 ⌘P @symbol so a single palette window can switch
/// between file picker (default) and symbol picker (prefix "@") without
/// the host having to teardown / rebuild the panel itself.
struct PrefixRoute: Identifiable {
    let id: String
    let prefix: String
    /// The sub-registry that owns the commands surfaced under this
    /// prefix. The palette never observes this object directly, so the
    /// caller must finish populating it BEFORE attaching the route.
    let registry: CommandRegistry
    /// Placeholder displayed in the search field while this route is
    /// active. nil ⇒ caller-supplied default.
    let placeholder: String?
}

@MainActor
final class CommandRegistry: ObservableObject {
    /// Live snapshot of every registered command. Rebuilt by callers
    /// whenever the surface changes (e.g. open documents, lexers).
    @Published var commands: [ScribeCommand] = []

    /// Optional sub-registries activated by query prefix. Searched in
    /// order, first matching prefix wins. Empty ⇒ classic single-mode
    /// registry (every Phase < 11 caller).
    @Published var prefixRoutes: [PrefixRoute] = []

    /// MRU stack of command IDs. Capped at 50; in-memory only for now —
    /// persistence can come later if it proves useful.
    private var mru: [String] = []
    private let mruCap = 50

    // MARK: - Mutation

    func register(_ command: ScribeCommand) {
        commands.removeAll { $0.id == command.id }
        commands.append(command)
    }

    func register(_ batch: [ScribeCommand]) {
        for c in batch { register(c) }
    }

    func unregister(id: String) {
        commands.removeAll { $0.id == id }
    }

    /// Replace every dynamic command whose id starts with `prefix` with
    /// `batch`. Keeps the registry tidy when the surface (open tabs, open
    /// folder, encodings…) changes — the caller sweeps a single prefix
    /// rather than tracking ids one by one.
    func replaceAll(withPrefix prefix: String, with batch: [ScribeCommand]) {
        commands.removeAll { $0.id.hasPrefix(prefix) }
        commands.append(contentsOf: batch)
    }

    // MARK: - Invocation

    func invoke(_ command: ScribeCommand) {
        command.perform()
        bump(command.id)
    }

    private func bump(_ id: String) {
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        if mru.count > mruCap { mru = Array(mru.prefix(mruCap)) }
    }

    // MARK: - Search

    /// First prefix route that matches `query`, or nil if `query` has
    /// no prefix routing. Pure read — view code uses this for the
    /// effective placeholder, search uses it to dispatch.
    func activeRoute(for query: String) -> PrefixRoute? {
        prefixRoutes.first { query.hasPrefix($0.prefix) }
    }

    /// Returns commands ranked by relevance to `query`. Empty query
    /// returns every command, MRU first. If `query` starts with a
    /// registered prefix, defers to the corresponding sub-registry
    /// with the prefix stripped.
    func search(_ query: String) -> [CommandMatch] {
        if let route = activeRoute(for: query) {
            let stripped = String(query.dropFirst(route.prefix.count))
            return route.registry.search(stripped)
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return commands
                .sorted { lhs, rhs in
                    let li = mru.firstIndex(of: lhs.id) ?? .max
                    let ri = mru.firstIndex(of: rhs.id) ?? .max
                    if li != ri { return li < ri }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                .map { CommandMatch(command: $0, score: 0, highlightedRanges: nil) }
        }
        var matches: [CommandMatch] = []
        for cmd in commands {
            if let hit = Self.fuzzyMatch(query: trimmed, against: cmd.title) {
                let mruBoost = mruIndex(of: cmd.id).map { 50.0 / Double($0 + 1) } ?? 0
                matches.append(CommandMatch(
                    command: cmd,
                    score: hit.score + mruBoost,
                    highlightedRanges: hit.ranges
                ))
                continue
            }
            // Fall back to keywords / subtitle — accepted but never
            // highlighted in the title.
            let haystack = ([cmd.subtitle].compactMap { $0 } + cmd.keywords).joined(separator: " ")
            if let hit = Self.fuzzyMatch(query: trimmed, against: haystack) {
                let mruBoost = mruIndex(of: cmd.id).map { 25.0 / Double($0 + 1) } ?? 0
                matches.append(CommandMatch(
                    command: cmd,
                    score: hit.score * 0.4 + mruBoost,   // de-emphasised vs title hits
                    highlightedRanges: nil
                ))
            }
        }
        return matches.sorted { $0.score > $1.score }
    }

    private func mruIndex(of id: String) -> Int? {
        mru.firstIndex(of: id)
    }

    // MARK: - Fuzzy matcher

    private struct FuzzyHit {
        let score: Double
        let ranges: [Range<String.Index>]
    }

    /// Sublime-style fuzzy match: every char in `query` must appear in
    /// order in `haystack` (case-insensitive). Score rewards consecutive
    /// runs and word-boundary starts; penalises gaps.
    private static func fuzzyMatch(query: String, against haystack: String) -> FuzzyHit? {
        guard !query.isEmpty, !haystack.isEmpty else { return nil }
        let q = Array(query.lowercased())
        let hay = Array(haystack.lowercased())
        var qi = 0
        var hi = 0
        var matchedIndices: [Int] = []
        var lastMatchIndex = -2
        var consecutiveBonus = 0.0
        var score = 0.0

        while qi < q.count, hi < hay.count {
            if q[qi] == hay[hi] {
                matchedIndices.append(hi)

                // Word-boundary bonus.
                let isStart = (hi == 0) || hay[hi - 1] == " " || hay[hi - 1] == "_" || hay[hi - 1] == "-" || hay[hi - 1] == "/"
                if isStart { score += 5 }

                // Consecutive-run bonus.
                if hi == lastMatchIndex + 1 {
                    consecutiveBonus += 2
                    score += consecutiveBonus
                } else {
                    consecutiveBonus = 0
                }

                // Gap penalty (small).
                let gap = hi - max(lastMatchIndex, 0)
                if lastMatchIndex >= 0 { score -= Double(min(gap, 5)) * 0.2 }

                score += 1   // base point per matched char
                lastMatchIndex = hi
                qi += 1
            }
            hi += 1
        }
        guard qi == q.count else { return nil }   // not all query chars consumed

        // Length-normalisation: short haystacks score higher than long ones
        // for the same hit pattern.
        score += max(0.0, 10.0 - Double(haystack.count) * 0.1)

        // Convert haystack-int indices back to String.Index ranges.
        let ranges: [Range<String.Index>] = matchedIndices.compactMap { i in
            guard let idx = haystack.index(haystack.startIndex, offsetBy: i, limitedBy: haystack.endIndex),
                  let next = haystack.index(idx, offsetBy: 1, limitedBy: haystack.endIndex) else {
                return nil
            }
            return idx..<next
        }
        return FuzzyHit(score: score, ranges: ranges)
    }
}
