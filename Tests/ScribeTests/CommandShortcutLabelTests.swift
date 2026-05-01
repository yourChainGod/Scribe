//
//  CommandShortcutLabelTests.swift
//  Phase 46e — verifies that the shortcut chip data model is wired
//  through from command registration into the ScribeCommand the
//  Command Palette reads.
//
//  The visual chip itself (CommandRow) is a SwiftUI view that
//  requires a hosting window to render; we cover the data contract
//  here and rely on smoke-level manual verification for the pixel
//  result, consistent with other palette tests in the suite.
//

import XCTest
@testable import Scribe

@MainActor
final class CommandShortcutLabelTests: XCTestCase {

    private func makePrefs() -> EditorPreferences {
        let suite = "scribe-shortcut-\(UUID().uuidString)"
        return EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    // MARK: - Shape

    func test_scribeCommand_defaultsShortcutLabelToNil() {
        let cmd = ScribeCommand(id: "x", title: "X") { }
        XCTAssertNil(cmd.shortcutLabel,
                     "existing call sites without the new arg pay no penalty")
    }

    func test_scribeCommand_storesShortcutLabelVerbatim() {
        let cmd = ScribeCommand(id: "x",
                                title: "X",
                                shortcutLabel: "⌘⇧K") { }
        XCTAssertEqual(cmd.shortcutLabel, "⌘⇧K")
    }

    // MARK: - Registration wiring

    func test_coreFileCommands_carryShortcutLabels() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)

        let byID = Dictionary(uniqueKeysWithValues:
                              registry.commands.map { ($0.id, $0) })

        XCTAssertEqual(byID["file.new"]?.shortcutLabel, "⌘N")
        XCTAssertEqual(byID["file.open"]?.shortcutLabel, "⌘O")
        XCTAssertEqual(byID["file.openFolder"]?.shortcutLabel, "⌥⌘O")
        XCTAssertEqual(byID["file.save"]?.shortcutLabel, "⌘S")
        XCTAssertEqual(byID["file.reopenClosed"]?.shortcutLabel, "⌘⇧T")
    }

    func test_zoomCommands_carryShortcutLabels() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)
        let byID = Dictionary(uniqueKeysWithValues:
                              registry.commands.map { ($0.id, $0) })
        XCTAssertEqual(byID["view.zoomIn"]?.shortcutLabel, "⌘+")
        XCTAssertEqual(byID["view.zoomOut"]?.shortcutLabel, "⌘-")
        XCTAssertEqual(byID["view.actualSize"]?.shortcutLabel, "⌘0")
    }

    func test_markdownPreviewCommand_carriesShortcutLabelWhenDocumentOpen() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "README.md",
                           text: "# hi",
                           url: URL(fileURLWithPath: "/tmp/readme.md"))
        workspace.documents = [doc]
        workspace.selectedID = doc.id

        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)

        let preview = registry.commands.first { $0.id == "view.markdownPreview" }
        XCTAssertEqual(preview?.shortcutLabel, "⌘⇧V")
    }

    func test_ambientCommands_leaveShortcutLabelNil() {
        // Commands that aren't wired to a menu-bar accelerator
        // shouldn't advertise one — the chip cue would mislead
        // users into pressing a key combo that does nothing.
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)

        let silent = registry.commands.first { $0.id == "file.closeFolder" }
        XCTAssertNotNil(silent, "sanity — the command should still be registered")
        XCTAssertNil(silent?.shortcutLabel)
    }
}
