//
//  OutlineSidebar.swift
//  Phase 7 — sidebar tab #3: symbol outline of the active document.
//  Click a row → editor scrolls to that line via Document.pendingScrollLine,
//  the same hook Find-in-Files uses for jump-to-match.
//

import SwiftUI

struct OutlineSidebar: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var outline: SymbolOutline
    @Environment(\.appTheme) private var appTheme

    /// Phase 50a — substring filter for the visible symbol list. Lives
    /// on the view (not on `SymbolOutline`) because it's a per-sidebar
    /// UI state, not part of the parsed outline model — switching
    /// documents shouldn't clobber a query the user typed elsewhere,
    /// but it shouldn't survive a sidebar tab switch either, which is
    /// exactly what `@State` gives us.
    @State private var filterQuery: String = ""

    /// Symbol whose line range contains the editor caret. Drives the
    /// "you are here" highlight in OutlineRow. Cheapest sufficient
    /// algorithm: linear scan; symbol counts in real files top out
    /// in low hundreds, well below the threshold where this matters.
    private var activeSymbolID: SymbolEntry.ID? {
        guard let doc = workspace.current else { return nil }
        let line = doc.cursorLine
        // Pick the deepest symbol whose start ≤ caret. Tie-break by
        // line so a symbol declared on the same line as the caret
        // takes precedence over the file's enclosing scope.
        return outline.symbols
            .filter { $0.lineNumber <= line }
            .max(by: { $0.lineNumber < $1.lineNumber })?
            .id
    }

    /// Symbols rendered after the filter. The active-highlight still
    /// reads from the unfiltered list so a row that scrolled out of
    /// the filtered view doesn't fight with the caret indicator.
    private var visibleSymbols: [SymbolEntry] {
        Self.filterSymbols(outline.symbols, by: filterQuery)
    }

    private var trimmedQuery: String {
        filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if shouldShowFilterField {
                filterRow
                Divider()
            }
            content
        }
        .background(appTheme.sidebarBackground)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text("sidebar.outline.header", bundle: .module)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if outline.isParsing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
            Spacer()
            if !outline.symbols.isEmpty {
                Text(symbolCountLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Capsule shows the live "matched / total" pair while a filter
    /// is active so the user can tell at a glance how aggressive the
    /// filter is. Falls back to a plain count when no query is set.
    private var symbolCountLabel: String {
        if trimmedQuery.isEmpty {
            return "\(outline.symbols.count)"
        }
        return "\(visibleSymbols.count)/\(outline.symbols.count)"
    }

    private var shouldShowFilterField: Bool {
        // Only render the field when there's something to filter; an
        // empty outline doesn't need the visual chrome.
        !outline.symbols.isEmpty
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 10))
            TextField(L10n.t("sidebar.outline.filter.placeholder"),
                      text: $filterQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !filterQuery.isEmpty {
                Button {
                    filterQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("button.clear", bundle: .module))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if workspace.current == nil {
            placeholder(L10n.t("sidebar.outline.noDocument"))
        } else if outline.symbols.isEmpty && !outline.isParsing {
            placeholder(L10n.t("sidebar.outline.empty"))
        } else if visibleSymbols.isEmpty && !trimmedQuery.isEmpty {
            placeholder(Self.format("sidebar.outline.filter.empty",
                                    trimmedQuery))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleSymbols) { sym in
                        OutlineRow(symbol: sym, isActive: sym.id == activeSymbolID)
                            .onTapGesture { jump(to: sym) }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer(minLength: 24)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            Spacer()
        }
    }

    // MARK: - Actions

    /// Re-uses Document.pendingScroll — the hook
    /// ScintillaCodeEditor reads inside makeNSView/updateNSView to
    /// reposition the caret + scroll. No bespoke wiring needed.
    private func jump(to symbol: SymbolEntry) {
        guard let doc = workspace.current else { return }
        doc.pendingScroll = PendingScrollTarget(line: symbol.lineNumber)
    }

    // MARK: - Pure helpers

    /// Phase 50a — substring + case-insensitive filter. Empty /
    /// whitespace-only queries pass everything through; otherwise we
    /// match against `symbol.name` only. Kind labels and line numbers
    /// aren't searchable on purpose — tossing them into the haystack
    /// would surface noise like "method" matching every Swift
    /// function. Exposed as a `static` so XCTest can assert the
    /// filter contract without standing up a SwiftUI body.
    static func filterSymbols(_ symbols: [SymbolEntry],
                              by query: String) -> [SymbolEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return symbols }
        let needle = trimmed.lowercased()
        return symbols.filter { $0.name.lowercased().contains(needle) }
    }

    private static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: L10n.t(key), arguments: args)
    }
}

private struct OutlineRow: View {
    let symbol: SymbolEntry
    let isActive: Bool
    @Environment(\.appTheme) private var appTheme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            // Markdown headings indent by depth so the H1/H2/H3
            // hierarchy shows. Other languages stay at depth 0 → no
            // indent for now.
            if symbol.depth > 0 {
                Spacer().frame(width: CGFloat(symbol.depth * 12))
            }
            Image(systemName: symbol.kind.icon)
                .foregroundStyle(symbol.kind.tint)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(symbol.name)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text("\(symbol.lineNumber)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(backgroundFill)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.18), value: isActive)
    }

    private var backgroundFill: Color {
        if isActive {
            // Caret-is-here highlight. Same accent 14% pill the
            // sidebar mode switcher uses, keeping the visual
            // language consistent across the sidebar.
            return appTheme.accent.opacity(0.14)
        } else if hover {
            return Color.primary.opacity(0.06)
        } else {
            return Color.clear
        }
    }
}
