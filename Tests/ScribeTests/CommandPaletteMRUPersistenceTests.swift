//
//  CommandPaletteMRUPersistenceTests.swift
//  Phase 50b — verify that `CommandRegistry.mru` survives across
//  launches via `EditorPreferences.commandPaletteMRU`. Pre-50b the
//  stack was in-memory only; this suite locks in the new contract:
//  seed from defaults, write back on every invoke, defensive de-dup
//  + cap when the persisted blob has been tampered with.
//

import XCTest
@testable import Scribe

@MainActor
final class CommandPaletteMRUPersistenceTests: XCTestCase {

    // MARK: - seedMRU

    func test_seedMRU_replacesStackInOrder() {
        let registry = CommandRegistry()
        registry.seedMRU(["b", "a", "c"])
        XCTAssertEqual(registry.mru, ["b", "a", "c"])
    }

    func test_seedMRU_dedupesPreservingFirstSeenPosition() {
        // A defaults blob hand-edited to contain duplicates shouldn't
        // crash the search path or skew the ranking. First occurrence
        // wins so the visible order matches what the user invoked.
        let registry = CommandRegistry()
        registry.seedMRU(["a", "b", "a", "c", "b"])
        XCTAssertEqual(registry.mru, ["a", "b", "c"])
    }

    func test_seedMRU_capsAtMRUCap() {
        let registry = CommandRegistry()
        let oversized = (0..<(CommandRegistry.mruCap + 25)).map { "cmd.\($0)" }
        registry.seedMRU(oversized)
        XCTAssertEqual(registry.mru.count, CommandRegistry.mruCap)
        XCTAssertEqual(registry.mru.first, "cmd.0")
        XCTAssertEqual(registry.mru.last,  "cmd.\(CommandRegistry.mruCap - 1)")
    }

    func test_seedMRU_doesNotFireOnMRUChange() {
        // Seeding from disk shouldn't echo the same array back. The
        // persistence wiring expects the callback to mark a *new*
        // mutation only.
        let registry = CommandRegistry()
        var fired = false
        registry.onMRUChange = { _ in fired = true }
        registry.seedMRU(["a", "b"])
        XCTAssertFalse(fired, "seedMRU must not trigger onMRUChange")
    }

    func test_seedMRU_emptyClearsStack() {
        let registry = CommandRegistry()
        registry.seedMRU(["a", "b"])
        registry.seedMRU([])
        XCTAssertEqual(registry.mru, [])
    }

    // MARK: - invoke + onMRUChange

    func test_invoke_firesOnMRUChange_withMostRecentFirst() {
        let registry = CommandRegistry()
        var lastSeen: [String]?
        registry.onMRUChange = { lastSeen = $0 }

        let alpha = makeCommand(id: "alpha")
        let beta  = makeCommand(id: "beta")
        registry.commands = [alpha, beta]

        registry.invoke(alpha)
        XCTAssertEqual(lastSeen, ["alpha"])

        registry.invoke(beta)
        XCTAssertEqual(lastSeen, ["beta", "alpha"],
                       "invoke must put the freshly-invoked id at index 0")

        registry.invoke(alpha)
        XCTAssertEqual(lastSeen, ["alpha", "beta"],
                       "invoking an existing id must move it to the front, not duplicate")
    }

    func test_invoke_capsOnMRUChangePayload() {
        // Stuff the cap, then invoke one more — the resulting
        // payload should still respect mruCap so the host never
        // persists more than the agreed maximum.
        let registry = CommandRegistry()
        let seed = (0..<CommandRegistry.mruCap).map { "cmd.\($0)" }
        registry.seedMRU(seed)
        registry.commands = seed.map { makeCommand(id: $0) } + [makeCommand(id: "fresh")]

        var lastSeen: [String]?
        registry.onMRUChange = { lastSeen = $0 }
        registry.invoke(registry.commands.last!)

        XCTAssertNotNil(lastSeen)
        XCTAssertEqual(lastSeen?.count, CommandRegistry.mruCap)
        XCTAssertEqual(lastSeen?.first, "fresh",
                       "newly invoked id must be at the head")
        XCTAssertFalse(lastSeen?.contains("cmd.\(CommandRegistry.mruCap - 1)") ?? true,
                       "oldest entry must be dropped to make room")
    }

    // MARK: - EditorPreferences round-trip

    func test_editorPreferences_persistsAndRestoresCommandPaletteMRU() {
        let suite = "scribe-mru-persistence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        // First "launch": empty, register one ID, observe the write.
        let prefs1 = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs1.commandPaletteMRU, [])
        prefs1.commandPaletteMRU = ["file.save", "view.toggleSidebar"]

        // Second "launch": reading from the same defaults should
        // see the previous session's stack verbatim.
        let prefs2 = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs2.commandPaletteMRU,
                       ["file.save", "view.toggleSidebar"])
    }

    func test_editorPreferences_seedsRegistry_andRegistryWritesBack() {
        // Full integration: seed → invoke → confirm prefs caught
        // the write. Models the exact wiring in
        // `ScribeApp.bootstrap`.
        let suite = "scribe-mru-roundtrip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prefs = EditorPreferences(defaults: defaults)
        prefs.commandPaletteMRU = ["seed.first", "seed.second"]

        let registry = CommandRegistry()
        registry.seedMRU(prefs.commandPaletteMRU)
        registry.onMRUChange = { [weak prefs] in prefs?.commandPaletteMRU = $0 }

        XCTAssertEqual(registry.mru, ["seed.first", "seed.second"])

        let cmd = makeCommand(id: "ad-hoc")
        registry.commands = [cmd]
        registry.invoke(cmd)

        XCTAssertEqual(prefs.commandPaletteMRU,
                       ["ad-hoc", "seed.first", "seed.second"],
                       "Registry should have written the bumped stack back through prefs")

        // Re-read defaults to be sure the value actually hit disk.
        let reloaded = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.commandPaletteMRU,
                       ["ad-hoc", "seed.first", "seed.second"])
    }

    // MARK: - Helpers

    private func makeCommand(id: String) -> ScribeCommand {
        ScribeCommand(
            id: id,
            title: id,
            perform: { /* no-op for tests */ }
        )
    }
}
