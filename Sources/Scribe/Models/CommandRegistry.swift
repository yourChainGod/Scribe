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
    /// Phase 46e — pre-rendered shortcut string (e.g. "⌘S", "⌘⇧T").
    /// The Command Palette row surfaces this as a chip on the
    /// trailing edge so the user can rehearse the key binding
    /// without leaving the palette. `nil` ⇒ no chip drawn (command
    /// has no menu binding, or the binding lives elsewhere in the
    /// responder chain and we don't want to imply the palette
    /// shortcut triggers it).
    let shortcutLabel: String?
    let perform: @MainActor () -> Void

    init(id: String,
         title: String,
         subtitle: String? = nil,
         keywords: [String] = [],
         shortcutLabel: String? = nil,
         perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.shortcutLabel = shortcutLabel
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

/// Phase 46d — one visually separated block of palette matches.
/// `grouped(for:)` returns these; empty-query mode splits into one
/// section per category (File / View / Text / …), non-empty queries
/// collapse into a single anonymous section so the flat fuzzy-
/// ranked output isn't broken up by surprise headers.
struct CommandSection: Identifiable {
    /// Stable id — used both as the ForEach identity and as the
    /// caption key ("" ⇒ no header rendered).
    let id: String
    /// Localised title shown above the section. Empty string ⇒
    /// section renders without a header (non-empty query mode).
    let title: String
    let matches: [CommandMatch]
}

/// Routes a query starting with `prefix` to a different command source.
/// Two flavours:
///   1. Static sub-registry (Phase 11 @symbol): caller pre-populates a
///      CommandRegistry, search routes the stripped query to it.
///   2. Dynamic (Phase 13 :N goto-line): caller supplies a closure that
///      maps the stripped query to a fresh [ScribeCommand]. Used when
///      the result list depends on the query itself rather than being
///      fuzzy-matched against a static set — e.g. ":42" can't be
///      faked by registering 1..N "go to line K" commands ahead of
///      time.
struct PrefixRoute: Identifiable {
    let id: String
    let prefix: String
    /// Optional static sub-registry. If non-nil and `dynamicCommands`
    /// is nil, search() defers to `registry.search(strippedQuery)`.
    let registry: CommandRegistry?
    /// Optional dynamic builder. If non-nil it wins over `registry`:
    /// search() invokes the closure with the stripped query and wraps
    /// the returned commands in CommandMatch values (no fuzzy scoring;
    /// the closure already decided what's relevant).
    let dynamicCommands: ((String) -> [ScribeCommand])?
    /// Placeholder displayed in the search field while this route is
    /// active. nil ⇒ caller-supplied default.
    let placeholder: String?

    init(id: String,
         prefix: String,
         registry: CommandRegistry? = nil,
         dynamicCommands: ((String) -> [ScribeCommand])? = nil,
         placeholder: String? = nil) {
        precondition(registry != nil || dynamicCommands != nil,
                     "PrefixRoute needs either a registry or a dynamicCommands closure")
        self.id = id
        self.prefix = prefix
        self.registry = registry
        self.dynamicCommands = dynamicCommands
        self.placeholder = placeholder
    }
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
            // Dynamic routes win over static ones — same as the init
            // precondition: caller can have one or the other, not
            // neither, and dynamic is the more specific contract.
            if let build = route.dynamicCommands {
                return build(stripped).map {
                    CommandMatch(command: $0, score: 0, highlightedRanges: nil)
                }
            }
            if let registry = route.registry {
                return registry.search(stripped)
            }
            return []
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

    // MARK: - Grouped search (Phase 46d)

    /// Phase 46d — Command Palette–facing search variant that keeps
    /// results flat for non-empty queries (so fuzzy ranking is
    /// preserved) but splits an empty query into category sections
    /// (File / View / Text / …). Each section's matches are MRU-
    /// sorted internally; the section order itself is fixed so the
    /// palette reads consistently regardless of the user's history.
    /// Prefix routes (`@`, `:`, `>`) skip sectioning since their
    /// result list is already scoped.
    func grouped(for query: String) -> [CommandSection] {
        let flatMatches = search(query)

        // Prefix route or non-empty query ⇒ single section, no
        // header. Keeps the flat visual behaviour for any mode
        // where sectioning would just clutter the list.
        if activeRoute(for: query) != nil
            || !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return [CommandSection(id: "all", title: "", matches: flatMatches)]
        }

        // Empty query: group by category. We key off the command's
        // `id` prefix (same contract `CommandPresentation` uses for
        // the category badge) so the grouping is resilient to
        // locale changes in `subtitle`.
        struct Bucket {
            var section: CategorySection
            var matches: [CommandMatch]
        }
        var buckets: [CategorySection: [CommandMatch]] = [:]
        for match in flatMatches {
            let section = Self.categorySection(for: match.command)
            buckets[section, default: []].append(match)
        }
        return CategorySection.allCases.compactMap { section -> CommandSection? in
            guard let matches = buckets[section], !matches.isEmpty else { return nil }
            return CommandSection(
                id: section.rawValue,
                title: L10n.t(section.titleKey),
                matches: matches
            )
        }
    }

    /// Phase 46d — fixed section roster shown above command rows
    /// when the palette opens without a query. Order here is the
    /// final render order; sections with no matches drop out.
    enum CategorySection: String, CaseIterable {
        case file, view, text, tabs, encoding, lineEnding, syntax, other

        var titleKey: String {
            switch self {
            case .file:       "palette.section.file"
            case .view:       "palette.section.view"
            case .text:       "palette.section.text"
            case .tabs:       "palette.section.tabs"
            case .encoding:   "palette.section.encoding"
            case .lineEnding: "palette.section.lineEnding"
            case .syntax:     "palette.section.syntax"
            case .other:      "palette.section.other"
            }
        }
    }

    /// Mapping `ScribeCommand.id → CategorySection`. Mirrors the
    /// routing in `CommandPresentation.categoryBadgeKey` so the
    /// badge and section header always agree.
    private static func categorySection(for command: ScribeCommand) -> CategorySection {
        let id = command.id
        if id.hasPrefix("file.") { return .file }
        if id.hasPrefix("view.") { return .view }
        if id.hasPrefix("text.") { return .text }
        if id.hasPrefix("tab.")  { return .tabs }
        if id.hasPrefix("enc.")  { return .encoding }
        if id.hasPrefix("eol.")  { return .lineEnding }
        if id.hasPrefix("lexer.") { return .syntax }
        return .other
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
