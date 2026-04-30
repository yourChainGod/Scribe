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
        runInlineBlame(env: env, ctx: ctx)
        runTextTools(env: env, ctx: ctx)
        runToast(env: env, ctx: ctx)
        runJWTSheet(env: env, ctx: ctx)
    }

    // MARK: Phase 41a — JWT sheet smoke

    /// SCRIBE_TEST_JWT = "<token>" pops the JWT decoder sheet
    /// pre-filled with the supplied token. Used by the screenshot
    /// script to capture the inspector layout deterministically.
    /// Defers briefly so the main window has finished its first
    /// layout pass before the sheet attaches.
    private static func runJWTSheet(env: [String: String],
                                    ctx: TestHookContext) {
        guard let token = env["SCRIBE_TEST_JWT"], !token.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            ctx.workspace.jwtSheet = JWTSheetRequest(prefill: token)
        }
    }

    // MARK: Phase 43-T — toast notification smoke

    /// SCRIBE_TEST_TOAST = "success|info|warning|error" — pipe-separated
    /// list of toast severities to spawn on launch. Lets the
    /// screenshot script capture the banner stack without having to
    /// manufacture a real failure (which would otherwise need a
    /// missing file or a poisoned encoding). Each severity gets a
    /// generic "Phase 43-T · <severity>" title and a fixed message
    /// so the layout matches what error paths actually produce.
    private static func runToast(env: [String: String],
                                 ctx: TestHookContext) {
        guard let raw = env["SCRIBE_TEST_TOAST"], !raw.isEmpty else { return }
        let parts = raw.split(separator: "|").map(String.init)
        let center = ctx.workspace.toastCenter
        for part in parts {
            guard let sev = ToastSeverity(rawValue: part) else { continue }
            let title = "Phase 43-T · \(sev.rawValue)"
            let msg = "Toast smoke hook"
            switch sev {
            case .success: center.success(title, message: msg)
            case .info:    center.info(title, message: msg)
            case .warning: center.warning(title, message: msg)
            case .error:   center.error(title, message: msg)
            }
        }
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
            ctx.workspace.activeTextSelection = s
        }
    }

    // MARK: Phase 15 — pin theme

    /// SCRIBE_TEST_THEME pins the editor to the named theme at
    /// startup so the screenshot script can grab a single palette
    /// without driving the View > Editor Theme menu.
    /// Phase 36 — drives the *UI* theme; the editor follows by
    /// default. Tests that need a decoupled editor theme should set
    /// `editorFollowsUITheme = false` then write `editorThemeID`.
    private static func runTheme(env: [String: String],
                                 ctx: TestHookContext) {
        guard let raw = env["SCRIBE_TEST_THEME"],
              let id = ThemeID(rawValue: raw) else { return }
        ctx.prefs.uiThemeID = id
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

    // MARK: Phase 35c-iv — Inline Blame verification

    /// SCRIBE_TEST_INLINE_BLAME_MODE = "off" | "currentLine" | "allLines"
    /// SCRIBE_TEST_INLINE_BLAME_LINE = "<1-based line>"
    /// SCRIBE_TEST_INLINE_BLAME_TOOLTIP_LINE = "<1-based line>"
    ///
    /// Drives the editor through the same command path as the find /
    /// multi-cursor screenshot hooks. We send the command twice because
    /// the first tick may land before `git blame` finishes on a freshly
    /// opened repo; the second tick is cheap and makes the screenshot
    /// workflow deterministic on slower machines.
    private static func runInlineBlame(env: [String: String],
                                       ctx: TestHookContext) {
        let mode = env["SCRIBE_TEST_INLINE_BLAME_MODE"]
            .flatMap(InlineBlameMode.init(rawValue:))
        let caretLine = positiveInt(env["SCRIBE_TEST_INLINE_BLAME_LINE"])
        let tooltipLine = positiveInt(env["SCRIBE_TEST_INLINE_BLAME_TOOLTIP_LINE"])

        guard mode != nil || caretLine != nil || tooltipLine != nil else { return }

        let resolvedMode = mode ?? ctx.prefs.inlineBlameMode
        let resolvedCaret = caretLine ?? (resolvedMode == .currentLine ? tooltipLine : nil)

        func sendCommand() {
            ctx.findState.commands.send(.testInlineBlame(mode: resolvedMode,
                                                         caretLine: resolvedCaret,
                                                         tooltipLine: tooltipLine))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            sendCommand()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            sendCommand()
        }
    }

    // MARK: Phase 37 → Phase 40 — text tools workbench

    /// SCRIBE_TEST_TEXT_TOOLS = "1" opens the column-merger sheet.
    /// SCRIBE_TEST_TEXT_TOOLS_DELAY can be used by screenshot scripts
    /// that first need another hook, such as inline-blame tooltip
    /// rendering, to settle. Phase 40 retired the per-mode hook
    /// (SCRIBE_TEST_TEXT_TOOLS_MODE) along with the multi-mode UI.
    private static func runTextTools(env: [String: String],
                                     ctx: TestHookContext) {
        guard env["SCRIBE_TEST_TEXT_TOOLS"] != nil else { return }

        let delay = env["SCRIBE_TEST_TEXT_TOOLS_DELAY"]
            .flatMap(Double.init) ?? 1.0

        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
            ctx.findState.commands.send(.hideInlineBlameTooltip)
            ctx.workspace.isTextToolsPresented = true
        }
    }

    private static func positiveInt(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), value > 0 else { return nil }
        return value
    }
}
