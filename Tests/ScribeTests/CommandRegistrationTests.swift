//
//  CommandRegistrationTests.swift
//  Phase 36b — discoverability coverage for command-palette surfaces.
//

import XCTest
import Combine
@testable import Scribe

@MainActor
final class CommandRegistrationTests: XCTestCase {
    private var bag: Set<AnyCancellable> = []

    override func tearDown() {
        bag.removeAll()
        super.tearDown()
    }

    private func makePrefs() -> EditorPreferences {
        let suite = "scribe-command-registration-\(UUID().uuidString)"
        return EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    func test_markdownPreviewCommand_isDiscoverableAndTogglesCurrentMarkdownDocument() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "README.md",
                           text: "# Scribe",
                           url: URL(fileURLWithPath: "/tmp/README.md"))
        workspace.documents = [doc]
        workspace.selectedID = doc.id

        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)

        let command = registry.search("markdown preview").first?.command
        XCTAssertEqual(command?.id, "view.markdownPreview")
        XCTAssertFalse(doc.isMarkdownPreviewVisible)

        command?.perform()

        XCTAssertTrue(doc.isMarkdownPreviewVisible)
    }

    func test_markdownPreviewCommand_isDiscoverableForPlainTextButNoOps() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "notes.txt",
                           text: "plain text",
                           url: URL(fileURLWithPath: "/tmp/notes.txt"))
        workspace.documents = [doc]
        workspace.selectedID = doc.id

        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)

        let command = registry.search("markdown preview").first?.command
        XCTAssertEqual(command?.id, "view.markdownPreview")

        command?.perform()

        XCTAssertFalse(doc.isMarkdownPreviewVisible)
    }

    func test_toggleSidebarCommand_remainsAvailableAfterToolbarUsesSystemButton() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)

        let command = registry.search("toggle sidebar").first?.command
        XCTAssertEqual(command?.id, "view.toggleSidebar")
        XCTAssertTrue(workspace.sidebarVisible)

        command?.perform()

        XCTAssertFalse(workspace.sidebarVisible)
    }

    func test_englishMnemonicQueriesStillWorkWithLocalizedCommandTitles() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "README.md",
                           text: "# Scribe",
                           url: URL(fileURLWithPath: "/tmp/README.md"))
        workspace.documents = [doc]
        workspace.selectedID = doc.id

        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)

        XCTAssertEqual(registry.search("toggle sidebar").first?.command.id, "view.toggleSidebar")
        XCTAssertEqual(registry.search("enc").first?.command.id.hasPrefix("enc."), true)
        XCTAssertEqual(registry.search("line ending").first?.command.id.hasPrefix("eol."), true)
    }

    func test_commandRegistration_usesInjectedLocalizationForVisiblePaletteText() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "README.md",
                           text: "# Scribe",
                           url: URL(fileURLWithPath: "/tmp/README.md"))
        workspace.documents = [doc]
        workspace.selectedID = doc.id

        let registry = CommandRegistry()
        CommandRegistration.refresh(
            registry: registry,
            workspace: workspace,
            prefs: prefs,
            localize: testLocalizer
        )

        let newTab = registry.commands.first { $0.id == "file.new" }
        XCTAssertEqual(newTab?.title, "loc:palette.command.newTab")
        XCTAssertEqual(
            CommandPresentation(command: newTab!, localize: testLocalizer).badge,
            "loc:menu.file"
        )

        let markdownPreview = registry.commands.first { $0.id == "view.markdownPreview" }
        XCTAssertEqual(markdownPreview?.title, "loc:menu.view.markdownPreview")
        XCTAssertEqual(
            CommandPresentation(command: markdownPreview!, localize: testLocalizer).badge,
            "loc:menu.view"
        )

        let switchTab = registry.commands.first { $0.id.hasPrefix("tab.") }
        XCTAssertEqual(switchTab?.title, "loc:palette.command.switchTo README.md")

        let encoding = registry.commands.first { $0.id.hasPrefix("enc.save.") && $0.title.contains("UTF-8") }
        XCTAssertEqual(encoding?.title, "loc:palette.command.saveAsEncoding UTF-8")
        XCTAssertEqual(
            CommandPresentation(command: encoding!, localize: testLocalizer).badge,
            "loc:palette.badge.encoding"
        )
    }

    func test_textTransformCommands_areDiscoverableAndDispatchToEditorSelection() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "scratch.txt", text: "a b")
        workspace.documents = [doc]
        workspace.selectedID = doc.id
        let findState = FindState(defaults: UserDefaults(suiteName: "scribe-command-text-\(UUID().uuidString)")!)
        var received: [FindState.Command] = []
        findState.commands
            .sink { received.append($0) }
            .store(in: &bag)

        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs,
                                    findState: findState,
                                    localize: testLocalizer)

        let command = registry.search("url encode").first?.command
        XCTAssertEqual(command?.id, "text.urlEncode")
        XCTAssertEqual(CommandPresentation(command: command!, localize: testLocalizer).badge,
                       "loc:palette.badge.text")

        command?.perform()

        XCTAssertEqual(received.count, 1)
        guard case let .transformSelection(action) = received[0] else {
            return XCTFail("Expected transformSelection, got \(received[0])")
        }
        XCTAssertEqual(action, .urlEncode)
    }

    func test_textToolsCommand_opensWorkbenchState() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "scratch.txt", text: "a,b")
        workspace.documents = [doc]
        workspace.selectedID = doc.id
        let findState = FindState(defaults: UserDefaults(suiteName: "scribe-command-tools-\(UUID().uuidString)")!)

        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs,
                                    findState: findState,
                                    localize: testLocalizer)

        let command = registry.search("text tools").first?.command
        XCTAssertEqual(command?.id, "text.openTools")
        XCTAssertFalse(workspace.isTextToolsPresented)

        command?.perform()

        XCTAssertTrue(workspace.isTextToolsPresented)
    }

    func test_textTransformWorkbenchCommand_opensTransformMode() {
        let prefs = makePrefs()
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let doc = Document(title: "scratch.txt", text: "a b")
        workspace.documents = [doc]
        workspace.selectedID = doc.id
        workspace.textToolsMode = .columns
        let findState = FindState(defaults: UserDefaults(suiteName: "scribe-command-transform-tools-\(UUID().uuidString)")!)

        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs,
                                    findState: findState,
                                    localize: testLocalizer)

        let command = registry.search("transform workbench").first?.command
        XCTAssertEqual(command?.id, "text.openTransformTools")
        XCTAssertFalse(workspace.isTextToolsPresented)

        command?.perform()

        XCTAssertTrue(workspace.isTextToolsPresented)
        XCTAssertEqual(workspace.textToolsMode, .transform)
    }

    private func testLocalizer(_ key: String) -> String {
        switch key {
        case "palette.command.switchTo",
             "palette.command.reopenWith",
             "palette.command.saveAsEncoding",
             "palette.command.useLineEndings",
             "palette.command.setLanguage":
            return "loc:\(key) %@"
        default:
            return "loc:\(key)"
        }
    }
}
