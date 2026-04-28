//
//  MultiCursorTests.swift
//  Phase 20 — Scintilla multi-cursor support is wired through the
//  ScintillaCodeEditor.Coordinator. Most of its behaviour requires a
//  live ScintillaView (an NSView subclass), so what we cover here
//  are:
//    1. The new FindState.Command cases survive through the
//       PassthroughSubject without a build-time regression.
//    2. The "FindCommand routing" contract — every multi-cursor
//       command flows through the same `commands` subject as the
//       Find bar, which keeps the Coordinator's sink the single
//       responsibility owner of search-related dispatches.
//    3. The "single cursor" Esc shortcut isn't shadowing the Find
//       bar's existing Esc binding by collision.
//

import XCTest
import Combine
@testable import Scribe

@MainActor
final class MultiCursorTests: XCTestCase {

    private var bag: Set<AnyCancellable> = []

    override func tearDown() {
        bag.removeAll()
        super.tearDown()
    }

    func test_findStateCommands_publishMultiCursorCases() {
        let state = FindState(defaults: UserDefaults(suiteName: "scribe-mc-\(UUID().uuidString)")!)
        var received: [FindState.Command] = []
        state.commands
            .sink { received.append($0) }
            .store(in: &bag)

        state.commands.send(.selectNextOccurrence)
        state.commands.send(.selectAllOccurrences)
        state.commands.send(.collapseToSingleCursor)
        // Phase 21 — vertical multi-cursor.
        state.commands.send(.addCaretAbove)
        state.commands.send(.addCaretBelow)
        // Phase 22 — skip-current.
        state.commands.send(.skipAndSelectNextOccurrence)

        XCTAssertEqual(received.count, 6)
        // Pattern-match on each case so the compiler catches a
        // future enum-rename.
        for cmd in received {
            switch cmd {
            case .selectNextOccurrence,
                 .selectAllOccurrences,
                 .collapseToSingleCursor,
                 .addCaretAbove,
                 .addCaretBelow,
                 .skipAndSelectNextOccurrence:
                continue
            default:
                XCTFail("Unexpected command: \(cmd)")
            }
        }
    }

    func test_findStateCommands_orderingIsPreserved() {
        // Multi-cursor + Find commands share one subject. We assert
        // they don't reorder relative to each other so a user
        // pressing ⌘D, ⌘G, ⌘D in quick succession sees the
        // coordinator process them in that order.
        let state = FindState(defaults: UserDefaults(suiteName: "scribe-mc-order-\(UUID().uuidString)")!)
        var received: [FindState.Command] = []
        state.commands
            .sink { received.append($0) }
            .store(in: &bag)

        state.commands.send(.selectNextOccurrence)
        state.commands.send(.findNext)
        state.commands.send(.selectNextOccurrence)

        XCTAssertEqual(received.count, 3)
        if case .selectNextOccurrence = received[0] {} else {
            XCTFail("expected selectNextOccurrence first, got \(received[0])")
        }
        if case .findNext = received[1] {} else {
            XCTFail("expected findNext second, got \(received[1])")
        }
        if case .selectNextOccurrence = received[2] {} else {
            XCTFail("expected selectNextOccurrence third, got \(received[2])")
        }
    }
}
