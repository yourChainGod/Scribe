//
//  SnippetCatalog.swift
//  Phase 33 — observable owner for the user's snippet collection.
//  Persists the list as JSON in UserDefaults under a single key so the
//  whole catalog round-trips atomically; observers (SettingsView panel,
//  SnippetController palette source) refresh on any mutation.
//
//  Why @MainActor + ObservableObject:
//    - SwiftUI bindings in the Settings tab need @Published access.
//    - The catalog is small (tens of entries, kilobytes of JSON), so
//      per-mutation full re-encode + UserDefaults write is fine.
//    - All mutations land on the main thread anyway (menu / palette
//      / settings are UI-driven); making it main-actor avoids the
//      Sendable dance for `[Snippet]` published values.
//
//  Why a single key, not one-per-snippet:
//    - Atomic writes mean the on-disk state is always a coherent list
//      (no torn partial save mid-rename).
//    - A user inspecting `defaults read` sees one JSON blob, not
//      `snippet.0.body / snippet.0.name / snippet.1.body / …`.
//

import Foundation

@MainActor
final class SnippetCatalog: ObservableObject {

    /// Live snapshot of the user's snippets. Writes flow through the
    /// CRUD methods so persistence stays in lockstep; direct
    /// mutation from outside is intentionally not exposed.
    @Published private(set) var snippets: [Snippet]

    private let defaults: UserDefaults
    private static let storageKey = "scribe.snippets.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Snippet].self,
                                                   from: data) {
            self.snippets = decoded
            return
        }
        // First run (or corrupted JSON) — seed with the starter set
        // and persist immediately so the next launch picks up the
        // same list. We don't surface decode errors: a corrupt blob
        // is no worse than "first run", and the user's edits will
        // overwrite the seed once they touch the palette.
        self.snippets = Self.starterSnippets
        Self.persist(self.snippets, to: defaults)
    }

    // MARK: - CRUD

    /// Append a new snippet and persist. Returns the snippet (with
    /// the freshly-generated `id`) so the caller can navigate the
    /// settings list straight to it.
    @discardableResult
    func add(_ snippet: Snippet) -> Snippet {
        snippets.append(snippet)
        Self.persist(snippets, to: defaults)
        return snippet
    }

    /// Replace the existing snippet with the same `id`. No-op if the
    /// id isn't in the catalog (the caller passed a stale value).
    func update(_ snippet: Snippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id })
        else { return }
        snippets[idx] = snippet
        Self.persist(snippets, to: defaults)
    }

    /// Remove the snippet with `id`, if present.
    func remove(id: UUID) {
        snippets.removeAll { $0.id == id }
        Self.persist(snippets, to: defaults)
    }

    /// Reset the catalog to the starter seed. Wipes any user edits;
    /// the Settings panel surfaces this behind a confirmation alert
    /// so a misclick can't drop hand-curated snippets.
    func resetToStarter() {
        snippets = Self.starterSnippets
        Self.persist(snippets, to: defaults)
    }

    // MARK: - Persistence

    /// Encode + write. We don't surface encoding errors: the
    /// `Snippet` struct is plain Codable, so a real encode failure
    /// would be a programmer error caught in tests, not a runtime
    /// path the user can hit.
    private static func persist(_ snippets: [Snippet],
                                to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        defaults.set(data, forKey: storageKey)
    }

    // MARK: - Starter seed

    /// First-launch defaults. A handful of high-signal samples that
    /// double as documentation: opening Settings → Snippets shows
    /// the user the kind of thing snippets are for, even before
    /// they've added their own.
    private static let starterSnippets: [Snippet] = [
        Snippet(
            name: "TODO Comment",
            prefix: "todo",
            body: "// TODO: ",
            description: "Insert a TODO comment marker."
        ),
        Snippet(
            name: "FIXME Comment",
            prefix: "fixme",
            body: "// FIXME: ",
            description: "Insert a FIXME comment marker."
        ),
        Snippet(
            name: "Markdown Table",
            prefix: "mdtable",
            body: "| col1 | col2 |\n| ---- | ---- |\n|      |      |\n",
            description: "GFM table skeleton (Phase 32)."
        ),
        Snippet(
            name: "Markdown Task List",
            prefix: "mdtasks",
            body: "- [ ] First task\n- [ ] Second task\n- [x] Done\n",
            description: "GFM task list (Phase 32)."
        ),
        Snippet(
            name: "Date (ISO 8601)",
            prefix: "date",
            // Phase 63 — when the user expands this snippet the
            // four-digit year is pre-selected and Tab walks
            // through MM, DD before parking the caret at the
            // tail (`$0`).
            body: "${1:YYYY}-${2:MM}-${3:DD}",
            description: "ISO 8601 date — Tab through year/month/day."
        ),
        Snippet(
            name: "Function (Swift)",
            prefix: "func",
            // Phase 63 — placeholders demo. `$1` is the function
            // name, `$2` is the parameter list, `$3` is the
            // return type, `$0` parks the caret on the body.
            body: "func ${1:name}(${2:args}) -> ${3:Void} {\n    $0\n}",
            description: "Swift function with placeholder navigation."
        )
    ]
}
