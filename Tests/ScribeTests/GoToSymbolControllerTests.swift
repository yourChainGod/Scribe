//
//  GoToSymbolControllerTests.swift
//  Phase 65 — locks down the pure (non-AppKit) slice of the
//  workspace-wide Go to Symbol controller:
//    1. Command rows carry a stable id, a relative-path subtitle,
//       kind + path-component keywords, and a perform closure that
//       funnels through Workspace.openFile(at:line:).
//    2. Relative-path helper strips the workspace root so rows
//       don't bleed absolute paths into the palette.
//    3. Placeholder text tracks isIndexing / truncated / no-folder
//       / steady-state modes without stringifying NSString
//       placeholders (a regression the zh-Hans bundle would surface
//       via `%@` showing up verbatim otherwise).
//    4. CommandRegistration.refresh emits the `go.workspaceSymbol`
//       entry only when both fileIndex and workspaceSymbolIndex are
//       provided, matching the defensive skip in production.
//

import XCTest
@testable import Scribe

@MainActor
final class GoToSymbolControllerTests: XCTestCase {

    // MARK: - Helpers

    private func makePrefs() -> EditorPreferences {
        let suite = "scribe-gotosymbol-\(UUID().uuidString)"
        return EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    private func makeWorkspace() -> Workspace {
        let prefs = makePrefs()
        return Workspace(prefs: prefs, openInitialUntitled: false)
    }

    // MARK: - makeCommands

    func test_makeCommands_emitsOneRowPerSymbol() {
        let workspace = makeWorkspace()
        let url = URL(fileURLWithPath: "/tmp/fake/Sources/Foo.swift")
        let symbols = [
            WorkspaceSymbol(id: WorkspaceSymbol.makeID(url: url, line: 3, name: "Foo"),
                            name: "Foo",
                            kind: .structDecl,
                            url: url,
                            line: 3),
            WorkspaceSymbol(id: WorkspaceSymbol.makeID(url: url, line: 9, name: "bar"),
                            name: "bar",
                            kind: .method,
                            url: url,
                            line: 9),
        ]
        let commands = GoToSymbolController.makeCommands(
            symbols: symbols,
            rootURL: URL(fileURLWithPath: "/tmp/fake"),
            workspace: workspace)

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.map(\.title), ["Foo", "bar"])
        // Ids mirror WorkspaceSymbol.id so the MRU / palette stable
        // identity piggybacks on the same key.
        XCTAssertEqual(commands.map(\.id), symbols.map(\.id))
    }

    func test_makeCommands_subtitleCarriesRelativePath() {
        let workspace = makeWorkspace()
        let root = URL(fileURLWithPath: "/tmp/fake")
        let url = root.appendingPathComponent("Sources/Foo.swift")
        let sym = WorkspaceSymbol(
            id: WorkspaceSymbol.makeID(url: url, line: 42, name: "Bar"),
            name: "Bar",
            kind: .classDecl,
            url: url,
            line: 42)
        let cmds = GoToSymbolController.makeCommands(symbols: [sym],
                                                     rootURL: root,
                                                     workspace: workspace)
        let subtitle = cmds.first?.subtitle ?? ""
        XCTAssertTrue(subtitle.contains("Sources/Foo.swift"),
                      "subtitle must contain the relative path; got '\(subtitle)'")
        XCTAssertTrue(subtitle.contains("42"),
                      "subtitle must surface the line number; got '\(subtitle)'")
        XCTAssertFalse(subtitle.contains("/tmp/fake"),
                       "subtitle must not leak the absolute root path; got '\(subtitle)'")
    }

    func test_makeCommands_keywordsIncludeKindAndBasename() {
        let url = URL(fileURLWithPath: "/tmp/fake/Views/Editor.swift")
        let sym = WorkspaceSymbol(
            id: WorkspaceSymbol.makeID(url: url, line: 7, name: "render"),
            name: "render",
            kind: .function,
            url: url,
            line: 7)
        let kw = GoToSymbolController.makeKeywords(for: sym)
        XCTAssertTrue(kw.contains("function"), "missing kind label; got \(kw)")
        XCTAssertTrue(kw.contains("Editor.swift"), "missing file basename; got \(kw)")
        XCTAssertTrue(kw.contains("Views"),
                      "missing parent dir for fuzzy narrowing; got \(kw)")
    }

    // MARK: - relativePath

    func test_relativePath_stripsWorkspaceRoot() {
        let root = URL(fileURLWithPath: "/Users/me/proj")
        let url = root.appendingPathComponent("src/app.swift")
        XCTAssertEqual(GoToSymbolController.relativePath(for: url,
                                                         rootURL: root),
                       "src/app.swift")
    }

    func test_relativePath_fallsBackToAbsolutePath_whenRootMissing() {
        let url = URL(fileURLWithPath: "/Users/me/proj/src/app.swift")
        XCTAssertEqual(GoToSymbolController.relativePath(for: url,
                                                         rootURL: nil),
                       url.standardizedFileURL.path)
    }

    func test_relativePath_fallsBackWhenOutsideRoot() {
        let root = URL(fileURLWithPath: "/Users/me/otherproj")
        let url = URL(fileURLWithPath: "/Users/me/proj/src/app.swift")
        XCTAssertEqual(GoToSymbolController.relativePath(for: url,
                                                         rootURL: root),
                       url.standardizedFileURL.path,
                       "url outside the root must fall back to an absolute path rather than returning a bogus relative")
    }

    // MARK: - Placeholder

    func test_placeholder_indexingState_returnsIndexingCopy() {
        let result = GoToSymbolController.placeholder(isIndexing: true,
                                                      truncated: false,
                                                      symbolCount: 0,
                                                      rootURL: nil,
                                                      localize: { $0 })
        XCTAssertEqual(result, "palette.goToSymbol.placeholder.indexing")
    }

    func test_placeholder_noFolder_returnsNoFolderCopy() {
        let result = GoToSymbolController.placeholder(isIndexing: false,
                                                      truncated: false,
                                                      symbolCount: 0,
                                                      rootURL: nil,
                                                      localize: { $0 })
        XCTAssertEqual(result, "palette.goToSymbol.placeholder.noFolder")
    }

    func test_placeholder_steadyState_carriesRootAndCount() {
        let root = URL(fileURLWithPath: "/tmp/proj")
        let text = GoToSymbolController.placeholder(
            isIndexing: false,
            truncated: false,
            symbolCount: 128,
            rootURL: root,
            localize: { key in
                // Make the format string unambiguous for the match.
                switch key {
                case "palette.goToSymbol.placeholder": return "[%@/%d]"
                default: return key
                }
            })
        XCTAssertEqual(text, "[proj/128]")
    }

    func test_placeholder_truncated_swapsToTruncatedCopy() {
        let root = URL(fileURLWithPath: "/tmp/proj")
        let text = GoToSymbolController.placeholder(
            isIndexing: false,
            truncated: true,
            symbolCount: 50_000,
            rootURL: root,
            localize: { key in
                switch key {
                case "palette.goToSymbol.placeholder.truncated": return "TRUNC %@ %d"
                default: return "OTHER"
                }
            })
        XCTAssertEqual(text, "TRUNC proj 50000")
    }

    // MARK: - CommandRegistration integration

    func test_refresh_emitsGoToSymbolPaletteEntry_whenDepsWired() {
        let suite = "scribe-gotosymbol-reg-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        // Register an open doc so other commands are emitted too —
        // helps assert that the new command doesn't collide with
        // the existing surface.
        workspace.documents = [Document(title: "x.swift", text: "struct X {}")]
        workspace.selectedID = workspace.documents[0].id

        let registry = CommandRegistry()
        let fileIndex = FileIndex()
        let symbolIndex = WorkspaceSymbolIndex()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs,
                                    fileIndex: fileIndex,
                                    workspaceSymbolIndex: symbolIndex)
        let command = registry.commands.first { $0.id == "go.workspaceSymbol" }
        XCTAssertNotNil(command,
                        "refresh must register the Go to Symbol command when both deps are wired")
        XCTAssertEqual(command?.shortcutLabel, "⌘T",
                       "shortcut label must match the menu binding")
    }

    func test_refresh_skipsGoToSymbolEntry_whenDepsMissing() {
        let suite = "scribe-gotosymbol-reg-miss-\(UUID().uuidString)"
        let prefs = EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
        let workspace = Workspace(prefs: prefs, openInitialUntitled: false)
        let registry = CommandRegistry()
        CommandRegistration.refresh(registry: registry,
                                    workspace: workspace,
                                    prefs: prefs)
        XCTAssertFalse(registry.commands.contains { $0.id == "go.workspaceSymbol" },
                       "must not register the Go to Symbol entry when fileIndex / symbolIndex are nil")
    }
}
