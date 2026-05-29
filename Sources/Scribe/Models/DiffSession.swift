//
//  DiffSession.swift
//  Phase 5 — observable wrapper around DiffEngine. Holds the two files
//  the user picked, the current DiffResult, and the pane-scroll
//  bookkeeping the SwiftUI views read.
//

import AppKit
import Foundation
import Scintilla

@MainActor
final class DiffSession: ObservableObject {
    @Published var leftURL: URL?
    @Published var rightURL: URL?
    @Published var leftText: String = ""
    @Published var rightText: String = ""
    /// Optional pane-header overrides. When nil the view falls back to
    /// the URL's lastPathComponent. Git-diff loads use these to surface
    /// "HEAD: foo.swift" instead of the working-tree file name on the
    /// left side.
    @Published var leftLabel: String?
    @Published var rightLabel: String?
    /// Optional header subtitle (greyed-out text under the title). Git
    /// diff uses it for the short SHA + revision marker.
    @Published var leftSubtitle: String?
    @Published var rightSubtitle: String?
    @Published var result: DiffResult?
    @Published var error: String?

    /// Weak refs to the two ScintillaViews, set by the panes' coordinators
    /// in attach(side:view:). Used to broker synchronised scrolling — the
    /// panes themselves don't know about each other.
    weak var leftView: ScintillaView?
    weak var rightView: ScintillaView?
    /// Re-entry guard. The 'sync the other side' write itself triggers
    /// SCN_UPDATEUI on the receiver, which would loop straight back.
    var isSyncingScroll: Bool = false
    /// `true` while a diff is being computed off-main. We don't bother
    /// cancelling the previous one — Myers is cheap and the user can
    /// only kick off one comparison per ⌘⌥D anyway.
    @Published var isComputing: Bool = false

    /// 0-based hunk index the user is currently looking at; wired to
    /// "Next / Previous Diff" buttons in the UI.
    @Published var activeHunk: Int = 0

    /// Hunks (non-equal ops) extracted from `result.ops` for navigation.
    var hunks: [DiffOp] {
        result?.ops.filter { $0.kind != .equal } ?? []
    }

    /// Compute a diff between `leftText` and `rightText`. Off-main; flips
    /// `isComputing` while it runs. Idempotent — calling twice with the
    /// same input is fine.
    func recompute() async {
        let left = leftText
        let right = rightText
        isComputing = true
        let computed = await Task.detached(priority: .userInitiated) {
            DiffEngine.compare(left, right)
        }.value
        result = computed
        activeHunk = 0
        isComputing = false
    }

    /// Pick two files via NSOpenPanel and load + diff.
    func chooseAndCompare() {
        let panel = NSOpenPanel()
        panel.title = "Select two files to compare"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Pick two files. Older first by convention."
        guard panel.runModal() == .OK, panel.urls.count == 2 else { return }
        load(left: panel.urls[0], right: panel.urls[1])
    }

    /// Load + diff the two given URLs. Public so the menu / drag-drop
    /// can call it directly with already-known paths.
    func load(left: URL, right: URL) {
        do {
            let leftData = try Data(contentsOf: left)
            let rightData = try Data(contentsOf: right)
            let leftDecoded  = TextFormatDetector.decode(data: leftData)
            let rightDecoded = TextFormatDetector.decode(data: rightData)
            leftURL = left
            rightURL = right
            leftLabel = nil
            rightLabel = nil
            leftSubtitle = nil
            rightSubtitle = nil
            leftText = leftDecoded.text
            rightText = rightDecoded.text
            error = nil
            Task { await recompute() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Diff a working-tree file against its HEAD blob. Left = HEAD,
    /// right = working tree (so additions show up as green on the
    /// right, the convention every other diff tool uses).
    /// Errors set `self.error` and leave the panes empty.
    func loadGitHEAD(file: URL) {
        // Audit H4 — `headBlob` forks three git subprocesses
        // (ls-files / show / rev-parse) and we then read + decode the
        // working file. This all used to run synchronously on the main
        // actor, freezing the UI for the duration on large tracked
        // files or a cold git. Resolve it off-main and apply the
        // outcome back here; mirrors `recompute()`'s detach pattern.
        isComputing = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.resolveGitHEAD(file: file)
            }.value
            switch outcome {
            case .untracked:
                error = "“\(file.lastPathComponent)” is not tracked by git."
                isComputing = false
            case .notInRepo:
                error = "“\(file.lastPathComponent)” is not inside a git repository."
                isComputing = false
            case .error(let message):
                error = "git: \(message)"
                isComputing = false
            case .readError(let message):
                error = "Couldn't read working file: \(message)"
                isComputing = false
            case .loaded(let blob, let shortSHA, let working):
                leftURL = nil
                rightURL = file
                leftLabel = file.lastPathComponent
                rightLabel = nil
                leftSubtitle = "HEAD@\(shortSHA)"
                rightSubtitle = "Working tree"
                leftText = blob
                rightText = working
                error = nil
                await recompute()   // flips isComputing true→false itself
            }
        }
    }

    /// Off-main resolution for `loadGitHEAD` (audit H4). `nonisolated`
    /// so it runs on the detached executor: forks the git subprocesses
    /// and reads + decodes the working file without touching any
    /// `@MainActor` state. Returns a `Sendable` outcome the caller
    /// applies back on the main actor.
    private nonisolated static func resolveGitHEAD(file: URL) -> GitHEADOutcome {
        switch GitClient.headBlob(of: file) {
        case .untracked:          return .untracked
        case .notInRepo:          return .notInRepo
        case .error(let message): return .error(message)
        case .success(let blob, let shortSHA):
            do {
                let workingData = try Data(contentsOf: file)
                let workingDecoded = TextFormatDetector.decode(data: workingData)
                return .loaded(blob: blob,
                               shortSHA: shortSHA,
                               working: workingDecoded.text)
            } catch {
                return .readError(error.localizedDescription)
            }
        }
    }

    /// Result of the off-main `resolveGitHEAD` pass. `Sendable` so it
    /// crosses the detached-task boundary back to the main actor.
    private enum GitHEADOutcome: Sendable {
        case untracked
        case notInRepo
        case error(String)
        case readError(String)
        case loaded(blob: String, shortSHA: String, working: String)
    }

    /// Phase 68b — load two raw strings (no URLs) and trigger a
    /// recompute. Used by the merge-conflict overlay's Compare
    /// button to surface a conflict's two sides side by side
    /// without writing them to temp files first. The labels /
    /// subtitles default to nil if the caller skips them; the
    /// pane header then falls back to "Left" / "Right" the same
    /// way the URL path does.
    func loadInline(leftText: String,
                    leftLabel: String? = nil,
                    leftSubtitle: String? = nil,
                    rightText: String,
                    rightLabel: String? = nil,
                    rightSubtitle: String? = nil) {
        leftURL = nil
        rightURL = nil
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
        self.leftSubtitle = leftSubtitle
        self.rightSubtitle = rightSubtitle
        self.leftText = leftText
        self.rightText = rightText
        error = nil
        Task { await recompute() }
    }

    func nextHunk() {
        guard !hunks.isEmpty else { return }
        activeHunk = (activeHunk + 1) % hunks.count
    }

    func previousHunk() {
        guard !hunks.isEmpty else { return }
        activeHunk = (activeHunk - 1 + hunks.count) % hunks.count
    }

    // MARK: - Synchronised scrolling

    /// Called by a pane's coordinator when it observes a vertical-scroll
    /// SCN_UPDATEUI. We translate the scrolling pane's first-visible-line
    /// to the matching line on the other side via `mapLeftToRight` /
    /// `mapRightToLeft` and push it through SCI_SETFIRSTVISIBLELINE.
    func syncScroll(from side: DiffEditorPane.Side, firstVisibleLine: Int) {
        guard let result, !isSyncingScroll else { return }
        let targetLine: Int
        let targetView: ScintillaView?
        switch side {
        case .left:
            targetLine = result.mapLeftToRight(firstVisibleLine)
            targetView = rightView
        case .right:
            targetLine = result.mapRightToLeft(firstVisibleLine)
            targetView = leftView
        }
        guard let targetView else { return }
        isSyncingScroll = true
        // SCI_SETFIRSTVISIBLELINE = 2613
        targetView.message(2613, wParam: UInt(max(0, targetLine)))
        // Release the guard on the next tick so the echo SCN_UPDATEUI
        // gets ignored, but a genuine user scroll arriving immediately
        // afterwards still works.
        DispatchQueue.main.async { [weak self] in
            self?.isSyncingScroll = false
        }
    }
}
