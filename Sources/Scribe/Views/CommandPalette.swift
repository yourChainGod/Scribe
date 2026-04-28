//
//  CommandPalette.swift
//  Phase 3 — VSCode-style command palette. Hosted in a borderless
//  NSPanel (see PaletteWindowController) so it can float above the main
//  window without being tied to the SwiftUI scene graph.
//
//  Keys:
//    Esc          dismiss
//    Enter        invoke selected command
//    ↑ / ↓        navigate
//
//  The view itself holds no business logic — `onPick` and `onCancel`
//  are wired by the controller.
//

import SwiftUI

struct CommandPalette: View {
    @ObservedObject var registry: CommandRegistry
    var placeholder: String = L10n.t("palette.placeholder.commands")
    /// Pre-fill the search field. Used by automated tests to drive the
    /// panel without simulating keystrokes; production callers leave
    /// it empty.
    var initialQuery: String = ""
    let onPick: (ScribeCommand) -> Void
    let onCancel: () -> Void

    @State private var query: String
    @State private var selection: Int = 0
    @FocusState private var queryFocused: Bool

    init(registry: CommandRegistry,
         placeholder: String = L10n.t("palette.placeholder.commands"),
         initialQuery: String = "",
         onPick: @escaping (ScribeCommand) -> Void,
         onCancel: @escaping () -> Void) {
        self.registry = registry
        self.placeholder = placeholder
        self.initialQuery = initialQuery
        self.onPick = onPick
        self.onCancel = onCancel
        // Initialize @State directly so the very first body evaluation
        // already sees the seeded query — avoids a flicker where the
        // user briefly sees the empty-query result list before
        // .onAppear kicks in.
        _query = State(initialValue: initialQuery)
    }

    private var matches: [CommandMatch] {
        registry.search(query)
    }

    /// Placeholder text for the search field. Falls back to the
    /// caller-supplied `placeholder` when no prefix route matches the
    /// current query. When a route IS active (e.g. user typed `@`),
    /// surface the route's own placeholder so the UI signals what kind
    /// of result is being filtered.
    private var effectivePlaceholder: String {
        registry.activeRoute(for: query)?.placeholder ?? placeholder
    }

    /// Glyph in the leading slot of the search bar. Reflects the
    /// active prefix-route so users get a visual cue when they've
    /// pivoted from "type to filter all commands" to "@symbol",
    /// ":line", etc. Falls back to magnifyingglass when no route
    /// matches.
    private var routeIcon: String {
        switch registry.activeRoute(for: query)?.id {
        case "symbol":  return "number"
        case "line":    return "arrow.right.to.line"
        case "command": return "command"
        default:        return "magnifyingglass"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field — slightly taller than the macOS default
            // so the palette feels like a focused command surface
            // rather than a sidebar input.
            HStack(spacing: 10) {
                Image(systemName: routeIcon)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 15))
                    .frame(width: 18)
                    .animation(.easeOut(duration: 0.15), value: routeIcon)
                TextField(effectivePlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($queryFocused)
                    .onSubmit { invokeSelected() }
                    .onKeyPress(.upArrow) {
                        selection = max(0, selection - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        selection = min(matches.count - 1, selection + 1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        onCancel()
                        return .handled
                    }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Result list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if matches.isEmpty {
                            Text(query.isEmpty
                                 ? L10n.t("palette.empty.noCommands")
                                 : String(format: L10n.t("palette.empty.noMatches"), query as NSString))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                        } else {
                            // Force the LazyVStack to reset its row
                            // identities whenever a prefix-route mode
                            // toggles. Without this, switching from the
                            // file picker to "@symbol" mode reuses the
                            // first cell and renders a stale "● file"
                            // row even though `matches` no longer
                            // contains it. The `routeID` part of the key
                            // changes only when the active route does,
                            // so plain typing inside one mode doesn't
                            // pay any tear-down cost.
                            let routeID = registry.activeRoute(for: query)?.id ?? "default"
                            ForEach(Array(matches.enumerated()), id: \.element.id) { idx, match in
                                CommandRow(
                                    match: match,
                                    isSelected: idx == selection
                                )
                                .id("\(routeID)#\(idx)")
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = idx
                                    invokeSelected()
                                }
                                .onHover { hovering in
                                    if hovering { selection = idx }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: selection) { _, new in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .onAppear { queryFocused = true }
    }

    private func invokeSelected() {
        guard matches.indices.contains(selection) else { return }
        onPick(matches[selection].command)
    }
}

// MARK: - Row

private struct CommandRow: View {
    let match: CommandMatch
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                highlightedTitle
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.9))
                    .lineLimit(1)
                if let subtitle = match.command.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            // Use a borderless rounded fill rather than a sharp
            // rectangle so the selection indicator doesn't fight
            // the rounded outer container. The 14% opacity matches
            // every other "active" state in the app's chrome
            // (sidebar mode pill, file tree active row).
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                .padding(.horizontal, 6)
        )
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    /// Title with the matched-char ranges drawn bold.
    private var highlightedTitle: Text {
        Text(buildAttributedTitle())
    }

    private func buildAttributedTitle() -> AttributedString {
        var attributed = AttributedString(match.command.title)
        guard let ranges = match.highlightedRanges, !ranges.isEmpty else {
            return attributed
        }
        for range in ranges {
            if let attrRange = Range(range, in: attributed) {
                attributed[attrRange].font = .system(size: 13, weight: .bold)
                attributed[attrRange].foregroundColor = .accentColor
            }
        }
        return attributed
    }
}
