//
//  SnippetIntegrationTests.swift
//  Phase 63 — guardrails for the cross-cutting wiring of the
//  snippet placeholder feature: FindState command bus, the
//  Scintilla `SC_MOD_*` bits we test against the modification
//  type bitmask, and the indicator slot allocation. Behavioural
//  coverage of `Coordinator.beginSnippetSession` lives in the
//  manual-QA path (same constraint as Phase 20's MultiCursorTests
//  and Phase 62's BraceMatchTests).
//

import Combine
import XCTest
@testable import Scribe

@MainActor
final class SnippetIntegrationTests: XCTestCase {

    // MARK: - FindState command bus

    /// `.insertSnippet(body)` must round-trip through the same
    /// PassthroughSubject every other editor command rides; the
    /// menu / palette / sheets all dispatch through this channel.
    func test_findState_insertSnippetRidesCommandBus() {
        let state = FindState()
        var received: FindState.Command?
        let sub = state.commands.sink { received = $0 }
        state.commands.send(.insertSnippet("hello"))
        guard case .insertSnippet(let body) = received else {
            XCTFail("insertSnippet did not round-trip; got \(String(describing: received))")
            sub.cancel(); return
        }
        XCTAssertEqual(body, "hello")
        sub.cancel()
    }

    // MARK: - Scintilla modificationType bits

    /// Pin the SCN_MODIFIED `modificationType` bit values so a
    /// silent Vendor bump can't re-route insert / delete events.
    /// The session adjuster keys off these exact bits to decide
    /// whether to grow or shrink stop ranges.
    func test_scModConstants_matchScintilla() {
        XCTAssertEqual(SC_MOD.INSERT_TEXT, 0x1,
                       "SC_MOD_INSERTTEXT changed — verify Vendor/scintilla/include/Scintilla.h")
        XCTAssertEqual(SC_MOD.DELETE_TEXT, 0x2,
                       "SC_MOD_DELETETEXT changed")
    }

    // MARK: - Indicator slot allocation

    /// Phase 63 reserves slot 2 for the active placeholder
    /// indicator. Slots 0 and 1 are owned by the find / colour
    /// swatch features; bumping any of these accidentally would
    /// cause the snippet highlight to overpaint matches or
    /// inline colour fills.
    func test_snippetIndicatorSlot_isSlotTwo() {
        XCTAssertEqual(SCIND.SNIPPET, 2,
                       "snippet indicator slot must remain 2 to avoid clashing with MATCHES (0) / COLOR_SWATCH (1)")
        XCTAssertNotEqual(SCIND.SNIPPET, SCIND.MATCHES)
        XCTAssertNotEqual(SCIND.SNIPPET, SCIND.COLOR_SWATCH)
    }

    // MARK: - Starter seed (Phase 63 placeholders demo)

    /// The first-launch seed gained two placeholder demos in
    /// Phase 63. Both must parse cleanly through `SnippetParser`
    /// and produce a session — otherwise the showcase falls back
    /// to plain insertion and users never see the new behaviour.
    func test_starterSeed_dateSnippet_hasPlaceholders() {
        let suite = "scribe-snippet-integration-\(UUID().uuidString)"
        let catalog = SnippetCatalog(defaults: UserDefaults(suiteName: suite)!)
        guard let snippet = catalog.snippets.first(where: { $0.prefix == "date" }) else {
            XCTFail("starter seed must include the 'date' snippet"); return
        }
        let parsed = SnippetParser.parse(snippet.body)
        // YYYY (1), MM (2), DD (3), then the synthetic $0 tail.
        XCTAssertEqual(parsed.stops.map(\.index), [1, 2, 3, 0])
        XCTAssertNotNil(SnippetSession.make(parsed: parsed, insertedAt: 0))
    }

    func test_starterSeed_funcSnippet_hasPlaceholders() {
        let suite = "scribe-snippet-integration-\(UUID().uuidString)"
        let catalog = SnippetCatalog(defaults: UserDefaults(suiteName: suite)!)
        guard let snippet = catalog.snippets.first(where: { $0.prefix == "func" }) else {
            XCTFail("starter seed must include the 'func' snippet"); return
        }
        let parsed = SnippetParser.parse(snippet.body)
        // name (1), args (2), return (3), explicit body $0.
        XCTAssertEqual(parsed.stops.map(\.index), [1, 2, 3, 0])
        // The terminal stop sits inside the function body, not at
        // the tail — verify it isn't the synthetic tail-stop.
        let terminal = parsed.stops.last
        XCTAssertEqual(terminal?.index, 0)
        XCTAssertLessThan(terminal?.location ?? Int.max,
                          parsed.plainText.utf16.count,
                          "$0 must be inside the function body, not appended at the tail")
    }

    // MARK: - Multi-caret fallback contract

    /// When `beginSnippetSession` would race against multiple
    /// active carets, the implementation falls back to the legacy
    /// `insertAtCarets` path. We can't drive a live ScintillaView
    /// from the test bundle, but we *can* prove the parser path
    /// returns a session for single-caret inputs that produce
    /// placeholders — which is the precondition the editor side
    /// branches on. The fallback's behaviour itself rides on
    /// MultiCursor behavioural QA.
    func test_session_isOpenedForBodiesWithPlaceholders() {
        let parsed = SnippetParser.parse("call(${1:arg})")
        XCTAssertNotNil(SnippetSession.make(parsed: parsed, insertedAt: 0))
    }

    func test_session_isSkippedForPlainBody() {
        let parsed = SnippetParser.parse("just plain text")
        XCTAssertNil(SnippetSession.make(parsed: parsed, insertedAt: 0),
                     "plain bodies must skip the session and fall back to a regular caret")
    }
}
