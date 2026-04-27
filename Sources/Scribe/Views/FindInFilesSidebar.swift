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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputs
            Divider()
            summary
            Divider()
            results
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { queryFocused = true }
    }

    // MARK: - Inputs

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $find.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                    .font(.system(size: 12))
                    .onSubmit { runSearch() }
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.2.squarepath")
                    .foregroundStyle(.secondary)
                TextField("Replace", text: $find.replacement)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    // Enter in the replace field triggers Replace All.
                    .onSubmit { confirmReplace() }
                Button {
                    confirmReplace()
                } label: {
                    Image(systemName: "rectangle.stack.badge.minus")
                }
                .help("Replace all matches")
                .accessibilityLabel("Replace All")
                .buttonStyle(.borderless)
                .disabled(replaceDisabled)
            }

            HStack(spacing: 4) {
                optionToggle("Aa", help: "Match Case", binding: $find.matchCase)
                optionToggle("ab\u{2009}|", help: "Whole Word", binding: $find.wholeWord)
                optionToggle(".*", help: "Regular Expression", binding: $find.regex)
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
                }
                .buttonStyle(.borderless)
                .help("Run search (Enter)")
                .disabled(find.query.isEmpty || workspace.folderRoot == nil
                          || find.isReplacing)
            }

            HStack(spacing: 4) {
                Image(systemName: "doc.badge.plus")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                TextField("files to include", text: $find.includeGlob)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { runSearch() }
            }

            HStack(spacing: 4) {
                Image(systemName: "doc.badge.minus")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                TextField("files to exclude", text: $find.excludeGlob)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { runSearch() }
            }
        }
        .padding(10)
    }

    /// Replace All is enabled only when there's something to replace,
    /// a search has produced files, and no other engine pass is running.
    private var replaceDisabled: Bool {
        find.query.isEmpty
            || find.results.isEmpty
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
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        } else if find.totalMatches > 0 {
            Text("\(find.totalMatches) results in \(find.filesWithMatches) files (\(find.filesScanned) scanned)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        } else if find.hasRun && !find.isSearching {
            Text("No results.")
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
                        toggleExpanded: { toggle(file.url) },
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
            find.error = "Open a workspace folder first."
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
        let urls = find.results.map(\.url)
        let dirtyOpen = workspace.documents.filter { doc in
            doc.isDirty && doc.url != nil
                && urls.contains(where: { $0.standardizedFileURL == doc.url!.standardizedFileURL })
        }

        let alert = NSAlert()
        alert.messageText = "Replace \(find.totalMatches) match\(find.totalMatches == 1 ? "" : "es") in \(find.filesWithMatches) file\(find.filesWithMatches == 1 ? "" : "s")?"
        var info = "“\(find.query)” → “\(find.replacement)”."
        if !dirtyOpen.isEmpty {
            let names = dirtyOpen.map(\.title).joined(separator: ", ")
            info += "\n\nUnsaved changes in \(names) will be lost."
        }
        info += "\nThis cannot be undone from inside Scribe."
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Cancel")
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

            // Build a human-readable summary string. Errors append a
            // truncated "+ N more" tail when the list grows.
            var msg = "Replaced \(summary.totalReplacements) in \(summary.filesChanged)/\(summary.filesScanned) files."
            if !summary.errors.isEmpty {
                let head = summary.errors.prefix(2)
                    .map { "\($0.0.lastPathComponent): \($0.1)" }
                    .joined(separator: "; ")
                let tail = summary.errors.count > 2
                    ? " + \(summary.errors.count - 2) more"
                    : ""
                msg += " Errors: \(head)\(tail)."
            }
            find.lastReplaceSummary = msg
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
    let toggleExpanded: () -> Void
    let onPick: (LineMatch) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    Text(file.url.deletingLastPathComponent().lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(file.matches.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(file.matches) { match in
                    MatchRow(match: match)
                        .onTapGesture { onPick(match) }
                }
            }
        }
    }
}

private struct MatchRow: View {
    let match: LineMatch
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(match.lineNumber)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
            Text(highlighted)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(hover ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
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
