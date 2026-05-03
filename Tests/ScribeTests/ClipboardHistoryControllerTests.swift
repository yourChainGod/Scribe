//
//  ClipboardHistoryControllerTests.swift
//  Phase 57 — covers the palette-bridge layer that wraps a
//  ClipboardHistoryStore as ScribeCommand entries. We don't open the
//  real NSPanel here; the test reads the controller's private
//  registry through `Mirror` to assert the rebuild output. That's
//  good enough to pin the contract: empty store ⇒ hint command,
//  non-empty store ⇒ one command per entry, perform writes the
//  text back to NSPasteboard.
//

import XCTest
import AppKit
@testable import Scribe

@MainActor
final class ClipboardHistoryControllerTests: XCTestCase {

    /// Reach into the private `registry` instance via Mirror so
    /// tests don't force the property to be `internal` for one
    /// caller. Returns nil if the layout ever changes — the test
    /// will then fail loudly and prompt the upgrade.
    private func registry(of controller: ClipboardHistoryController) -> CommandRegistry? {
        Mirror(reflecting: controller)
            .children
            .first(where: { $0.label == "registry" })?
            .value as? CommandRegistry
    }

    // MARK: - Empty state

    func test_emptyStore_seedsHintCommand() {
        let store = ClipboardHistoryStore()
        let controller = ClipboardHistoryController()
        // Trigger rebuild by calling the public toggle path. We
        // can't drive the panel itself in a headless XCTest, but
        // toggle(...) calls rebuild + the controller's private
        // PaletteWindowController call — the panel call is a
        // no-op when the host has no key window.
        controller.toggle(store: store)
        guard let reg = registry(of: controller) else {
            return XCTFail("ClipboardHistoryController.registry inaccessible")
        }
        XCTAssertEqual(reg.commands.count, 1,
                       "empty store should surface exactly one hint command")
        XCTAssertEqual(reg.commands.first?.id, "clipboard.empty",
                       "hint command must use the stable 'clipboard.empty' ID")
    }

    // MARK: - Populated state

    func test_populatedStore_yieldsOneCommandPerEntry() {
        let store = ClipboardHistoryStore()
        store.record(text: "alpha")
        store.record(text: "beta")
        store.record(text: "gamma")
        let controller = ClipboardHistoryController()
        controller.toggle(store: store)
        guard let reg = registry(of: controller) else {
            return XCTFail("registry not reachable")
        }
        XCTAssertEqual(reg.commands.count, 3)
        // Most recent first — "gamma" was the last record() call.
        let titles = reg.commands.map(\.title)
        XCTAssertEqual(titles[0], "gamma")
        XCTAssertEqual(titles[1], "beta")
        XCTAssertEqual(titles[2], "alpha")
        // Each command id is namespaced with `clipboard:` so
        // CommandRegistry's MRU storage doesn't collide with
        // unrelated commands.
        for cmd in reg.commands {
            XCTAssertTrue(cmd.id.hasPrefix("clipboard:"),
                          "id must be clipboard-namespaced; got \(cmd.id)")
        }
    }

    // MARK: - Multi-line preview

    func test_multiLineEntry_producesPreviewWithMoreHint() {
        // The picker condenses multi-line entries into a single
        // line + an "↵ +N more" cue so the row stays readable.
        let store = ClipboardHistoryStore()
        store.record(text: "first line\nsecond line\nthird line")
        let controller = ClipboardHistoryController()
        controller.toggle(store: store)
        guard let reg = registry(of: controller) else {
            return XCTFail("registry not reachable")
        }
        let title = reg.commands.first?.title ?? ""
        XCTAssertTrue(title.contains("first line"),
                      "preview must surface the first line verbatim")
        XCTAssertTrue(title.contains("+2 more"),
                      "preview must announce the dropped lines: got \(title)")
    }

    // MARK: - Perform writes pasteboard + promotes entry

    func test_performingCommand_writesTextBackToPasteboard() {
        // Save and restore the system pasteboard around the test
        // so we don't trash the dev's clipboard during a CI run.
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            pb.clearContents()
            if let saved {
                pb.setString(saved, forType: .string)
            }
        }

        let store = ClipboardHistoryStore()
        store.record(text: "older")
        store.record(text: "newer")
        let controller = ClipboardHistoryController()
        controller.toggle(store: store)
        guard let reg = registry(of: controller),
              let oldCmd = reg.commands.first(where: { $0.title == "older" }) else {
            return XCTFail("expected an 'older' entry")
        }

        oldCmd.perform()

        XCTAssertEqual(pb.string(forType: .string), "older",
                       "perform must promote the chosen text to NSPasteboard")
        // Promotion side-effect: the chosen entry is now top of the
        // store so a subsequent picker open lists it first.
        XCTAssertEqual(store.entries.first?.text, "older",
                       "perform must record-back so 'most recent' tracks the choice")
    }
}
