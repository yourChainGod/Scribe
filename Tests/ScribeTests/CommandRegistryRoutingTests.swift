//
//  CommandRegistryRoutingTests.swift
//  Phase 11 — covers the PrefixRoute dispatching that powers ⌘P @symbol.
//

import XCTest
@testable import Scribe

@MainActor
final class CommandRegistryRoutingTests: XCTestCase {

    // MARK: - activeRoute

    func test_activeRoute_returnsNilWhenNoRoutes() {
        let r = CommandRegistry()
        XCTAssertNil(r.activeRoute(for: ""))
        XCTAssertNil(r.activeRoute(for: "foo"))
    }

    func test_activeRoute_returnsFirstMatchingPrefix() {
        let r = CommandRegistry()
        let sub = CommandRegistry()
        r.prefixRoutes = [
            PrefixRoute(id: "a", prefix: "@", registry: sub, placeholder: nil),
            PrefixRoute(id: "h", prefix: "#", registry: sub, placeholder: nil),
        ]
        XCTAssertEqual(r.activeRoute(for: "@hello")?.id, "a")
        XCTAssertEqual(r.activeRoute(for: "#tag")?.id, "h")
        XCTAssertNil(r.activeRoute(for: "plain"))
    }

    // MARK: - search routing

    func test_search_routesToSubRegistryWhenPrefixMatches() {
        let main = CommandRegistry()
        let sub = CommandRegistry()
        sub.commands = [
            ScribeCommand(id: "s1", title: "alpha", perform: {}),
            ScribeCommand(id: "s2", title: "beta",  perform: {}),
        ]
        main.commands = [
            ScribeCommand(id: "f1", title: "alpha-file", perform: {}),
        ]
        main.prefixRoutes = [
            PrefixRoute(id: "sym", prefix: "@", registry: sub, placeholder: nil)
        ]
        // No prefix → main registry only.
        let plain = main.search("alpha").map(\.command.id)
        XCTAssertEqual(plain, ["f1"])

        // With "@" prefix → sub registry, prefix stripped from query.
        let symbolHits = main.search("@alpha").map(\.command.id)
        XCTAssertEqual(symbolHits, ["s1"])

        // Bare "@" returns every sub command (empty stripped query).
        let allSymbols = Set(main.search("@").map(\.command.id))
        XCTAssertEqual(allSymbols, ["s1", "s2"])
    }

    func test_search_doesNotLeakSubRegistryWhenPrefixAbsent() {
        let main = CommandRegistry()
        let sub = CommandRegistry()
        sub.commands = [ScribeCommand(id: "s1", title: "alpha", perform: {})]
        main.commands = [ScribeCommand(id: "f1", title: "beta", perform: {})]
        main.prefixRoutes = [
            PrefixRoute(id: "sym", prefix: "@", registry: sub, placeholder: nil)
        ]
        // Empty query goes through the main path, not the sub.
        let allMain = main.search("").map(\.command.id)
        XCTAssertEqual(allMain, ["f1"])
    }

    // MARK: - placeholder

    func test_activeRoute_placeholderIsCarried() {
        let r = CommandRegistry()
        let sub = CommandRegistry()
        r.prefixRoutes = [
            PrefixRoute(id: "sym",
                        prefix: "@",
                        registry: sub,
                        placeholder: "Jump to symbol…")
        ]
        XCTAssertEqual(r.activeRoute(for: "@x")?.placeholder, "Jump to symbol…")
        XCTAssertNil(r.activeRoute(for: "x")?.placeholder)
    }
}
