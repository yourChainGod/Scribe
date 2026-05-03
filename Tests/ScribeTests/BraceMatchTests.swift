//
//  BraceMatchTests.swift
//  Phase 62 — guardrails around the bracket-matching + auto-close
//  seams that don't require a live ScintillaView. Behavioural
//  coverage of BRACEMATCH / BRACEHIGHLIGHT / CHARADDED dispatch
//  lives in the manual-QA path (same constraint as Phase 20's
//  MultiCursorTests).
//

import XCTest
@testable import Scribe

@MainActor
final class BraceMatchTests: XCTestCase {

    // MARK: - Scintilla constants

    /// Pin the Scintilla message IDs we depend on so a silent
    /// Vendor bump can't re-route our calls to a different message.
    /// (Same defensive pattern as
    /// `MultiCursorTests.test_sciConstants_docPointerIDsMatchScintilla`.)
    func test_sciConstants_braceMessageIDsMatchScintilla() {
        XCTAssertEqual(SCI.BRACEHIGHLIGHT, 2351,
                       "SCI_BRACEHIGHLIGHT changed — verify Vendor/scintilla/include/Scintilla.h")
        XCTAssertEqual(SCI.BRACEBADLIGHT, 2352,
                       "SCI_BRACEBADLIGHT changed")
        XCTAssertEqual(SCI.BRACEMATCH, 2353,
                       "SCI_BRACEMATCH changed")
        XCTAssertEqual(SCI.GETCHARAT, 2007,
                       "SCI_GETCHARAT changed")
        XCTAssertEqual(SCI.POSITIONBEFORE, 2417,
                       "SCI_POSITIONBEFORE changed")
    }

    func test_sciConstants_braceStyleSlotsMatchScintilla() {
        XCTAssertEqual(SC.STYLE_BRACELIGHT, 34,
                       "STYLE_BRACELIGHT changed")
        XCTAssertEqual(SC.STYLE_BRACEBAD, 35,
                       "STYLE_BRACEBAD changed")
    }

    // MARK: - FindState.Command plumbing

    /// Compile-time + runtime proof that `.jumpToMatchingBracket`
    /// rides the PassthroughSubject without a regression. The
    /// menu / palette dispatch uses the same channel.
    func test_findState_jumpToMatchingBracketRidesCommandBus() {
        let state = FindState()
        var received: FindState.Command?
        let sub = state.commands.sink { received = $0 }
        state.commands.send(.jumpToMatchingBracket)
        if case .jumpToMatchingBracket = received {
            // OK
        } else {
            XCTFail("jumpToMatchingBracket did not round-trip; got \(String(describing: received))")
        }
        sub.cancel()
    }

    // MARK: - Palette registration

    func test_palette_registersJumpToMatchingBracket() {
        let suite = "scribe-brace-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "scratch.swift", text: "")
        workspace.documents = [doc]
        workspace.selectedID = doc.id

        let registry = CommandRegistry()
        let findState = FindState()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs,
                                    findState: findState)
        let cmd = registry.commands.first { $0.id == "edit.jumpToMatchingBracket" }
        XCTAssertNotNil(cmd, "palette must expose edit.jumpToMatchingBracket")
        XCTAssertEqual(cmd?.shortcutLabel, "⇧⌘B",
                       "shortcut label must match the ⌘⇧B menu binding")
    }

    func test_palette_jumpToMatchingBracket_matchesBracketKeywords() {
        let suite = "scribe-brace-kw-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "scratch.swift", text: "")
        workspace.documents = [doc]
        workspace.selectedID = doc.id

        let registry = CommandRegistry()
        let findState = FindState()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs,
                                    findState: findState)
        // Each query below is a direct substring of a keyword we
        // registered for the command (not fuzzy). At least one of
        // them must rank the entry inside the result list.
        for query in ["bracket", "brace", "paren", "matching",
                      "partner", "balance", "括号", "匹配"] {
            let ids = registry.search(query).map(\.command.id)
            XCTAssertTrue(ids.contains("edit.jumpToMatchingBracket"),
                          "query '\(query)' should surface edit.jumpToMatchingBracket; got \(ids)")
        }
    }

    // MARK: - i18n

    func test_localisation_phase62StringsExist() {
        // Both locales must carry the visible strings. Falling
        // back to the key itself is what L10n.t returns for a
        // missing key, so "=== key" failures here point at an
        // unlocalised release.
        for key in ["menu.tools.jumpToMatchingBracket",
                    "palette.command.jumpToMatchingBracket"] {
            let resolved = L10n.t(key)
            XCTAssertNotEqual(resolved, key,
                              "missing localisation for \(key)")
        }
    }
}
