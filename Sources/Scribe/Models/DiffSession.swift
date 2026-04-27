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
            leftText = leftDecoded.text
            rightText = rightDecoded.text
            error = nil
            Task { await recompute() }
        } catch {
            self.error = error.localizedDescription
        }
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
