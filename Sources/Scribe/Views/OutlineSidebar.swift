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
    /// UI state, not part of the parsed outline model.
    ///
    /// Bug 3 fix — earlier the field deliberately survived document
    /// switches; in practice a query like "load" typed against doc A
    /// would carry over to doc B, where matching nothing made the
    /// outline look empty even when doc B was full of symbols. Users
    /// read this as "the new file has no outline" rather than
    /// "I'm still filtering". Clearing on doc-switch matches what
    /// VS Code, Xcode, and JetBrains all do.
    @State private var filterQuery: String = ""

    /// Last document id this view rendered against. Drives the
    /// "clear filter on doc switch" rule below. `@State` so SwiftUI
    /// keeps it across body recompositions.
    @State private var filterDocID: UUID?

    /// Symbol whose line range contains the editor caret. Drives the
    /// "you are here" highlight in OutlineRow. Cheapest sufficient
    /// algorithm: linear scan; symbol counts in real files top out
    /// in low hundreds, well below the threshold where this matters.
    private var activeSymbolID: SymbolEntry.ID? {
        guard let doc = workspace.current else { return nil }
        let line = doc.viewport.cursorLine
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
        .onChange(of: workspace.current?.id) { _, newID in
            // Bug 3 fix — clear the filter when the user moves to a
            // different document. First-render and "doc closed → nil"
            // intentionally don't clear (helper returns false) so a
            // freshly-opened sidebar with no doc bound doesn't drop
            // anything that wasn't there.
            if Self.shouldClearFilter(currentDocID: newID,
                                      lastDocID: filterDocID) {
                filterQuery = ""
            }
            filterDocID = newID
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .foregroundStyle(appTheme.secondaryText)
                .font(.system(size: 11))
            Text("sidebar.outline.header", bundle: .module)
                .font(.caption.weight(.semibold))
                .foregroundStyle(appTheme.secondaryText)
            if outline.isParsing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
            Spacer()
            if !outline.symbols.isEmpty {
                Text(symbolCountLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(appTheme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(appTheme.chromeSubtleFill)
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
                .foregroundStyle(appTheme.secondaryText)
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
                        .foregroundStyle(appTheme.secondaryText)
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
            // Phase 50c — auto-reveal the active symbol whenever the
            // caret crosses into a new row. Wrapping the ScrollView in
            // a ScrollViewReader gives us `.scrollTo` for free, and
            // ForEach's `Identifiable` rows act as the anchor targets
            // — no extra `.id(_:)` modifier needed.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleSymbols) { sym in
                            OutlineRow(symbol: sym, isActive: sym.id == activeSymbolID)
                                .onTapGesture { jump(to: sym) }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .onChange(of: activeSymbolID) { _, newID in
                    revealActive(newID, using: proxy)
                }
                // Outline gets re-parsed on every text edit; use this
                // to also reveal the active row right after a fresh
                // parse so a newly-loaded document doesn't open with
                // the active row scrolled off-screen.
                .onChange(of: outline.symbols.count) { _, _ in
                    revealActive(activeSymbolID, using: proxy)
                }
            }
        }
    }

    /// Scrolls the outline so the active row sits in a sensible
    /// anchor position. Pulled out of the `.onChange` body so the
    /// callback stays one-liner short and the animation stays
    /// consistent across both triggers.
    private func revealActive(_ id: SymbolEntry.ID?,
                              using proxy: ScrollViewProxy) {
        guard let id else { return }
        let anchor = Self.scrollAnchor(forActive: id,
                                       in: outline.symbols)
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer(minLength: 24)
            Text(text)
                .font(.caption)
                .foregroundStyle(appTheme.secondaryText)
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

    /// Bug 3 — decide whether a document-switch should wipe the
    /// outline filter query. Same id (re-render) ⇒ keep the query.
    /// First binding (`lastDocID == nil`) ⇒ keep, since there's
    /// nothing to "switch from". Doc closed (`currentDocID == nil`
    /// while we had one) ⇒ keep — the filter field hides anyway in
    /// the no-doc placeholder, and the user's text is still there
    /// when they reopen something. Only a true A→B move clears.
    /// Pure helper so XCTest can lock in the rule without standing
    /// up the full sidebar view.
    static func shouldClearFilter(currentDocID: UUID?,
                                  lastDocID: UUID?) -> Bool {
        guard let lastDocID, let currentDocID else { return false }
        return currentDocID != lastDocID
    }

    /// Phase 50c — choose a scroll anchor for the active row. Edge
    /// rows pin to the matching edge so the row doesn't slam into a
    /// half-cropped position; everything else centres so the user
    /// gets equal context above and below the symbol they're in.
    /// Pure helper so the contract is exercised by XCTest without
    /// instantiating SwiftUI scroll views.
    static func scrollAnchor(forActive id: SymbolEntry.ID,
                             in symbols: [SymbolEntry]) -> UnitPoint {
        guard let idx = symbols.firstIndex(where: { $0.id == id }) else {
            return .center
        }
        if idx == 0 { return .top }
        if idx == symbols.count - 1 { return .bottom }
        return .center
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
                .foregroundStyle(isActive ? appTheme.primaryText : appTheme.primaryText.opacity(0.85))
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
            return appTheme.chromeHoverFill
        } else {
            return Color.clear
        }
    }
}
