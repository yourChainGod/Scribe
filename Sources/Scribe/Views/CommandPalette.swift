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

enum CommandPaletteMetrics {
    static let width: CGFloat = 560
    static let maxListHeight: CGFloat = 208
    static let rowIconBox: CGFloat = 20
    static let rowIconSize: CGFloat = 12
    static let rowMinHeight: CGFloat = 34
    static let cornerRadius: CGFloat = 10
}

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
    @Environment(\.appTheme) private var appTheme

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

    /// Phase 46d — flat ranked result list used by keyboard navigation
    /// and the pick action. `sections` below is the grouped view onto
    /// the exact same matches (it just splits them by category).
    private var matches: [CommandMatch] {
        sections.flatMap(\.matches)
    }

    /// Phase 46d — grouped view. Empty query ⇒ category sections;
    /// non-empty query ⇒ a single anonymous section so the flat fuzzy
    /// ranking still reads as one list. Prefix routes (`@`, `:`, `>`)
    /// also collapse to a single section because their result space
    /// is already scoped.
    private var sections: [CommandSection] {
        registry.grouped(for: query)
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
        case "atSymbol":       return "number"
        case "gotoLine":       return "arrow.right.to.line"
        case "commandPalette": return "command"
        default:               return "magnifyingglass"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field — slightly taller than the macOS default
            // so the palette feels like a focused command surface
            // rather than a sidebar input.
            HStack(spacing: 10) {
                Image(systemName: routeIcon)
                    .foregroundStyle(appTheme.secondaryText)
                    .font(.system(size: 14))
                    .frame(width: 18)
                    .animation(.easeOut(duration: 0.15), value: routeIcon)
                TextField(effectivePlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
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
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(appTheme.secondaryText.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("palette.action.close"))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(appTheme.panelBackground.opacity(0.92))

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
                                .foregroundStyle(appTheme.secondaryText)
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
                            // Phase 46d — pre-compute each section's
                            // starting flat index so the `selection`
                            // key (which indexes into the flat match
                            // list) stays in lockstep with the rows
                            // we actually draw. Doing this upfront
                            // keeps the ForEach bodies pure (no
                            // mutating captures — SwiftUI's ViewBuilder
                            // rejects those).
                            let sectionsSnapshot = sections
                            let sectionOffsets = Self.flatOffsets(for: sectionsSnapshot)
                            ForEach(Array(sectionsSnapshot.enumerated()),
                                    id: \.element.id) { sIdx, section in
                                // Only draw a header when the section
                                // has a non-empty title — non-empty-
                                // query + prefix-route modes return a
                                // single anonymous section so we skip
                                // the visual split there.
                                if !section.title.isEmpty {
                                    Text(section.title.uppercased())
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(appTheme.secondaryText.opacity(0.9))
                                        .tracking(0.6)
                                        .padding(.horizontal, 18)
                                        .padding(.top, sIdx == 0 ? 8 : 10)
                                        .padding(.bottom, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                let base = sectionOffsets[sIdx]
                                ForEach(Array(section.matches.enumerated()),
                                        id: \.element.id) { mIdx, match in
                                    let idx = base + mIdx
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
                }
                .frame(maxHeight: CommandPaletteMetrics.maxListHeight)
                .onChange(of: selection) { _, new in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
        .frame(width: CommandPaletteMetrics.width)
        .background(appTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: CommandPaletteMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CommandPaletteMetrics.cornerRadius, style: .continuous)
                .stroke(appTheme.separator.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
        .onAppear { queryFocused = true }
    }

    private func invokeSelected() {
        guard matches.indices.contains(selection) else { return }
        onPick(matches[selection].command)
    }

    /// Phase 46d — given a list of sections, produce the prefix-sum
    /// table mapping `sectionIndex → flatIdx of its first match`.
    /// Used by the ForEach body to compute each row's flat index
    /// without a mutating captured counter (SwiftUI's ViewBuilder
    /// forbids those; pre-computing is the standard workaround).
    private static func flatOffsets(for sections: [CommandSection]) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(sections.count)
        var running = 0
        for section in sections {
            offsets.append(running)
            running += section.matches.count
        }
        return offsets
    }
}

// MARK: - Row

private struct CommandRow: View {
    let match: CommandMatch
    let isSelected: Bool
    @Environment(\.appTheme) private var appTheme

    private var presentation: CommandPresentation {
        CommandPresentation(command: match.command)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: presentation.iconName)
                .font(.system(size: CommandPaletteMetrics.rowIconSize, weight: .semibold))
                .foregroundStyle(isSelected ? appTheme.accent : appTheme.secondaryText)
                .frame(width: CommandPaletteMetrics.rowIconBox, height: CommandPaletteMetrics.rowIconBox)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected
                              ? appTheme.accent.opacity(0.16)
                              : Color.primary.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 2) {
                highlightedTitle
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.9))
                    .lineLimit(1)
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(appTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let badge = presentation.badge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(appTheme.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(isSelected ? 0.08 : 0.05))
                    )
            }
            // Phase 46e — shortcut chip. Monospaced mini pill at
            // the trailing edge so users can rehearse key bindings
            // inside the palette. Shows only when the command
            // declares a `shortcutLabel`; otherwise the row stays
            // quiet.
            if let shortcut = match.command.shortcutLabel {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(appTheme.secondaryText.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(isSelected ? 0.10 : 0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(appTheme.separator.opacity(0.4), lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(minHeight: CommandPaletteMetrics.rowMinHeight)
        .background(
            // Use a borderless rounded fill rather than a sharp
            // rectangle so the selection indicator doesn't fight
            // the rounded outer container. The 14% opacity matches
            // every other "active" state in the app's chrome
            // (sidebar mode pill, file tree active row).
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? appTheme.accent.opacity(0.14) : Color.clear)
                .padding(.horizontal, 7)
        )
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Title with the matched-char ranges drawn bold.
    private var highlightedTitle: Text {
        Text(buildAttributedTitle())
    }

    private func buildAttributedTitle() -> AttributedString {
        var attributed = AttributedString(presentation.title)
        guard match.command.title == presentation.title,
              let ranges = match.highlightedRanges,
              !ranges.isEmpty else {
            return attributed
        }
        for range in ranges {
            if let attrRange = Range(range, in: attributed) {
                attributed[attrRange].font = .system(size: 13, weight: .bold)
                attributed[attrRange].foregroundColor = appTheme.accent
            }
        }
        return attributed
    }

    private var accessibilityLabel: String {
        [
            presentation.title,
            presentation.detail,
            presentation.badge,
            // Phase 46e — append the shortcut so VoiceOver reads the
            // key binding after the title. Keeps blind users on the
            // same cognitive path as sighted users who see the chip.
            match.command.shortcutLabel
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}
