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

    /// Phase 35b-4-e — diff search state. `searchVisible` toggles
    /// the bar via the magnifying-glass button or ⌘F; `searchQuery`
    /// is the live substring filter (case-insensitive). When the
    /// bar is hidden the query is forced empty so a stale match
    /// can't keep filtering invisible-state results.
    @State private var searchVisible: Bool = false
    @State private var searchQuery: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if searchVisible {
                searchBar
            }
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
            // Phase 35b-4-e — search toggle. Click or ⌘F to flip
            // visibility; clicking when already visible collapses
            // and clears the query so the next open is a clean
            // slate.
            Button {
                toggleSearch()
            } label: {
                Image(systemName: searchVisible
                      ? "magnifyingglass.circle.fill"
                      : "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: .command)
            .help(L10n.t("projectDiff.action.search"))
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

    /// Phase 35b-4-e — search bar shown below the header when
    /// `searchVisible` is true. Plain TextField + clear button;
    /// no regex, no whole-word, just substring (case-insensitive).
    /// Filtering is computed lazily on `filteredEntries` so an
    /// empty query is a free pass-through.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField(L10n.t("projectDiff.search.placeholder"),
                      text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit {
                    // Enter on an empty query collapses the bar —
                    // otherwise it just commits the current filter.
                    if searchQuery.isEmpty {
                        searchVisible = false
                    }
                }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help(L10n.t("projectDiff.action.clearSearch"))
            }
            Text(searchCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Toggle the search bar. Opening focuses the field; closing
    /// drops the query so a re-open starts clean.
    private func toggleSearch() {
        if searchVisible {
            searchVisible = false
            searchQuery = ""
        } else {
            searchVisible = true
            // .async hop so the TextField is in the view tree
            // before we ask it to take focus.
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    /// "(N matches)" / "(no matches)" — only renders when the
    /// query is non-empty, otherwise we keep the bar visually
    /// quiet.
    private var searchCountLabel: String {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return "" }
        let n = filteredEntries.count
        if n == 0 {
            return L10n.t("projectDiff.search.noMatches")
        }
        let key = n == 1 ? "projectDiff.search.matches.one"
                         : "projectDiff.search.matches.many"
        return L10n.t(key, n)
    }

    // MARK: - Filtering

    /// Search-aware view of `entries`. When the trimmed query is
    /// empty, returns `entries` verbatim (free pass-through). When
    /// non-empty, keeps only those entries that contain at least
    /// one hunk with at least one body line whose substring
    /// matches the query (case-insensitive). Hunks themselves
    /// are not filtered out of the kept entries — the whole
    /// file's diff stays visible so the user has surrounding
    /// context, with the matching lines highlighted in the body.
    private var filteredEntries: [ProjectDiffEntry] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { entry in
            entry.stagedHunks.contains(where: { hunkMatches($0, q) })
                || entry.workingHunks.contains(where: { hunkMatches($0, q) })
        }
    }

    /// `true` iff any body line in `hunk` contains `q`
    /// (case-insensitive substring).
    private func hunkMatches(_ hunk: GitClient.Hunk, _ q: String) -> Bool {
        hunk.bodyLines.contains(where: { lineMatches($0, q) })
    }

    /// Single-line match helper. Pulled out so highlight
    /// rendering can share the exact same predicate the filter
    /// uses — no risk of "shows in list but not highlighted".
    private func lineMatches(_ line: String, _ q: String) -> Bool {
        line.range(of: q, options: .caseInsensitive) != nil
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
        } else if filteredEntries.isEmpty {
            // Phase 35b-4-e — search is active but matches nothing.
            // We still want the header search bar (lives above
            // `content` in body) to stay live so the user can
            // refine the query without losing focus.
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(.secondary)
                Text("projectDiff.search.noMatches.detail",
                     bundle: .module)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // ScrollViewReader gives us programmatic .scrollTo for
            // the focus-path handoff from the sidebar; per-file
            // section ids match `entry.id` (== entry.path) so the
            // proxy can target a specific file without us
            // maintaining a parallel id table.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(filteredEntries) { entry in
                            fileSection(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(14)
                }
                // Re-fire on every focusPath flip *and* on every
                // entries refresh — the second trigger covers the
                // initial load case where focusPath got set first
                // (sidebar click) but entries hadn't resolved yet.
                .onChange(of: workspace.projectDiffFocusPath) { _, newPath in
                    scrollIfNeeded(proxy, target: newPath)
                }
                .onChange(of: entries) { _, _ in
                    scrollIfNeeded(proxy, target: workspace.projectDiffFocusPath)
                }
            }
        }
    }

    /// Animate a scroll to `target`, then nil out the workspace
    /// flag so a second sidebar click on the *same* file still
    /// re-triggers (otherwise SwiftUI would coalesce the no-op).
    private func scrollIfNeeded(_ proxy: ScrollViewProxy,
                                target: String?) {
        guard let target,
              entries.contains(where: { $0.id == target }) else {
            return
        }
        withAnimation(.easeOut(duration: 0.20)) {
            proxy.scrollTo(target, anchor: .top)
        }
        // Drain the focus latch so the same path can be re-targeted
        // later. Done on the next runloop tick so the animation
        // above keeps reading the still-set value.
        DispatchQueue.main.async {
            workspace.projectDiffFocusPath = nil
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
                // Stage All — only meaningful when there's at
                // least one working-tree hunk to promote to the
                // index. Disabled state keeps the button visible
                // (so the row layout doesn't reflow when the
                // last hunk is staged) but obviously inert.
                Button {
                    Task {
                        await engine.stagePath(entry.path)
                        await reload()
                    }
                } label: {
                    Text("projectDiff.action.stageAll", bundle: .module)
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(entry.workingHunks.isEmpty)
                .help(L10n.t("projectDiff.action.stageAll.hint"))
                // Unstage All — symmetric. Disabled when the
                // staged column is empty so a stray click can't
                // no-op into an alert.
                Button {
                    Task {
                        await engine.unstagePath(entry.path)
                        await reload()
                    }
                } label: {
                    Text("projectDiff.action.unstageAll", bundle: .module)
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(entry.stagedHunks.isEmpty)
                .help(L10n.t("projectDiff.action.unstageAll.hint"))
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
    /// action buttons. We render bodyLines verbatim
    /// (preserving the leading ' ' / '+' / '-' so widths line
    /// up between context and changed lines) and tint the row
    /// background to make additions / deletions glanceable.
    ///
    /// Working-tree hunks get an extra `Revert` button that
    /// drops the change (destructive — confirmed via NSAlert
    /// before it dispatches). Staged hunks don't, because
    /// "unstage + discard" is what working-tree revert does
    /// after a stage, and chaining the two is more legible
    /// than a one-shot "revert from index" that bypasses the
    /// working tree.
    private func hunkExcerpt(_ hunk: GitClient.Hunk,
                             isStaged: Bool,
                             path: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hunk.headerLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if !isStaged {
                    Button {
                        revertHunkWithConfirm(hunk, path: path)
                    } label: {
                        Text("projectDiff.action.revertHunk", bundle: .module)
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.t("projectDiff.action.revertHunk.hint"))
                }
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
                    let q = searchQuery.trimmingCharacters(in: .whitespaces)
                    let matched = !q.isEmpty && lineMatches(line, q)
                    HStack(spacing: 0) {
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(lineForeground(line))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(lineBackground(line))
                    // Phase 35b-4-e — search match highlight. Layered
                    // *over* the +/- diff tint via a second .background
                    // call (SwiftUI stacks them bottom-up). Yellow
                    // matches what zed / GitHub use; opacity stays low
                    // so the underlying green/red still reads.
                    .background(matched
                                ? Color.yellow.opacity(0.30)
                                : Color.clear)
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

    // MARK: - Destructive confirmations

    /// Revert one working-tree hunk, after confirmation. We hand-
    /// roll an NSAlert (rather than `.confirmationDialog`) for
    /// parity with `SourceControlSidebar.discardWithConfirm`: the
    /// "Revert" button is marked .destructive and the default-
    /// Enter focus is on Cancel, so a stray Return doesn't lose
    /// the user's edits.
    private func revertHunkWithConfirm(_ hunk: GitClient.Hunk,
                                       path: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("projectDiff.revert.confirm.title")
        alert.informativeText = String(
            format: L10n.t("projectDiff.revert.confirm.message"),
            path
        )
        alert.addButton(withTitle: L10n.t("projectDiff.action.revertHunk"))
        alert.addButton(withTitle: L10n.t("alert.button.cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await engine.revertHunk(hunk, path: path)
                await reload()
            }
        }
    }
}
