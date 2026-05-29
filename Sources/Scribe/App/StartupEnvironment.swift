//
//  StartupEnvironment.swift
//  ScribeApp pre-Workspace startup — environment-variable parsing,
//  activation policy, and the post-init auto-open dispatch.
//
//  Why an extra type: ScribeApp.init() used to inline-handle three
//  separate environment knobs (SCRIBE_AUTO_OPEN, SCRIBE_AUTO_FOLDER,
//  SCRIBE_AUTO_COMPARE) plus the NSApplication activation dance. With
//  the SCRIBE_TEST_* surface broken out into TestHooks, splitting the
//  startup parsing here too keeps `ScribeApp` itself readable as the
//  pure SwiftUI Scene declaration it should be.
//
//  All members are pure value-level reads of ProcessInfo.environment;
//  we never mutate the environment from this file.
//

import Foundation
import AppKit

/// Parsed form of the SCRIBE_AUTO_* environment knobs that ScribeApp.init
/// reads. Every field is non-optional — empty arrays / strings represent
/// "nothing requested".
struct StartupEnvironment {
    /// Files passed via `SCRIBE_AUTO_OPEN`, colon-separated. Only paths
    /// that actually exist on disk make it through; missing files are
    /// silently dropped because the test rigs occasionally pass paths
    /// that don't yet exist (a copy step happens in parallel).
    let autoOpenURLs: [URL]

    /// Folder requested via `SCRIBE_AUTO_FOLDER`. Empty string means
    /// "no auto-folder"; the caller treats this as "skip the open
    /// folder" branch entirely.
    let autoFolder: String

    /// Two `:`-separated paths passed via `SCRIBE_AUTO_COMPARE`. Empty
    /// when not set. Caller validates both halves exist before taking
    /// the diff path.
    let autoCompare: String

    /// Phase 35a — 1-based line number passed via
    /// `SCRIBE_AUTO_OPEN_LINE`. Plumbed through the CLI's `-l N`
    /// flag so `scribe -l 42 src/main.swift` opens with the cursor
    /// on line 42 (column 1). `nil` ⇒ no line targeting; opens the
    /// file at its persisted position. Negative / zero values are
    /// rejected at parse time so downstream `pendingScrollLine`
    /// gets a clean Int? with valid values only.
    let autoOpenLine: Int?

    /// Phase 54 — 1-based visual column number passed via
    /// `SCRIBE_AUTO_OPEN_COLUMN`. Mirrors the CLI's `-c N` flag.
    /// `nil` (or `autoOpenLine == nil`) ⇒ caret falls on column 1
    /// of the requested line; the editor's pending-scroll consumer
    /// already treats a nil column as "select the whole line"
    /// (high-visibility cue), so dropping `-c` keeps that behaviour.
    /// Negative / zero values are rejected at parse time.
    let autoOpenColumn: Int?

    /// Phase 54 — read-only flag passed via `SCRIBE_AUTO_READONLY`
    /// (CLI: `-r` / `--readonly`). Any non-empty value (`"1"`, `"true"`,
    /// `"yes"`) is treated as `true`; absent or empty ⇒ `false`. Every
    /// auto-opened file in the same invocation gets the same flag,
    /// matching `code --readonly` and `notepad++ -ro` semantics —
    /// users who want mixed read-only / writable tabs invoke `scribe`
    /// twice.
    let autoReadOnly: Bool

    /// UI smoke-test escape hatch: skip crash recovery detection so
    /// screenshots never touch the user's real scratch entries.
    let skipCrashRecoveryForTesting: Bool

    /// Phase 54 — Lexilla lexer name passed via `SCRIBE_AUTO_LEXER`
    /// (CLI: `-L LANG` / `--lang LANG`). When non-nil, Workspace
    /// stamps `doc.lexerOverride` on each auto-opened file so the
    /// status-bar language pill shows the override and syntax
    /// highlighting matches even if the file extension wouldn't
    /// normally resolve to that lexer. `nil` ⇒ extension-based
    /// auto-detection. Unknown lexer names fall through harmlessly
    /// to LexerCatalog's `plain` default at apply time.
    let autoLexer: String?

    /// Resolve from the current process environment.
    static func current() -> StartupEnvironment {
        let env = ProcessInfo.processInfo.environment

        let openList = env["SCRIBE_AUTO_OPEN"] ?? ""
        let urls: [URL] = openList
            .split(separator: ":")
            .map(String.init)
            .compactMap { path in
                FileManager.default.fileExists(atPath: path)
                    ? URL(fileURLWithPath: path)
                    : nil
            }

        // Parse SCRIBE_AUTO_OPEN_LINE as a strictly-positive Int.
        // Garbage / zero / negatives are silently dropped; the
        // caller behaves as though no line was requested. We
        // deliberately don't surface a parse error — the CLI
        // wrapper validates before launch, and any other launch
        // path with a malformed line is most likely a bug we want
        // to fail open (= file still opens, no scroll).
        let line: Int? = (env["SCRIBE_AUTO_OPEN_LINE"]).flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }

        // Phase 54 — same fail-open contract as the line knob:
        // garbage / zero / negative values silently degrade to nil.
        let column: Int? = (env["SCRIBE_AUTO_OPEN_COLUMN"]).flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }

        // Phase 54 — accept the common shell truthy spellings so
        // `SCRIBE_AUTO_READONLY=1`, `=true`, `=yes`, and `=on` all
        // work. Anything else (including the empty string) is
        // treated as false — the wrapper only ever emits "1".
        let readOnly: Bool
        switch (env["SCRIBE_AUTO_READONLY"] ?? "").lowercased() {
        case "1", "true", "yes", "on": readOnly = true
        default: readOnly = false
        }

        // Phase 54 — Lexilla lexer name override; whitespace-only
        // strings collapse to nil so `SCRIBE_AUTO_LEXER=""` from
        // the wrapper doesn't pin every doc to an empty lexer.
        let rawLexer = (env["SCRIBE_AUTO_LEXER"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        let lexer: String? = rawLexer.isEmpty ? nil : rawLexer

        return StartupEnvironment(
            autoOpenURLs: urls,
            autoFolder: env["SCRIBE_AUTO_FOLDER"] ?? "",
            autoCompare: env["SCRIBE_AUTO_COMPARE"] ?? "",
            autoOpenLine: line,
            autoOpenColumn: column,
            autoReadOnly: readOnly,
            skipCrashRecoveryForTesting: env["SCRIBE_TEST_SKIP_CRASH_RECOVERY"] == "1",
            autoLexer: lexer
        )
    }
}

// MARK: - Activation policy

/// SwiftPM-built executables default to `.background` activation
/// policy, so the window never reaches the Dock and AppKit doesn't
/// claim foreground focus. Forcing `.regular` + `activate` mirrors
/// what an Xcode-built `.app` bundle gets for free.
@MainActor
enum AppActivation {
    static func makeRegular() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Auto-open dispatch

/// Apply `StartupEnvironment` to a freshly-constructed Workspace.
/// Runs on the next runloop turn — eager mutation of `@Published`
/// state at @main init time is observed to delay or skip NSWindow
/// creation on macOS 14+ / swift-tools 5.9. Defer until the
/// WindowGroup has its NSWindow materialised first.
@MainActor
enum StartupAutoOpen {
    static func apply(_ env: StartupEnvironment, to workspace: Workspace) {
        DispatchQueue.main.async {
            // Phase 35a — `-l N` from the CLI plumbs through to a
            // single shared line number applied to every auto-opened
            // file. The common case is `scribe -l 42 file.swift` (one
            // file, one line); when multiple files are listed the
            // line targets each of them, which matches `code` and
            // `subl` semantics — users who want different lines per
            // file invoke the CLI multiple times.
            //
            // Phase 54 — `-c N` (column), `-r` (read-only), and
            // `-L LANG` (lexer override) join the same all-files
            // sharing contract so a single invocation behaves
            // predictably; per-file granularity stays opt-in via
            // multiple `scribe` calls.
            for url in env.autoOpenURLs {
                workspace.openFile(at: url,
                                   line: env.autoOpenLine,
                                   column: env.autoOpenColumn,
                                   readOnly: env.autoReadOnly,
                                   lexerOverride: env.autoLexer)
            }
            if !env.autoFolder.isEmpty {
                let url = URL(fileURLWithPath: env.autoFolder)
                if FileManager.default.fileExists(atPath: url.path) {
                    workspace.openFolder(at: url)
                }
            }
            if !env.autoCompare.isEmpty {
                let parts = env.autoCompare
                    .split(separator: ":", maxSplits: 1)
                    .map(String.init)
                if parts.count == 2,
                   FileManager.default.fileExists(atPath: parts[0]),
                   FileManager.default.fileExists(atPath: parts[1]) {
                    let session = DiffSession()
                    session.load(left: URL(fileURLWithPath: parts[0]),
                                 right: URL(fileURLWithPath: parts[1]))
                    workspace.compareSession = session
                }
            }
        }
    }
}
