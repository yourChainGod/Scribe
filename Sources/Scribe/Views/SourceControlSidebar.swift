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
                            rows: conflicts)
                }
                if !staged.isEmpty {
                    section(titleKey: "sourceControl.section.staged",
                            count: staged.count,
                            tint: .green,
                            rows: staged)
                }
                if !changes.isEmpty {
                    section(titleKey: "sourceControl.section.changes",
                            count: changes.count,
                            tint: .orange,
                            rows: changes)
                }
                if !untracked.isEmpty {
                    section(titleKey: "sourceControl.section.untracked",
                            count: untracked.count,
                            tint: .gray,
                            rows: untracked)
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
                         rows: [GitFileStatus]) -> some View {
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
            SourceControlRow(row: row, engine: engine)
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
    let row: GitFileStatus
    let engine: GitStatusEngine
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(statusLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusTint)
                .frame(width: 16, alignment: .center)
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            // Display the file name + parent directory hint so two
            // `index.ts` rows from different folders don't collapse
            // into a confusing pair of identical labels. Matches
            // VSCode / zed's row format.
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
            // Phase 35b-2a — hover-revealed action cluster. We keep
            // the buttons hidden by default so a wide list isn't
            // visually noisy; they appear only when the cursor lands
            // on a row (matches the convention zed / VSCode picked).
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
