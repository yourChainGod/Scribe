//
//  TestHooks.swift
//  Verification hooks driven by SCRIBE_TEST_* environment variables.
//  Every hook is a single-purpose deterministic side effect that
//  Scripts/screenshot_*.swift use to take a screenshot of an
//  otherwise hard-to-reach UI state without keystroke synthesis.
//
//  Why one big enum instead of a sea of free functions: every hook
//  reads from ProcessInfo + writes to a small graph of @StateObject
//  observables (Workspace / FindState / FindInFilesState / outline /
//  fileIndex / prefs). Grouping them under `TestHooks` makes the
//  call sites at `MainWindow.onAppear` a single line per hook and
//  lets us rip the entire surface out of the production build via
//  conditional compilation if we ever want to.
//
//  Every hook is a no-op when its environment variable is unset, so
//  shipping these in release is safe — no test rig can race a real
//  user.
//

import AppKit
import Foundation
import SwiftUI

/// Bag of references the hooks need to drive. Constructed once in
/// MainWindow.onAppear and threaded through. Reference types only —
/// every member is an @StateObject in the App layer.
@MainActor
struct TestHookContext {
    let workspace: Workspace
    let prefs: EditorPreferences
    let findState: FindState
    let findInFiles: FindInFilesState
    let findInFilesEngine: FindInFilesEngine
    let fileIndex: FileIndex
    let outline: SymbolOutline
    let commands: CommandRegistry
}

@MainActor
enum TestHooks {

    /// Drive every SCRIBE_TEST_* hook. Order matters here only loosely
    /// — most hooks defer to .asyncAfter so they all overlap rather
    /// than chain — but we keep the ordering identical to the previous
    /// monolithic implementation for parity with the existing
    /// screenshot scripts.
    static func runAll(_ ctx: TestHookContext) {
        let env = ProcessInfo.processInfo.environment

        runRectSelect(env: env, ctx: ctx)
        runSkipNext(env: env, ctx: ctx)
        runMultiVertical(env: env, ctx: ctx)
        runMultiSelect(env: env, ctx: ctx)
        runFindFromSelection(env: env, ctx: ctx)
        runTheme(env: env, ctx: ctx)
        runPaletteQuery(env: env, ctx: ctx)
        runFindInFiles(env: env, ctx: ctx)
    }

    // MARK: Phase 23 — rectangular selection

    /// SCRIBE_TEST_RECT_SELECT = "<linesDown>:<charsRight>" toggles
    /// the doc into SC_SEL_RECTANGLE then drives
    /// LINEDOWNRECTEXTEND × N + CHARRIGHTRECTEXTEND × M so the
    /// screenshot script can show a real rectangle highlight without
    /// keystroke synthesis.
    private static func runRectSelect(env: [String: String],
                                      ctx: TestHookContext) {
        guard let raw = env["SCRIBE_TEST_RECT_SELECT"] else { return }
        let parts = raw.split(separator: ":").map(String.init)
        let lines = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
        let chars = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ctx.findState.commands.send(.toggleColumnSelectionMode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                ctx.findState.commands.send(
                    .testRectSelectExtend(linesDown: lines, charsRight: chars)
                )
            }
        }
    }

    // MARK: Phase 22 — skip current ⌘D selection

    /// SCRIBE_TEST_SKIP_NEXT = "<needle>" runs ⌘D twice (so two
    /// occurrences are selected), then ⌃⌘D once (skip current,
    /// pick next). Used by the screenshot script to demonstrate the
    /// skip-and-advance behaviour.
    private static func runSkipNext(env: [String: String],
                                    ctx: TestHookContext) {
        guard let needle = env["SCRIBE_TEST_SKIP_NEXT"], !needle.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ctx.findState.query = needle
            ctx.findState.commands.send(.findCurrent)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ctx.findState.commands.send(.selectNextOccurrence)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    ctx.findState.commands.send(.selectNextOccurrence)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        ctx.findState.commands.send(.skipAndSelectNextOccurrence)
                    }
                }
            }
        }
    }

    // MARK: Phase 21 — vertical multi-cursor

    /// SCRIBE_TEST_MULTI_VERTICAL = "<count>" sends `addCaretBelow`
    /// <count> times, then sends a literal "★" insertion so the
    /// screenshot has a visible marker for each stacked caret.
    private static func runMultiVertical(env: [String: String],
                                         ctx: TestHookContext) {
        guard let raw = env["SCRIBE_TEST_MULTI_VERTICAL"],
              let n = Int(raw), n > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for _ in 0..<n {
                ctx.findState.commands.send(.addCaretBelow)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                ctx.findState.commands.send(.insertAtCarets("★"))
            }
        }
    }

    // MARK: Phase 20 — multi-select-all-occurrences

    /// SCRIBE_TEST_MULTI_SELECT = "<needle>" finds the needle and
    /// selects every occurrence as a multi-cursor selection.
    private static func runMultiSelect(env: [String: String],
                                       ctx: TestHookContext) {
        guard let needle = env["SCRIBE_TEST_MULTI_SELECT"], !needle.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ctx.findState.query = needle
            ctx.findState.commands.send(.findCurrent)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                ctx.findState.commands.send(.selectAllOccurrences)
            }
        }
    }

    // MARK: Phase 18 — find from live selection

    /// SCRIBE_TEST_FIND_FROM_SELECTION primes Workspace.activeSelection
    /// so the screenshot can demonstrate the prefill-from-selection
    /// path without driving an actual SCN_UPDATEUI tick.
    private static func runFindFromSelection(env: [String: String],
                                             ctx: TestHookContext) {
        guard let s = env["SCRIBE_TEST_FIND_FROM_SELECTION"], !s.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            ctx.workspace.activeSelection = s
        }
    }

    // MARK: Phase 15 — pin theme

    /// SCRIBE_TEST_THEME pins the editor to the named theme at
    /// startup so the screenshot script can grab a single palette
    /// without driving the View > Editor Theme menu.
    private static func runTheme(env: [String: String],
                                 ctx: TestHookContext) {
        guard let raw = env["SCRIBE_TEST_THEME"],
              let id = ThemeID(rawValue: raw) else { return }
        ctx.prefs.themeID = id
    }

    // MARK: Phase 11 — pre-fill ⌘P palette

    /// SCRIBE_TEST_PALETTE_QUERY pre-fills ⌘P with the given query.
    /// The 1.5 s delay covers the outline parser's debounce + the
    /// detached parse on a background queue.
    private static func runPaletteQuery(env: [String: String],
                                        ctx: TestHookContext) {
        guard let q = env["SCRIBE_TEST_PALETTE_QUERY"], !q.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            QuickOpenController.shared.show(
                workspace: ctx.workspace,
                fileIndex: ctx.fileIndex,
                outline: ctx.outline,
                initialQuery: q
            )
        }
    }

    // MARK: Phase 16/17 — Find-in-Files

    /// SCRIBE_TEST_FIND_QUERY runs Find-in-Files against the seeded
    /// folder. Lets the screenshot workflow exercise the result tree
    /// without depending on flaky keystroke synthesis through the
    /// borderless Find sidebar.
    ///
    /// Companion variables:
    ///   SCRIBE_TEST_FIND_DESELECT       comma-separated filenames
    ///                                   whose checkbox should be
    ///                                   unticked once results arrive.
    ///   SCRIBE_TEST_FIND_DESELECT_LINES "<file>:<line>" pairs to
    ///                                   opt out of at the line level.
    private static func runFindInFiles(env: [String: String],
                                       ctx: TestHookContext) {
        guard let q = env["SCRIBE_TEST_FIND_QUERY"], !q.isEmpty else { return }
        // folderRoot is opened by SCRIBE_AUTO_FOLDER via
        // StartupAutoOpen.apply — resolve the root inside the
        // closure rather than at onAppear time when it's still nil.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let root = ctx.workspace.folderRoot?.url else { return }
            ctx.workspace.sidebarMode = .search
            ctx.workspace.sidebarVisible = true
            ctx.findInFiles.query = q
            let opts = FindInFilesOptions(
                query: q,
                matchCase: false,
                wholeWord: false,
                regex: false,
                includeGlobs: [],
                excludeGlobs: []
            )
            ctx.findInFilesEngine.search(options: opts, root: root, into: ctx.findInFiles)

            if let deselect = env["SCRIBE_TEST_FIND_DESELECT"], !deselect.isEmpty {
                let names = deselect.split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    for r in ctx.findInFiles.results
                        where names.contains(r.url.lastPathComponent) {
                        ctx.findInFiles.toggleSelection(r.url)
                    }
                }
            }

            if let lines = env["SCRIBE_TEST_FIND_DESELECT_LINES"], !lines.isEmpty {
                let pairs = lines.split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    for pair in pairs {
                        let parts = pair.split(separator: ":")
                        guard parts.count == 2,
                              let line = Int(parts[1]) else { continue }
                        let name = String(parts[0])
                        if let result = ctx.findInFiles.results.first(
                            where: { $0.url.lastPathComponent == name }
                        ) {
                            ctx.findInFiles.toggleLineSelection(result.url, line: line)
                        }
                    }
                }
            }
        }
    }
}
