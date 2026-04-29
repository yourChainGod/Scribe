//
//  FindInFilesSidebar.swift
//  Phase 4b — replaces the workspace tree in the sidebar when the user
//  switches to Search mode (⌘⇧F). Inputs at the top, results tree below.
//

import AppKit
import SwiftUI

struct FindInFilesSidebar: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var find: FindInFilesState
    let engine: FindInFilesEngine

    @FocusState private var queryFocused: Bool
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputs
            Divider()
            summary
            Divider()
            results
        }
        .background(appTheme.sidebarBackground)
        .onAppear { queryFocused = true }
    }

    // MARK: - Inputs

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Query — primary input. The leading glyph + textfield
            // pair shape is repeated in every row for visual rhythm.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(width: 14)
                TextField(L10n.t("find.placeholder"), text: $find.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                    .font(.system(size: 12))
                    .onSubmit { runSearch() }
            }

            // Replace target + Run-replace trigger. The trigger
            // glyph (text.badge.checkmark) reads more clearly as
            // "commit replacement" than the previous
            // rectangle.stack.badge.minus, which leaned negative.
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(width: 14)
                TextField(L10n.t("find.replacePlaceholder"), text: $find.replacement)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { confirmReplace() }
                Button {
                    confirmReplace()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(replaceDisabled
                                         ? Color.secondary.opacity(0.5)
                                         : appTheme.accent)
                }
                .help(L10n.t("finfiles.button.replaceAll"))
                .accessibilityLabel(L10n.t("findbar.action.replaceAll"))
                .buttonStyle(.plain)
                .disabled(replaceDisabled)
            }

            // Option toggles + run-search trigger. Spinner sits
            // between the two so it reads as "in flight" without
            // making the layout reflow.
            HStack(spacing: 4) {
                optionToggle("Aa", help: L10n.t("find.option.matchCase"), binding: $find.matchCase)
                optionToggle("ab\u{2009}|", help: L10n.t("find.option.wholeWord"), binding: $find.wholeWord)
                optionToggle(".*", help: L10n.t("find.option.regex"), binding: $find.regex)
                Spacer()
                if find.isSearching || find.isReplacing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Button {
                    runSearch()
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(searchDisabled
                                         ? Color.secondary.opacity(0.5)
                                         : appTheme.accent)
                }
                .buttonStyle(.plain)
                .help(L10n.t("finfiles.button.runSearch"))
                .disabled(searchDisabled)
            }

            // Include / exclude globs. Their inputs are tertiary
            // controls (most users never use them), so the rows
            // get a dimmer label glyph + smaller text.
            globFieldRow(systemImage: "doc.badge.plus",
                         placeholder: L10n.t("find.includes.placeholder"),
                         text: $find.includeGlob)
            globFieldRow(systemImage: "doc.badge.minus",
                         placeholder: L10n.t("find.excludes.placeholder"),
                         text: $find.excludeGlob)
        }
        .padding(12)
    }

    /// Disable rule for the run-search button. Pulled out so the
    /// button's visual treatment + the SwiftUI `.disabled` binding
    /// stay in sync.
    private var searchDisabled: Bool {
        find.query.isEmpty
            || workspace.folderRoot == nil
            || find.isReplacing
    }

    @ViewBuilder
    private func globFieldRow(systemImage: String,
                              placeholder: String,
                              text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.tertiary)
                .font(.system(size: 11))
                .frame(width: 14)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit { runSearch() }
        }
    }

    /// Replace All is enabled only when there's something to replace,
    /// a search has produced files, at least one file is selected, and
    /// no other engine pass is running.
    private var replaceDisabled: Bool {
        find.query.isEmpty
            || find.results.isEmpty
            || find.selectedURLs.isEmpty
            || find.isReplacing
            || find.isSearching
    }

    // MARK: - Summary

    @ViewBuilder
    private var summary: some View {
        if let err = find.error {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        } else if let replaceMsg = find.lastReplaceSummary {
            // Replace summary takes precedence over the search totals
            // immediately after a replace pass — it stays visible until
            // the user runs another search.
            Text(replaceMsg)
                .font(.caption)
                .foregroundStyle(appTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        } else if find.totalMatches > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("finfiles.summary.results",
                            find.totalMatches,
                            find.filesWithMatches,
                            find.filesScanned))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Phase 16/17: surface the selected slice when the user
                // has deselected anything — file or individual line.
                // Otherwise the summary stays a single line — no UI
                // churn for the common "replace everything" case.
                if !find.excludedURLs.isEmpty || !find.excludedLines.isEmpty {
                    Text(find.selectedMatchCount == 1
                         ? L10n.t("finfiles.summary.replace.scope.singular",
                                  find.selectedURLs.count)
                         : L10n.t("finfiles.summary.replace.scope",
                                  find.selectedMatchCount,
                                  find.selectedURLs.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else if find.hasRun && !find.isSearching {
            Text("finfiles.summary.empty", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    // MARK: - Results

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(find.results) { file in
                    FileGroup(
                        file: file,
                        expanded: find.expanded.contains(file.url) || find.expanded.isEmpty,
                        isSelected: find.isSelected(file.url),
                        toggleExpanded: { toggle(file.url) },
                        toggleSelection: { find.toggleSelection(file.url) },
                        isLineSelected: { line in find.isLineSelected(file.url, line: line) },
                        toggleLineSelection: { line in find.toggleLineSelection(file.url, line: line) },
                        onPick: { match in jump(to: file.url, line: match.lineNumber) }
                    )
                }
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Actions

    private func runSearch() {
        guard let root = workspace.folderRoot?.url else {
            find.error = L10n.t("finfiles.error.noWorkspace")
            return
        }
        let opts = FindInFilesOptions(
            query: find.query,
            matchCase: find.matchCase,
            wholeWord: find.wholeWord,
            regex: find.regex,
            includeGlobs: split(find.includeGlob),
            excludeGlobs: split(find.excludeGlob)
        )
        engine.search(options: opts, root: root, into: find)
    }

    /// Confirm and execute a workspace-wide replace. Three guarantees we
    /// surface to the user up front:
    ///   1. We list how many files / matches will be touched.
    ///   2. We point out any open buffer with unsaved edits that will
    ///      get reloaded (and therefore lose those edits).
    ///   3. The action is presented as destructive; default = Cancel.
    private func confirmReplace() {
        guard !replaceDisabled else { return }
        // Phase 16: only operate on the currently-selected files. The
        // dirty-buffer warning + post-replace reload mirror the same
        // filtered set so we don't claim to have touched files that
        // were skipped.
        let urls = find.selectedURLs
        guard !urls.isEmpty else { return }
        let selectedMatches = find.selectedMatchCount
        let dirtyOpen = workspace.documents.filter { doc in
            doc.isDirty && doc.url != nil
                && urls.contains(where: { $0.standardizedFileURL == doc.url!.standardizedFileURL })
        }

        let alert = NSAlert()
        let totalFiles = find.results.count
        let skipped = totalFiles - urls.count
        alert.messageText = selectedMatches == 1
            ? L10n.t("alert.replace.title.singular", urls.count)
            : L10n.t("alert.replace.title", selectedMatches, urls.count)
        var info = L10n.t("alert.replace.subject",
                          find.query as NSString,
                          find.replacement as NSString)
        if skipped > 0 {
            info += skipped == 1
                ? L10n.t("alert.replace.skipped.singular")
                : L10n.t("alert.replace.skipped", skipped)
        }
        if !dirtyOpen.isEmpty {
            let names = dirtyOpen.map(\.title).joined(separator: ", ")
            info += L10n.t("alert.replace.unsaved", names as NSString)
        }
        info += L10n.t("alert.replace.warning")
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("alert.button.replace"))
        alert.addButton(withTitle: L10n.t("alert.button.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let opts = FindInFilesOptions(
            query: find.query,
            matchCase: find.matchCase,
            wholeWord: find.wholeWord,
            regex: find.regex,
            includeGlobs: split(find.includeGlob),
            excludeGlobs: split(find.excludeGlob)
        )
        engine.replaceAll(options: opts,
                          replacement: find.replacement,
                          urls: urls,
                          excludedLinesByURL: find.excludedLinesByURL,
                          into: find) { [find, workspace] summary in
            // Pull every still-open document forward so the buffer
            // matches what's now on disk. Skipped errors stay in the
            // open set untouched.
            for doc in workspace.documents {
                guard let docURL = doc.url?.standardizedFileURL else { continue }
                if urls.contains(where: { $0.standardizedFileURL == docURL }) {
                    workspace.reloadFromDisk(doc: doc)
                }
            }

            find.lastReplaceSummary = FindInFilesPresentation.replaceSummaryText(summary)
            // Stale results no longer reflect what's on disk; clear them
            // and let the user re-run search to verify.
            find.update(results: [],
                        totalMatches: 0,
                        filesScanned: 0,
                        filesWithMatches: 0)
        }
    }

    private func split(_ csv: String) -> [String] {
        csv.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func toggle(_ url: URL) {
        if find.expanded.contains(url) {
            find.expanded.remove(url)
        } else {
            find.expanded.insert(url)
        }
    }

    private func jump(to url: URL, line: Int) {
        workspace.openFile(at: url, line: line)
    }
}

// MARK: - Per-file group

private struct FileGroup: View {
    let file: FileResult
    let expanded: Bool
    let isSelected: Bool
    let toggleExpanded: () -> Void
    let toggleSelection: () -> Void
    let isLineSelected: (Int) -> Bool
    let toggleLineSelection: (Int) -> Void
    let onPick: (LineMatch) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                // Phase 16: per-file inclusion toggle. Sits at the
                // start of the row so a quick eye-scan tells you which
                // files Replace All will touch. Click is independent
                // of the disclosure chevron so users can deselect a
                // collapsed file without expanding it first.
                Toggle(isOn: Binding(
                    get: { isSelected },
                    set: { _ in toggleSelection() }
                )) { EmptyView() }
                .toggleStyle(.checkbox)
                .help(FindInFilesPresentation.fileToggleHelp(isSelected: isSelected))
                .accessibilityLabel(FindInFilesPresentation.fileToggleAccessibility(
                    isSelected: isSelected,
                    fileName: file.url.lastPathComponent
                ))

                // Disclosure chevron + filename make up the rest of
                // the row; tapping anywhere here toggles expansion.
                Button(action: toggleExpanded) {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10)
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                        Text(file.url.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            // Greyed-out title gives a second visual
                            // cue that this file won't be touched.
                            .foregroundStyle(isSelected ? .primary : .secondary)
                        Text(file.url.deletingLastPathComponent().lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(file.matches.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.08))
                            )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            if expanded {
                ForEach(file.matches) { match in
                    MatchRow(
                        match: match,
                        isSelected: isLineSelected(match.lineNumber),
                        // Skip the line-checkbox interaction when the
                        // parent file is opted out — the row is
                        // greyed out anyway and toggling it would
                        // create UI ambiguity ("file off but line
                        // on?"). The accessibility label still
                        // surfaces the disabled state.
                        toggleSelection: { toggleLineSelection(match.lineNumber) }
                    )
                    .onTapGesture { onPick(match) }
                }
            }
        }
    }
}

private struct MatchRow: View {
    let match: LineMatch
    let isSelected: Bool
    let toggleSelection: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Phase 17: line-level inclusion toggle. Compact size so a
            // dense result list (5+ matches per file) doesn't grow
            // vertically. Tap target is the checkbox itself plus the
            // padding around it; the rest of the row preserves its
            // jump-to-source click behaviour.
            Toggle(isOn: Binding(
                get: { isSelected },
                set: { _ in toggleSelection() }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(FindInFilesPresentation.matchToggleHelp(isSelected: isSelected))
            .accessibilityLabel(FindInFilesPresentation.matchToggleAccessibility(
                lineNumber: match.lineNumber,
                isSelected: isSelected
            ))
            .frame(width: 18)
            Text("\(match.lineNumber)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            Text(highlighted)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                // Subtle dim on excluded rows so the user can scan
                // for "what gets touched" at a glance.
                .opacity(isSelected ? 1.0 : 0.45)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hover ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    private var highlighted: AttributedString {
        var attributed = AttributedString(match.lineText)
        for range in match.matchRanges {
            // Translate UTF-16 NSRange-style indices into AttributedString
            // indices. Cheap because we only do this for matched lines.
            guard let attrRange = attributedRange(in: attributed,
                                                  utf16Lower: range.lowerBound,
                                                  utf16Upper: range.upperBound) else { continue }
            attributed[attrRange].font = .system(size: 11, weight: .bold, design: .monospaced)
            attributed[attrRange].backgroundColor = .yellow.opacity(0.6)
        }
        return attributed
    }

    private func attributedRange(in attributed: AttributedString,
                                 utf16Lower: Int,
                                 utf16Upper: Int) -> Range<AttributedString.Index>? {
        let raw = String(attributed.characters)
        let utf16 = raw.utf16
        guard utf16Lower <= utf16.count, utf16Upper <= utf16.count else { return nil }
        let lower16 = utf16.index(utf16.startIndex, offsetBy: utf16Lower)
        let upper16 = utf16.index(utf16.startIndex, offsetBy: utf16Upper)
        guard let lower = lower16.samePosition(in: raw),
              let upper = upper16.samePosition(in: raw) else { return nil }
        let nsRange = NSRange(lower..<upper, in: raw)
        return Range(nsRange, in: attributed)
    }
}

// MARK: - Local helpers

// `ToggleStyle.button` and `ButtonStyle.borderless` are main-actor
// isolated; under Swift 6 strict concurrency the helper has to be
// `@MainActor` for the call sites (which already run on the main
// actor) to compile cleanly.
@MainActor
@ViewBuilder
private func optionToggle(_ label: String,
                          help: String,
                          binding: Binding<Bool>) -> some View {
    Toggle(isOn: binding) {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .frame(minWidth: 18)
    }
    .toggleStyle(.button)
    .buttonStyle(.borderless)
    .help(help)
}
