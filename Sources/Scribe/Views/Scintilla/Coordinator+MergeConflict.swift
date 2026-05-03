//
//  Coordinator+MergeConflict.swift
//  Phase 68 — turns `MergeConflictEngine.conflicts` into a stack
//  of floating banner views that hover above each `<<<<<<<` line
//  inside the live Scintilla NSView. The banners host three
//  Accept buttons (Current / Incoming / Both) plus a Compare
//  hand-off; clicking one routes through this extension's
//  `applyMergeConflictResolution`, which drives a transactional
//  SCI_REPLACETARGET so the patch participates in the editor's
//  undo chain and triggers a single SCN_MODIFIED.
//

import AppKit
import Combine
import Scintilla

extension ScintillaCodeEditor.Coordinator {

    // MARK: - Subscription

    /// Install the sink that listens for `engine.$conflicts` emits.
    /// Idempotent — `attach(view:)` calls this once per NSView
    /// lifecycle and we replace any prior cancellable so a SwiftUI
    /// view rebuild doesn't pile up duplicate subscriptions.
    func subscribeToMergeConflicts(view: ScintillaView) {
        mergeConflictSink = workspace?.mergeConflictEngine.$conflicts
            .receive(on: RunLoop.main)
            .sink { [weak self, weak view] conflicts in
                guard let self, let view else { return }
                self.applyMergeConflictBanners(conflicts: conflicts, in: view)
            }
        // Seed once so the very first `attach` paints whatever the
        // engine had cached for the document we just bound to. The
        // sink only fires on subsequent emits.
        if let workspace, let view = self.view {
            applyMergeConflictBanners(
                conflicts: workspace.mergeConflictEngine.conflicts,
                in: view)
        }
    }

    // MARK: - Banner lifecycle

    /// Drop the previous banner set and install a fresh one for
    /// the new conflict list. Called from the Combine sink + from
    /// `applyMergeConflictResolution` after the parser refresh.
    func applyMergeConflictBanners(conflicts: [MergeConflict],
                                   in view: ScintillaView) {
        // Tear down old banners. addSubview on each new banner
        // would technically work without removing the old ones,
        // but they'd stack up forever as the user types into a
        // file — explicit removeFromSuperview keeps the view tree
        // clean.
        for banner in mergeConflictBanners {
            banner.removeFromSuperview()
        }
        mergeConflictBanners.removeAll(keepingCapacity: true)

        guard !conflicts.isEmpty else { return }
        for conflict in conflicts {
            let banner = MergeConflictBannerView(
                conflict: conflict,
                onAccept: { [weak self, weak view] choice in
                    guard let self, let view else { return }
                    self.applyMergeConflictResolution(
                        seed: conflict, choice: choice, in: view)
                },
                onCompare: { [weak self] in
                    guard let self else { return }
                    self.openMergeConflictCompare(seed: conflict)
                })
            banner.translatesAutoresizingMaskIntoConstraints = true
            banner.autoresizingMask = [.width]
            view.addSubview(banner)
            mergeConflictBanners.append(banner)
        }
        repositionMergeConflictBanners(in: view)
    }

    /// Recompute every banner's frame from its conflict's
    /// `startLine`. Called from `SCN_UPDATEUI` (caret / scroll /
    /// selection ticks) so a scrollwheel gesture or a cmd-up jump
    /// pulls the banners along with the source block. Cheap —
    /// at most a handful of conflicts per file in practice.
    func repositionMergeConflictBanners(in view: ScintillaView) {
        guard !mergeConflictBanners.isEmpty else { return }
        let viewWidth = view.bounds.width
        for banner in mergeConflictBanners {
            let line0 = max(0, banner.conflict.startLine - 1)
            let position = view.message(SCI.POSITIONFROMLINE,
                                        wParam: UInt(line0))
            let y = CGFloat(view.message(SCI.POINTYFROMPOSITION,
                                         wParam: 0,
                                         lParam: position))
            let height = MergeConflictBannerView.bannerHeight
            // Banner sits in front of the `<<<<<<<` marker line.
            // Drawing on top of the marker (rather than above it,
            // which would shift visible source rows downward) keeps
            // the file's line numbers stable and signals "the
            // marker line is the affordance" the same way VSCode's
            // CodeLens treats its anchor row.
            banner.frame = NSRect(x: 0, y: y,
                                  width: viewWidth, height: height)
        }
    }

    // MARK: - Resolution

    /// Translate the user's button click into an
    /// SCI_REPLACETARGET. We don't trust the seed conflict's
    /// stored range — `Document.text` rides a 50ms throttle in
    /// front of SCN_MODIFIED, so a fast typist could have shifted
    /// the buffer between the parser snapshot and the click. We
    /// re-flush + re-parse just before the replacement so the
    /// range we hand Scintilla matches the live buffer.
    func applyMergeConflictResolution(seed: MergeConflict,
                                      choice: MergeConflictChoice,
                                      in view: ScintillaView) {
        // Drain any throttled keystrokes so doc.text matches the
        // view buffer, then re-parse to find the conflict that
        // still starts on the same line. If the user's edits have
        // dismantled the markers since the banner was rendered,
        // the lookup misses and we silently bail — the next
        // engine emit will already have removed the banner.
        doc.flushPendingEdit?()
        let conflicts = MergeConflictParser.parse(doc.text)
        guard let live = conflicts.first(where: {
            $0.startLine == seed.startLine
                && $0.currentText == seed.currentText
                && $0.incomingText == seed.incomingText
        }) else {
            workspace?.mergeConflictEngine.refresh()
            return
        }

        let resolution = MergeConflictResolver.resolve(
            live, choice: choice, in: doc.text)

        // Wrap the replace in a single undoable transaction so
        // ⌘Z reverts the whole accept in one shot. Scintilla
        // treats SETTARGETSTART/END + REPLACETARGET as a single
        // edit by default, but the BEGIN/END pair makes the
        // intent explicit + future-proofs against a multi-step
        // resolution mode (e.g. "Accept Both with manual
        // separator") landing in a follow-up phase.
        view.message(SCI.BEGINUNDOACTION)
        view.message(SCI.SETTARGETSTART,
                     wParam: UInt(bitPattern: resolution.range.location))
        view.message(SCI.SETTARGETEND,
                     wParam: UInt(bitPattern: resolution.range.location
                                  + resolution.range.length))
        let bytes = Array(resolution.replacement.utf8)
        if bytes.isEmpty {
            view.message(SCI.REPLACETARGET, wParam: 0, lParam: 0)
        } else {
            _ = bytes.withUnsafeBufferPointer { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return view.message(SCI.REPLACETARGET,
                                    wParam: UInt(bytes.count),
                                    lParam: Int(bitPattern: base))
            }
        }
        view.message(SCI.ENDUNDOACTION)

        // Push the buffer change back into doc.text so the engine
        // can re-parse without waiting for the throttled
        // SCN_MODIFIED tick. flushDocSync is a no-op on large
        // files (their text stays empty by design) and a cheap
        // O(N) read on normal files.
        flushDocSync()
        workspace?.mergeConflictEngine.refresh()
    }

    /// Phase 68b — Compare hand-off. Spins up a fresh `DiffSession`
    /// pre-loaded with the conflict's two sides as inline strings
    /// (no URLs — `loadInline` was added precisely for this) and
    /// hands it to `Workspace.compareSession`, which flips
    /// MainWindow over to the side-by-side DiffView. Pane labels
    /// surface the marker labels (`HEAD` / `feature/translations`)
    /// so the user always knows which side they're staring at.
    func openMergeConflictCompare(seed: MergeConflict) {
        guard let workspace else { return }
        // Prefer the live conflict (post-flush re-parse) so a fast
        // typist who edited the buffer between banner render and
        // click compares the *current* text, not the stale snapshot.
        // Fall back to the seed if the parser no longer finds a
        // matching block — the user can still see what the banner
        // captured at render time.
        doc.flushPendingEdit?()
        let live = MergeConflictParser.parse(doc.text)
            .first(where: { $0.startLine == seed.startLine })
        let conflict = live ?? seed

        let session = DiffSession()
        let docTitle = doc.title
        session.loadInline(
            leftText: conflict.currentText,
            leftLabel: conflict.currentLabel.isEmpty ? "ours" : conflict.currentLabel,
            leftSubtitle: docTitle,
            rightText: conflict.incomingText,
            rightLabel: conflict.incomingLabel.isEmpty ? "theirs" : conflict.incomingLabel,
            rightSubtitle: docTitle)
        workspace.compareSession = session
    }

    // MARK: - Navigation (Phase 68b)

    /// Jump the caret to the start of the next conflict block after
    /// the current line. Wraps to the first conflict when past the
    /// last one. Beeps when the file has no conflicts so a stray
    /// keystroke doesn't silently no-op.
    func gotoNextMergeConflict(in view: ScintillaView) {
        let conflicts = workspace?.mergeConflictEngine.conflicts ?? []
        guard let target = MergeConflictNavigation.next(
            after: currentLine1Based(in: view), in: conflicts) else {
            NSSound.beep()
            return
        }
        moveCaretToConflict(line1: target, in: view)
    }

    /// Symmetric with `gotoNextMergeConflict` — jumps to the
    /// previous conflict, wrapping to the last when past the first.
    func gotoPrevMergeConflict(in view: ScintillaView) {
        let conflicts = workspace?.mergeConflictEngine.conflicts ?? []
        guard let target = MergeConflictNavigation.previous(
            before: currentLine1Based(in: view), in: conflicts) else {
            NSSound.beep()
            return
        }
        moveCaretToConflict(line1: target, in: view)
    }

    private func currentLine1Based(in view: ScintillaView) -> Int {
        let pos = view.message(SCI.GETCURRENTPOS)
        let line0 = view.message(SCI.LINEFROMPOSITION,
                                 wParam: UInt(pos), lParam: 0)
        return Int(line0) + 1
    }

    /// Distinct from `Coordinator+GitGutter.swift`'s fileprivate
    /// `moveCaret(to:in:)` only by name — Swift resolves them per
    /// file, so renaming here keeps them from looking like a
    /// duplicate during a future refactor that promotes either
    /// helper to module-internal.
    private func moveCaretToConflict(line1: Int, in view: ScintillaView) {
        let line0 = max(0, line1 - 1)
        view.message(SCI.GOTOLINE, wParam: UInt(line0))
        view.message(SCI.SCROLLCARET)
    }
}
