//
//  CommandPresentationTests.swift
//  Phase 36d — palette / quick-open row presentation metadata.
//

import XCTest
@testable import Scribe

@MainActor
final class CommandPresentationTests: XCTestCase {

    func test_quickOpenOpenFilePresentation_usesCleanTitlePathDetailAndOpenBadge() {
        let command = ScribeCommand(
            id: "quickopen.open:/repo/README.md",
            title: "README.md",
            subtitle: "docs",
            perform: {}
        )

        let presentation = CommandPresentation(command: command)

        XCTAssertEqual(presentation.iconName, "doc.text")
        XCTAssertEqual(presentation.title, "README.md")
        XCTAssertEqual(presentation.detail, "docs")
        XCTAssertEqual(presentation.badge, L10n.t("palette.badge.open"))
    }

    func test_badgesUseInjectedLocalizationKeys() {
        let localize: (String) -> String = { "loc:\($0)" }

        let openFile = CommandPresentation(
            command: ScribeCommand(
                id: "quickopen.open:/repo/README.md",
                title: "README.md",
                subtitle: "docs",
                perform: {}
            ),
            localize: localize
        )
        let symbol = CommandPresentation(
            command: ScribeCommand(
                id: "symbol:doc:function",
                title: "render",
                subtitle: "function · line 3",
                perform: {}
            ),
            localize: localize
        )
        let gotoLine = CommandPresentation(
            command: ScribeCommand(
                id: "gotoLine:doc:42",
                title: "Go to line 42",
                subtitle: "in README.md",
                perform: {}
            ),
            localize: localize
        )
        let fileCommand = CommandPresentation(
            command: ScribeCommand(
                id: "file.open",
                title: "Open File…",
                subtitle: "File",
                perform: {}
            ),
            localize: localize
        )
        let encodingCommand = CommandPresentation(
            command: ScribeCommand(
                id: "enc.save.utf8",
                title: "Save as UTF-8",
                subtitle: "Encoding",
                perform: {}
            ),
            localize: localize
        )

        XCTAssertEqual(openFile.badge, "loc:palette.badge.open")
        XCTAssertEqual(symbol.badge, "loc:palette.badge.symbol")
        XCTAssertEqual(gotoLine.badge, "loc:palette.badge.line")
        XCTAssertEqual(fileCommand.badge, "loc:menu.file")
        XCTAssertEqual(encodingCommand.badge, "loc:palette.badge.encoding")
    }

    func test_commandPaletteCommandPresentation_movesCategorySubtitleIntoBadge() {
        let command = ScribeCommand(
            id: "view.markdownPreview",
            title: "Markdown Preview",
            subtitle: "View",
            perform: {}
        )

        let presentation = CommandPresentation(command: command)

        XCTAssertEqual(presentation.iconName, "eye")
        XCTAssertEqual(presentation.title, "Markdown Preview")
        XCTAssertNil(presentation.detail)
        XCTAssertEqual(presentation.badge, L10n.t("menu.view"))
    }

    func test_saveCommandUsesDocumentSaveGlyphNotDownloadTray() {
        let command = ScribeCommand(
            id: "file.save",
            title: "Save",
            subtitle: "File",
            perform: {}
        )

        let presentation = CommandPresentation(command: command)

        XCTAssertEqual(presentation.iconName, "doc.badge.checkmark")
    }

    func test_textToolCommandsUseStableTableGlyphAndTextBadge() {
        let command = ScribeCommand(
            id: "text.openTools",
            title: "Text Tools…",
            subtitle: "Text",
            perform: {}
        )

        let presentation = CommandPresentation(command: command)

        XCTAssertEqual(presentation.iconName, "tablecells")
        XCTAssertEqual(presentation.badge, L10n.t("palette.badge.text"))
    }

    func test_quickOpenMetadata_forOpenDocumentDoesNotPrefixTitleWithStatusGlyph() {
        let root = URL(fileURLWithPath: "/repo")
        let file = URL(fileURLWithPath: "/repo/Sources/App.swift")

        let metadata = QuickOpenController.commandMetadata(
            for: file,
            rootURL: root,
            isOpenDocument: true
        )

        XCTAssertEqual(metadata.id, "quickopen.open:/repo/Sources/App.swift")
        XCTAssertEqual(metadata.title, "App.swift")
        XCTAssertEqual(metadata.subtitle, "Sources")
        XCTAssertEqual(metadata.keywords, ["Sources", "open"])
    }

    func test_quickOpenMetadata_forIndexedFileKeepsDirectoryKeywordsOnly() {
        let root = URL(fileURLWithPath: "/repo")
        let file = URL(fileURLWithPath: "/repo/Sources/Models/Workspace.swift")

        let metadata = QuickOpenController.commandMetadata(
            for: file,
            rootURL: root,
            isOpenDocument: false
        )

        XCTAssertEqual(metadata.id, "quickopen.file:/repo/Sources/Models/Workspace.swift")
        XCTAssertEqual(metadata.title, "Workspace.swift")
        XCTAssertEqual(metadata.subtitle, "Sources/Models")
        XCTAssertEqual(metadata.keywords, ["Sources", "Models"])
    }

    func test_gotoLineCommandsUseInjectedLocalization() {
        let doc = Document(title: "README.md", text: "one\ntwo")
        let commands = QuickOpenController.gotoLineCommands(
            stripped: "2",
            doc: doc,
            localize: testLocalizer
        )

        XCTAssertEqual(commands.first?.title, "loc:palette.command.gotoLine 2")
        XCTAssertEqual(commands.first?.subtitle, "loc:palette.command.gotoLine.detail README.md")
        XCTAssertEqual(
            CommandPresentation(command: commands.first!, localize: testLocalizer).badge,
            "loc:palette.badge.line"
        )
    }

    func test_filePlaceholderUsesInjectedLocalization() {
        let root = URL(fileURLWithPath: "/repo/Scribe")

        XCTAssertEqual(
            QuickOpenController.filePlaceholder(
                isIndexing: true,
                rootURL: root,
                localize: testLocalizer
            ),
            "loc:palette.placeholder.indexing loc:palette.placeholder.modeHint"
        )
        XCTAssertEqual(
            QuickOpenController.filePlaceholder(
                isIndexing: false,
                rootURL: root,
                localize: testLocalizer
            ),
            "loc:palette.placeholder.filesWithHint Scribe loc:palette.placeholder.modeHint"
        )
        XCTAssertEqual(
            QuickOpenController.filePlaceholder(
                isIndexing: false,
                rootURL: nil,
                localize: testLocalizer
            ),
            "loc:palette.placeholder.openedFiles loc:palette.placeholder.modeHint"
        )
    }

    private func testLocalizer(_ key: String) -> String {
        switch key {
        case "palette.command.gotoLine":
            return "loc:\(key) %d"
        case "palette.command.gotoLine.detail":
            return "loc:\(key) %@"
        case "palette.placeholder.indexing",
             "palette.placeholder.openedFiles":
            return "loc:\(key) %@"
        case "palette.placeholder.filesWithHint":
            return "loc:\(key) %@ %@"
        default:
            return "loc:\(key)"
        }
    }
}
