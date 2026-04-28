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

    var body: some View {
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
            SourceControlRow(row: row)
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
