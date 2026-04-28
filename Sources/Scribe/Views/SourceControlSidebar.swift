//
//  SourceControlSidebar.swift
//  Phase 35b-1 — read-only Git status panel. Mirrors zed's "Git
//  Panel" in shape: one button in the sidebar mode-switcher gets
//  you a list of every file diverging from HEAD, sectioned by
//  staged / changes / untracked / conflicts. Clicking a row opens
//  it in the editor.
//
//  This commit deliberately ships only the read surface. Per-hunk
//  stage/unstage, commit message, push/pull are Phase 35b-2 / 35b-3:
//  splitting the work keeps each commit small enough that a
//  reviewer (or future-me) can hold the diff in their head.
//

import SwiftUI

struct SourceControlSidebar: View {
    @ObservedObject var engine: GitStatusEngine
    @EnvironmentObject var workspace: Workspace

    /// Phase 35b-2b — commit panel state lives here (not in the
    /// engine) because it's a *draft* — abandoning the sidebar
    /// shouldn't mutate the engine's git state. Persisting between
    /// repos is handled implicitly by SwiftUI keeping `@State`
    /// alive while the view is in the hierarchy.
    @State private var commitMessage: String = ""
    @State private var amend: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            branchHeader
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            Group {
                switch engine.state {
                case .idle:
                    emptyState(titleKey: "sourceControl.empty.noFolder",
                               system: "folder")
                case .notInRepo:
                    emptyState(titleKey: "sourceControl.empty.notInRepo",
                               system: "exclamationmark.triangle")
                case .loaded:
                    if engine.rows.isEmpty {
                        emptyState(titleKey: "sourceControl.empty.clean",
                                   system: "checkmark.seal")
                    } else {
                        rowList
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Only show commit panel when the engine has a repo —
            // hiding it for `.idle` / `.notInRepo` keeps the empty
            // states uncluttered.
            if engine.state == .loaded {
                Divider()
                commitPanel
            }
        }
    }

    // MARK: - Branch header (Phase 35b-2b/2c)

    /// Slim header: branch name, ahead/behind chip, fetch/pull/push
    /// triplet. Detached-HEAD copy replaces the branch when nil so
    /// the user always knows which ref their changes target. Remote
    /// buttons stay enabled regardless of upstream state — git's
    /// own error reporting is clearer than any pre-flight check we
    /// could implement here, and a one-click "see what git says"
    /// is sometimes the actual debugging step.
    private var branchHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(engine.branch
                 ?? L10n.t("sourceControl.branch.detached"))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            // Ahead/behind chip — only renders when `aheadBehind`
            // is non-nil and not 0/0. Up-to-date state is implicit
            // (no chip = "nothing to report") which keeps the row
            // visually quiet 99% of the time.
            if let ab = engine.aheadBehind, !ab.isUpToDate {
                aheadBehindChip(ab)
            }
            Spacer()
            remoteButton(systemName: "arrow.down.circle",
                         titleKey: "sourceControl.action.fetch") {
                Task { await engine.fetch() }
            }
            remoteButton(systemName: "arrow.down.to.line",
                         titleKey: "sourceControl.action.pull") {
                Task { await engine.pull() }
            }
            // Push gets a fill variant when ahead > 0 so it visually
            // signals "you have local commits to publish". A common
            // sidebar UX pattern (zed/GitHub Desktop both do this).
            remoteButton(systemName: (engine.aheadBehind?.ahead ?? 0) > 0
                            ? "arrow.up.circle.fill"
                            : "arrow.up.circle",
                         titleKey: "sourceControl.action.push") {
                Task { await engine.push() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// `↑N ↓M` chip rendered next to the branch name. Counts that
    /// are zero are skipped so a "behind only" repo doesn't have
    /// a stray "↑0".
    private func aheadBehindChip(_ ab: GitClient.AheadBehind) -> some View {
        HStack(spacing: 4) {
            if ab.ahead > 0 {
                Label("\(ab.ahead)", systemImage: "arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            if ab.behind > 0 {
                Label("\(ab.behind)", systemImage: "arrow.down")
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            Capsule().fill(Color.secondary.opacity(0.12))
        )
    }

    /// Compact icon button for a remote operation. plainButtonStyle
    /// + bordered control size mirrors the row-action cluster from
    /// 35b-2a so the visual language stays consistent across the
    /// sidebar.
    private func remoteButton(systemName: String,
                              titleKey: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help(L10n.t(titleKey))
    }

    // MARK: - Commit panel (Phase 35b-2b)

    private var commitPanel: some View {
        let stagedCount = engine.rows.filter { $0.hasStagedChanges }.count
        // Empty-after-trim is the universal "no message" check;
        // git's --cleanup=strip would also reject this so we save a
        // round-trip by disabling the button up front.
        let hasMessage = !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Amend doesn't require staged changes — rewording the
        // last commit is a perfectly valid use of --amend even on
        // an otherwise-clean tree.
        let canCommit = hasMessage && (amend || stagedCount > 0)

        return VStack(alignment: .leading, spacing: 6) {
            // Use a TextEditor (multi-line) rather than TextField so
            // a Linux-kernel-style commit body fits without horizontal
            // scrolling. macOS auto-grows up to maxHeight.
            TextEditor(text: $commitMessage)
                .font(.system(size: 12))
                .frame(minHeight: 56, maxHeight: 120)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
                .overlay(alignment: .topLeading) {
                    if commitMessage.isEmpty {
                        Text(amend
                             ? L10n.t("sourceControl.commit.placeholder.amend")
                             : L10n.t("sourceControl.commit.placeholder"))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { amend },
                    set: { newValue in
                        amend = newValue
                        // Pre-fill on enable; clear on disable. We
                        // only seed when the textarea is otherwise
                        // empty so we never overwrite something the
                        // user already typed.
                        if newValue, commitMessage.isEmpty,
                           let subject = engine.headSubject {
                            commitMessage = subject
                        } else if !newValue,
                                  commitMessage == engine.headSubject {
                            commitMessage = ""
                        }
                    }
                )) {
                    Text("sourceControl.commit.amend", bundle: .module)
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button {
                    Task {
                        let msg = commitMessage
                        let isAmend = amend
                        await engine.commit(message: msg, amend: isAmend)
                        // Clear the draft only on success-path; the
                        // engine's NSAlert already informed the user
                        // about failure and we want them to be able
                        // to fix + retry without retyping. We can't
                        // observe success directly, so pivot on the
                        // refreshed row list: a successful commit
                        // empties the staged section, and we'd be
                        // racing the refresh anyway. The UX trade-off
                        // here is leaving the message text after a
                        // failed commit, which is what zed does.
                        await MainActor.run {
                            // Heuristic: if no error fired (no alert
                            // was modal'd, which we can't inspect) AND
                            // the staged count dropped to zero (or
                            // amend was used), assume success.
                            let stillStaged = engine.rows.contains { $0.hasStagedChanges }
                            if !stillStaged || isAmend {
                                commitMessage = ""
                                amend = false
                            }
                        }
                    }
                } label: {
                    Text(amend
                         ? "sourceControl.commit.amend.action"
                         : "sourceControl.commit.action",
                         bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canCommit)
                .keyboardShortcut(.return, modifiers: .command)
                .help(L10n.t("sourceControl.commit.shortcut.hint"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Row list

    private var rowList: some View {
        // Bucket the rows once per render. The lists themselves are
        // tiny (typically <100 entries even on monorepos) so this
        // O(N) split per body invocation is irrelevant against
        // SwiftUI's diff cost.
        let conflicts = engine.rows.filter { $0.isConflict }
        let staged    = engine.rows.filter {
            $0.hasStagedChanges && !$0.isConflict
        }
        let changes   = engine.rows.filter {
            !$0.hasStagedChanges && $0.hasUnstagedChanges
                && !$0.isUntracked && !$0.isConflict
        }
        let untracked = engine.rows.filter {
            $0.isUntracked && !$0.isConflict
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !conflicts.isEmpty {
                    section(titleKey: "sourceControl.section.conflicts",
                            count: conflicts.count,
                            tint: .red,
                            rows: conflicts,
                            hunkSource: nil)
                }
                if !staged.isEmpty {
                    // Phase 35b-3-ii — staged rows expand into the
                    // cached diff (index-vs-HEAD) so each hunk is
                    // unstage-able.
                    section(titleKey: "sourceControl.section.staged",
                            count: staged.count,
                            tint: .green,
                            rows: staged,
                            hunkSource: .staged)
                }
                if !changes.isEmpty {
                    // Phase 35b-3-ii — changes rows expand into the
                    // working diff (working-vs-index) so each hunk
                    // is stage-able.
                    section(titleKey: "sourceControl.section.changes",
                            count: changes.count,
                            tint: .orange,
                            rows: changes,
                            hunkSource: .changes)
                }
                if !untracked.isEmpty {
                    // Untracked has no two-sided diff, so no per-
                    // hunk surface. The whole-file [+] in the row
                    // hover already covers staging it.
                    section(titleKey: "sourceControl.section.untracked",
                            count: untracked.count,
                            tint: .gray,
                            rows: untracked,
                            hunkSource: nil)
                }
                Spacer(minLength: 16)
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func section(titleKey: LocalizedStringKey,
                         count: Int,
                         tint: Color,
                         rows: [GitFileStatus],
                         hunkSource: SourceControlRow.HunkSource?) -> some View {
        HStack(spacing: 6) {
            Text(titleKey, bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.18))
                )
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)

        ForEach(rows) { row in
            SourceControlRow(row: row, engine: engine, hunkSource: hunkSource)
                .onTapGesture {
                    workspace.openFile(at: row.url)
                }
        }
    }

    // MARK: - Empty state

    private func emptyState(titleKey: LocalizedStringKey,
                            system: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: system)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(titleKey, bundle: .module)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One file row. Pulled out so SwiftUI's per-row identity stays
/// stable when sections re-shuffle (the engine refresh may move a
/// file from "Changes" → "Staged" without it disappearing).
private struct SourceControlRow: View {
    /// Phase 35b-3-ii — which side of the diff the row's hunk
    /// expansion uses, and therefore what the per-hunk button
    /// does. `.staged` ⇒ unstage from index. `.changes` ⇒ stage
    /// into index. Conflict / untracked rows are passed nil at
    /// the call site, which suppresses the chevron entirely.
    enum HunkSource { case staged, changes }

    let row: GitFileStatus
    let engine: GitStatusEngine
    let hunkSource: HunkSource?
    @State private var hover = false
    @State private var expanded = false
    @State private var hunks: [GitClient.Hunk] = []
    @State private var hunksLoaded = false
    @State private var hunksLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // Phase 35b-3-ii — leading chevron. Tapping toggles
                // the per-hunk expansion. We render an invisible
                // 12 pt placeholder for rows without a hunk surface
                // (conflicts / untracked) so the column of file
                // names stays visually aligned across sections.
                if hunkSource != nil {
                    Button(action: toggleExpanded) {
                        Image(systemName: expanded
                              ? "chevron.down"
                              : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t(expanded
                                 ? "sourceControl.hunk.collapse"
                                 : "sourceControl.hunk.expand"))
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }
                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusTint)
                    .frame(width: 16, alignment: .center)
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text(displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(parentHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(0)
                Spacer(minLength: 4)
                if hover {
                    rowActions
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.06) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .onHover { hover = $0 }
            .help(row.path)

            // Phase 35b-3-ii — hunk list. We render it inside the
            // same VStack so SwiftUI animates the expand/collapse
            // smoothly and the list scrolls with its parent row.
            if expanded, let source = hunkSource {
                hunkList(source: source)
            }
        }
    }

    /// Toggle expand state. On expand we kick off an async hunk
    /// fetch — `hunks(forPath:cached:)` runs the git CLI on a
    /// detached task so we never block the main run loop, and
    /// stores into local @State once the result lands.
    private func toggleExpanded() {
        guard let source = hunkSource else { return }
        if expanded {
            expanded = false
            return
        }
        expanded = true
        // Always re-fetch on each expand: between two expansions
        // the index might have moved (the user could have committed
        // from another terminal), and a stale hunk list applied
        // back will fail at `git apply` time with a confusing
        // "patch does not apply" alert.
        hunksLoading = true
        Task { [path = row.path] in
            let fresh = await engine.hunks(forPath: path,
                                           cached: source.cached)
            await MainActor.run {
                self.hunks = fresh
                self.hunksLoaded = true
                self.hunksLoading = false
            }
        }
    }

    /// Per-hunk list view. Each line shows a short summary
    /// ("@@ -12,4 +12,5 @@" + section name + +/- counts) and a
    /// hover-revealed [+] / [-] button that calls into the engine.
    @ViewBuilder
    private func hunkList(source: HunkSource) -> some View {
        if hunksLoading && !hunksLoaded {
            HStack {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text("sourceControl.hunk.loading", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 38)
            .padding(.vertical, 2)
        } else if hunks.isEmpty {
            // Empty state means git produced no diff for this path —
            // common when the row is a pure rename (R) or a binary
            // file that diff suppresses.
            Text("sourceControl.hunk.none", bundle: .module)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 38)
                .padding(.vertical, 2)
        } else {
            ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                HunkRow(hunk: hunk,
                        source: source,
                        path: row.path,
                        engine: engine)
            }
        }
    }

    // MARK: - Hover actions

    /// Cluster of [discard] [+] / [-] buttons. Layout shape mirrors
    /// zed: discard sits leftmost (it's the destructive one and we
    /// surround it with whitespace), then either stage or unstage
    /// based on which column the row populates. A row with both
    /// staged AND unstaged changes (e.g. "AM" — staged-add then
    /// modified) shows BOTH so the user can deal with each
    /// independently.
    @ViewBuilder
    private var rowActions: some View {
        actionButton(
            system: "arrow.uturn.backward",
            tooltipKey: "sourceControl.action.discard",
            tint: .red,
            action: discardWithConfirm
        )
        if row.hasStagedChanges {
            actionButton(
                system: "minus",
                tooltipKey: "sourceControl.action.unstage",
                tint: .orange,
                action: { Task { await engine.unstage(row) } }
            )
        }
        if row.hasUnstagedChanges || row.isUntracked {
            actionButton(
                system: "plus",
                tooltipKey: "sourceControl.action.stage",
                tint: .green,
                action: { Task { await engine.stage(row) } }
            )
        }
    }

    private func actionButton(system: String,
                              tooltipKey: String,
                              tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .background(
                    Circle().fill(tint.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(L10n.t(tooltipKey))
    }

    /// Discard is destructive — restoring an untracked file is
    /// impossible (we delete it) and restoring a tracked file
    /// silently throws away unstaged edits. Confirm via NSAlert
    /// before handing off to the engine.
    private func discardWithConfirm() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("sourceControl.discard.confirm.title")
        alert.informativeText = String(
            format: L10n.t("sourceControl.discard.confirm.message"),
            row.path
        )
        alert.addButton(withTitle: L10n.t("sourceControl.action.discard"))
        alert.addButton(withTitle: L10n.t("alert.button.cancel"))
        // First button gets the default highlight; we want destructive
        // to require an explicit click rather than default-Enter.
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await engine.discard(row) }
        }
    }

    /// Two-glyph status label, e.g. " M" (modified, unstaged) or
    /// "M " (modified, staged). Mirrors `git status -s` exactly.
    private var statusLabel: String {
        row.staged.glyph + row.unstaged.glyph
    }

    /// Tint tracks the most "interesting" of the two columns —
    /// staged green > conflict red > unstaged orange > untracked
    /// gray. This is what zed does and the colours have a clear
    /// reading order against the row's primary text.
    private var statusTint: Color {
        if row.isConflict { return .red }
        if row.hasStagedChanges { return .green }
        if row.isUntracked { return .gray }
        if row.hasUnstagedChanges { return .orange }
        return .secondary
    }

    /// Last path component — the bit users scan first.
    private var displayName: String {
        let comps = row.path.split(separator: "/")
        return String(comps.last ?? Substring(row.path))
    }

    /// Parent directory in the repo. Shown dimmed next to the
    /// filename so duplicate filenames in different folders are
    /// disambiguated. Empty string when the file is at the repo root.
    private var parentHint: String {
        let comps = row.path.split(separator: "/")
        guard comps.count > 1 else { return "" }
        return comps.dropLast().joined(separator: "/")
    }
}

extension SourceControlRow.HunkSource {
    /// `cached:` flag for `GitClient.diffForApply`. Staged rows
    /// expand the cached diff (index-vs-HEAD); changes rows expand
    /// the working diff (working-vs-index).
    var cached: Bool {
        switch self {
        case .staged:  return true
        case .changes: return false
        }
    }
}

/// Phase 35b-3-ii — single hunk row inside an expanded file. Shows
/// a one-line summary ("@@ ... @@ section · +N -M") and a hover-
/// revealed [+] (stage) or [-] (unstage) button.
private struct HunkRow: View {
    let hunk: GitClient.Hunk
    let source: SourceControlRow.HunkSource
    let path: String
    let engine: GitStatusEngine
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            // Indent matching the file row's chevron+status+icon
            // gutter so hunks visually nest under their parent.
            Color.clear.frame(width: 38, height: 1)
            Text(headerLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let section = hunk.section {
                Text("· \(section)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(countsLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if hover {
                Button(action: applyHunk) {
                    Image(systemName: source == .changes ? "plus" : "minus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(source == .changes ? .green : .orange)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle().fill((source == .changes
                                           ? Color.green
                                           : Color.orange).opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .help(L10n.t(source == .changes
                             ? "sourceControl.action.stageHunk"
                             : "sourceControl.action.unstageHunk"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(hover ? Color.primary.opacity(0.04) : Color.clear)
                .padding(.horizontal, 4)
        )
        .onHover { hover = $0 }
    }

    /// Compact header label — `@@ -12,4 +12,5 @@`.
    private var headerLabel: String {
        "@@ -\(hunk.oldStart),\(hunk.oldLen) +\(hunk.newStart),\(hunk.newLen) @@"
    }

    /// `+N -M` counters — eyeballable insert/delete weight without
    /// having to count body lines manually.
    private var countsLabel: String {
        let plus  = hunk.bodyLines.filter { $0.first == "+" }.count
        let minus = hunk.bodyLines.filter { $0.first == "-" }.count
        return "+\(plus) -\(minus)"
    }

    /// Dispatch to engine.{stageHunk,unstageHunk}. The engine
    /// refreshes after a successful apply, which collapses the
    /// row's expansion (because the row may move sections or
    /// disappear entirely) and the user can re-expand a fresh
    /// list if there's still anything left.
    private func applyHunk() {
        let h = hunk
        let p = path
        switch source {
        case .changes:
            Task { await engine.stageHunk(h, path: p) }
        case .staged:
            Task { await engine.unstageHunk(h, path: p) }
        }
    }
}
