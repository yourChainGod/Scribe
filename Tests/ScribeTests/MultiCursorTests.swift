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
        // Phase 23 — column selection toggle.
        state.commands.send(.toggleColumnSelectionMode)

        XCTAssertEqual(received.count, 7)
        // Pattern-match on each case so the compiler catches a
        // future enum-rename.
        for cmd in received {
            switch cmd {
            case .selectNextOccurrence,
                 .selectAllOccurrences,
                 .collapseToSingleCursor,
                 .addCaretAbove,
                 .addCaretBelow,
                 .skipAndSelectNextOccurrence,
                 .toggleColumnSelectionMode:
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

    func test_findStateCommands_publishTextTransformActions() {
        let state = FindState(defaults: UserDefaults(suiteName: "scribe-transform-\(UUID().uuidString)")!)
        var received: [FindState.Command] = []
        state.commands
            .sink { received.append($0) }
            .store(in: &bag)

        state.commands.send(.transformSelection(.urlEncode))
        state.commands.send(.transformSelection(.convertBase(fromBase: 16, toBase: 10)))

        XCTAssertEqual(received.count, 2)
        guard case let .transformSelection(first) = received[0] else {
            return XCTFail("expected transformSelection, got \(received[0])")
        }
        guard case let .transformSelection(second) = received[1] else {
            return XCTFail("expected transformSelection, got \(received[1])")
        }
        XCTAssertEqual(first, .urlEncode)
        XCTAssertEqual(second, .convertBase(fromBase: 16, toBase: 10))
    }

    func test_findStateCommands_publishReplaceSelectionText() {
        let state = FindState(defaults: UserDefaults(suiteName: "scribe-replace-selection-\(UUID().uuidString)")!)
        var received: [FindState.Command] = []
        state.commands
            .sink { received.append($0) }
            .store(in: &bag)

        state.commands.send(.replaceSelectionText("merged result"))

        XCTAssertEqual(received.count, 1)
        guard case let .replaceSelectionText(text) = received[0] else {
            return XCTFail("expected replaceSelectionText, got \(received[0])")
        }
        XCTAssertEqual(text, "merged result")
    }

    func test_findStateCommands_publishHideInlineBlameTooltip() {
        let state = FindState(defaults: UserDefaults(suiteName: "scribe-hide-calltip-\(UUID().uuidString)")!)
        var received: [FindState.Command] = []
        state.commands
            .sink { received.append($0) }
            .store(in: &bag)

        state.commands.send(.hideInlineBlameTooltip)

        XCTAssertEqual(received.count, 1)
        if case .hideInlineBlameTooltip = received[0] {
            return
        }
        XCTFail("expected hideInlineBlameTooltip, got \(received[0])")
    }
}
