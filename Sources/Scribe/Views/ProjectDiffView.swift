//
//  ProjectDiffView.swift
//  Phase 35b-4-b — Project Diff multibuffer.
//
//  zed surfaces a special "Project Diff" pane that lists every
//  changed file in the workspace as a stack of diff excerpts, so
//  the user can review everything in one scroll instead of
//  expanding hunks one at a time in the sidebar. This is the
//  Scribe equivalent.
//
//  Why an overlay (not a new tab kind):
//    Document carries a lot of file-specific state (encoding,
//    lineEnding, isDirty, gitGutter, isLargeFile, save hooks…).
//    A virtual "Project Diff" tab would either drag all that
//    along or short-circuit half of it with `if doc.kind ==
//    .projectDiff` branches everywhere — both cluttery. An
//    overlay keyed off Workspace.projectDiffVisible keeps the
//    tab strip + sidebar live behind it, so the user can still
//    see the source-control status freshen as they stage /
//    unstage from inside the multibuffer.
//
//  Per-hunk Stage / Unstage flow:
//    Reuses GitStatusEngine.{stageHunk, unstageHunk} verbatim.
//    The view doesn't know about `git apply --cached`; it just
//    posts intents and reloads the entry list from
//    `engine.projectDiff()` afterwards. That refresh is what
//    drains a fully-staged file from the staged-only column,
//    or makes a partial unstage flip a file from staged-only
//    back to mixed.
//

import SwiftUI

struct ProjectDiffView: View {
    @ObservedObject var engine: GitStatusEngine
    @EnvironmentObject var workspace: Workspace

    /// Loaded diff payload. Empty during the very first refresh —
    /// the view shows a centred ProgressView in that window.
    @State private var entries: [ProjectDiffEntry] = []

    /// Latch flips false once the first refresh resolves so we
    /// don't ping-pong between "Loading…" and "No changes" while
    /// the user is staging individual hunks.
    @State private var hasLoadedOnce: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: engine.rows) {
            // Re-run whenever the engine's rows change (e.g. an
            // outside refresh after a save) so the multibuffer
            // tracks status without the user clicking refresh.
            await reload()
        }
    }

    // MARK: - Header

    /// Header strip with title + entry count + Refresh + Done.
    /// `Done` returns control to the editor; the multibuffer
    /// is non-modal (the sidebar / tab strip stay live behind
    /// it) so this is just a visibility toggle.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("projectDiff.title", bundle: .module)
                .font(.headline)
            Text(entryCountLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(L10n.t("projectDiff.action.refresh"))
            Button {
                workspace.projectDiffVisible = false
            } label: {
                Text("projectDiff.action.done", bundle: .module)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// "(N files)" — singular / plural is folded into the i18n
    /// catalogue (Localizable.stringsdict would be cleaner; for
    /// now we manually pick the key) so non-English locales can
    /// follow their own pluralisation rules.
    private var entryCountLabel: String {
        let n = entries.count
        if n == 0 { return "" }
        let key = n == 1 ? "projectDiff.count.one"
                         : "projectDiff.count.many"
        return L10n.t(key, n)
    }

    // MARK: - Content

    /// Either the empty / loading placeholder, or the scroll-
    /// list of file sections. Split out so `body` reads as
    /// "header / divider / content" without the conditional
    /// inline.
    @ViewBuilder
    private var content: some View {
        if !hasLoadedOnce {
            VStack(spacing: 8) {
                ProgressView()
                Text("projectDiff.loading", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(.secondary)
                Text("projectDiff.empty", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(entries) { entry in
                        fileSection(entry)
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - File section

    /// One per-file block: title row + (optional) staged strip +
    /// (optional) working-tree strip. The two strips visually
    /// distinguish "ready to commit" vs "still in your tree" so
    /// the user can pick a hunk for the right action without
    /// reading labels.
    private func fileSection(_ entry: ProjectDiffEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(entry.path)
                    .font(.system(.body, design: .monospaced)
                              .weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    workspace.openFile(at: entry.url)
                    workspace.projectDiffVisible = false
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(L10n.t("projectDiff.action.openFile"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.08))

            if !entry.stagedHunks.isEmpty {
                hunkGroup(entry.stagedHunks,
                          isStaged: true,
                          path: entry.path)
            }
            if !entry.workingHunks.isEmpty {
                hunkGroup(entry.workingHunks,
                          isStaged: false,
                          path: entry.path)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
        )
    }

    /// One staged-or-working strip with section label + N hunk
    /// excerpts. The section label is what tells the user
    /// whether the action button on each hunk will Stage or
    /// Unstage; the button itself stays terse.
    private func hunkGroup(_ hunks: [GitClient.Hunk],
                           isStaged: Bool,
                           path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isStaged ? "projectDiff.section.staged"
                          : "projectDiff.section.changes",
                 bundle: .module)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            ForEach(hunks.indices, id: \.self) { idx in
                hunkExcerpt(hunks[idx],
                            isStaged: isStaged,
                            path: path)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 8)
    }

    /// One hunk: header line ("@@ -a,b +c,d @@") + per-line
    /// monospace body coloured by leading char + trailing
    /// Stage / Unstage button. We render bodyLines verbatim
    /// (preserving the leading ' ' / '+' / '-' so widths line
    /// up between context and changed lines) and tint the row
    /// background to make additions / deletions glanceable.
    private func hunkExcerpt(_ hunk: GitClient.Hunk,
                             isStaged: Bool,
                             path: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hunk.headerLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        if isStaged {
                            await engine.unstageHunk(hunk, path: path)
                        } else {
                            await engine.stageHunk(hunk, path: path)
                        }
                        await reload()
                    }
                } label: {
                    Text(isStaged ? "projectDiff.action.unstageHunk"
                                  : "projectDiff.action.stageHunk",
                         bundle: .module)
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.06))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunk.bodyLines.indices, id: \.self) { lineIdx in
                    let line = hunk.bodyLines[lineIdx]
                    HStack(spacing: 0) {
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(lineForeground(line))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(lineBackground(line))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Line tinting

    /// Foreground colour for one body line. Mirrors what zed and
    /// GitHub do — green/red text on tinted backgrounds, gray for
    /// context, soft gray for the "\ No newline" sentinel.
    private func lineForeground(_ line: String) -> Color {
        guard let ch = line.first else { return .primary }
        switch ch {
        case "+": return Color.green
        case "-": return Color.red
        case "\\": return .secondary  // "\ No newline at end of file"
        default:  return .primary
        }
    }

    /// Background tint for one body line. Identical hue to the
    /// foreground but at a low opacity so the diff reads at a
    /// glance even when the user is skim-scrolling.
    private func lineBackground(_ line: String) -> Color {
        guard let ch = line.first else { return .clear }
        switch ch {
        case "+": return Color.green.opacity(0.10)
        case "-": return Color.red.opacity(0.10)
        default:  return .clear
        }
    }

    // MARK: - Refresh

    /// Pull `engine.projectDiff()` and replace `entries`. Keep
    /// the old list while loading the new one so a stage / unstage
    /// click doesn't blank-flash the view between actions.
    private func reload() async {
        let next = await engine.projectDiff()
        entries = next
        hasLoadedOnce = true
    }
}
