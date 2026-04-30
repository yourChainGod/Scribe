//
//  InlineBlameSettingsTests.swift
//  Phase 35c-iii — settings + display polish for inline blame.
//

import XCTest
import Combine
@testable import Scribe

@MainActor
final class InlineBlameSettingsTests: XCTestCase {
    private var bag: Set<AnyCancellable> = []

    override func tearDown() {
        bag.removeAll()
        super.tearDown()
    }

    func test_editorPreferences_inlineBlameModeDefaultsAndPersists() {
        let suite = "scribe-inline-blame-mode-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = EditorPreferences(defaults: defaults)
        XCTAssertEqual(first.inlineBlameMode, .currentLine)

        first.inlineBlameMode = .allLines
        let reborn = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reborn.inlineBlameMode, .allLines)
    }

    func test_editorPreferences_inlineBlameModeFallsBackOnUnknownValue() {
        let suite = "scribe-inline-blame-mode-fallback-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("sideways", forKey: "editor.inlineBlameMode")

        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs.inlineBlameMode, .currentLine)
    }

    func test_inlineBlameFormatter_replacesCurrentAuthorNameWithYou() {
        let line = GitClient.BlameLine(
            lineNo: 1,
            sha: "abcdef1234567890",
            author: "Scribe Smoke",
            authorEmail: "<smoke@scribe.app>",
            authorTime: Int(Date().timeIntervalSince1970),
            summary: "baseline"
        )

        let label = InlineBlameFormatter.label(for: line,
                                               currentAuthorName: "Scribe Smoke")

        XCTAssertTrue(label.contains(L10n.t("inlineBlame.author.you")))
        XCTAssertFalse(label.contains("Scribe Smoke"))
        XCTAssertTrue(label.contains("abcdef1"))
    }

    func test_inlineBlameFormatter_tooltipIncludesSummaryAuthorAndSha() {
        let line = GitClient.BlameLine(
            lineNo: 7,
            sha: "1234567890abcdef",
            author: "Ada",
            authorEmail: "<ada@example.com>",
            authorTime: Int(Date().timeIntervalSince1970),
            summary: "Teach editor to annotate blame"
        )

        let tooltip = InlineBlameFormatter.tooltip(for: line,
                                                   currentAuthorName: "Someone Else")

        XCTAssertTrue(tooltip.contains("Teach editor to annotate blame"))
        XCTAssertTrue(tooltip.contains("Ada"))
        XCTAssertTrue(tooltip.contains("1234567"))
    }

    func test_gitClientCurrentUserNameReadsRepoConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-inline-blame-git-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], cwd: root)
        try runGit(["config", "user.name", "Scribe Smoke"], cwd: root)

        XCTAssertEqual(GitClient.currentUserName(repo: root), "Scribe Smoke")
    }

    func test_findStatePublishesInlineBlameVerificationCommand() {
        let state = FindState(defaults: UserDefaults(suiteName: "scribe-inline-blame-command-\(UUID().uuidString)")!)
        var received: [FindState.Command] = []
        state.commands
            .sink { received.append($0) }
            .store(in: &bag)

        state.commands.send(.testInlineBlame(mode: .allLines,
                                             caretLine: 5,
                                             tooltipLine: 7))

        XCTAssertEqual(received.count, 1)
        guard case let .testInlineBlame(mode, caretLine, tooltipLine) = received[0] else {
            return XCTFail("Expected inline blame verification command, got \(received[0])")
        }
        XCTAssertEqual(mode, .allLines)
        XCTAssertEqual(caretLine, 5)
        XCTAssertEqual(tooltipLine, 7)
    }

    private func runGit(_ args: [String], cwd: URL) throws {
        let task = Process()
        task.currentDirectoryURL = cwd
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
    }
}
