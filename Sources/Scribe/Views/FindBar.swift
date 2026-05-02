//
//  FindBar.swift
//  Phase 4 — the strip that drops in above the editor when ⌘F or ⌘R
//  fires. Pure UI: it reads + writes FindState and emits commands; the
//  Scintilla coordinator owns the actual search logic.
//

import SwiftUI

struct FindBar: View {
    @ObservedObject var state: FindState
    @Environment(\.appTheme) private var appTheme
    @FocusState private var queryFocused: Bool
    @FocusState private var replaceFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            findRow
            if state.isReplaceMode {
                Divider()
                replaceRow
            }
            Divider()
        }
        .background(appTheme.barBackground)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { queryFocused = true }
        .onChange(of: state.isVisible) { _, visible in
            if visible { queryFocused = true }
        }
        .onChange(of: state.isReplaceMode) { _, replace in
            // When the user toggles into Replace, keep the query field
            // focused; expanding to Replace All etc. is one Tab away.
            if replace { queryFocused = true }
        }
    }

    // MARK: - Rows

    private var findRow: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $state.isReplaceMode) {
                Image(systemName: state.isReplaceMode ? "chevron.down" : "chevron.right")
                    .foregroundStyle(appTheme.secondaryText)
                    .font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(L10n.t("findbar.toggleReplace"))

            historyMenu(
                history: state.queryHistory,
                empty: L10n.t("findbar.history.emptySearches"),
                onPick: { state.query = $0 },
                onClear: { state.clearHistory() }
            )

            TextField(L10n.t("findbar.placeholder.find"), text: $state.query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .font(.system(size: 12))
                .frame(maxWidth: 280)
                .onSubmit {
                    state.commitQueryToHistory()
                    state.commands.send(.findNext)
                }
                .onChange(of: state.debouncedQuery) { _, _ in
                    // Phase 45-D — live-search like VSCode: every
                    // *settled* keystroke (after a 150ms debounce on
                    // `query`) confirms the current hit (or moves to
                    // the next one) and refreshes the highlight
                    // overlay. The TextField stays bound to `query`
                    // so the field itself still echoes input
                    // instantly; only the heavy scan / caret-jump
                    // path waits for the burst to settle.
                    state.commands.send(.findCurrent)
                }
                .onChange(of: state.matchCase) { _, _ in
                    state.commands.send(.findCurrent)
                }
                .onChange(of: state.wholeWord) { _, _ in
                    state.commands.send(.findCurrent)
                }
                .onChange(of: state.regex) { _, _ in
                    state.commands.send(.findCurrent)
                }
                .onKeyPress(.escape) {
                    state.hide()
                    return .handled
                }

            optionToggle(
                "Aa",
                help: L10n.t("find.option.matchCase") + FindOptionShortcuts.helpSuffix(for: .matchCase),
                binding: $state.matchCase
            )
            .findOptionShortcut(for: .matchCase)
            optionToggle(
                "ab\u{2009}|",
                help: L10n.t("find.option.wholeWord") + FindOptionShortcuts.helpSuffix(for: .wholeWord),
                binding: $state.wholeWord
            )
            .findOptionShortcut(for: .wholeWord)
            optionToggle(
                ".*",
                help: L10n.t("find.option.regex") + FindOptionShortcuts.helpSuffix(for: .regex),
                binding: $state.regex
            )
            .findOptionShortcut(for: .regex)

            // Spacer first so the status sticks to the right next to
            // the navigation buttons, like Xcode / VSCode.
            Spacer(minLength: 4)

            statusLabel
                .fixedSize(horizontal: true, vertical: false)

            // Navigation buttons
            Button {
                state.commands.send(.findPrev)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help(L10n.t("findbar.action.previous") + " (⇧⌘G)")

            Button {
                state.commands.send(.findNext)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("g", modifiers: .command)
            .help(L10n.t("findbar.action.next") + " (⌘G)")

            CloseButton(action: state.hide)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            // Spacer to align under the disclosure toggle in findRow.
            Color.clear.frame(width: 22)

            historyMenu(
                history: state.replacementHistory,
                empty: L10n.t("findbar.history.emptyReplacements"),
                onPick: { state.replacement = $0 },
                onClear: { state.replacementHistory = [] }
            )

            TextField(L10n.t("findbar.placeholder.replace"), text: $state.replacement)
                .textFieldStyle(.roundedBorder)
                .focused($replaceFocused)
                .font(.system(size: 12))
                .frame(maxWidth: 280)
                .onSubmit {
                    state.commitQueryToHistory()
                    state.commitReplacementToHistory()
                    state.commands.send(.replaceCurrent)
                }

            Button {
                state.commitQueryToHistory()
                state.commitReplacementToHistory()
                state.commands.send(.replaceCurrent)
            } label: {
                Text("findbar.action.replace", bundle: .module)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.query.isEmpty)

            Button {
                state.commitQueryToHistory()
                state.commitReplacementToHistory()
                state.commands.send(.replaceAll)
            } label: {
                Text("findbar.action.replaceAll", bundle: .module)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.query.isEmpty)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - History menu

    @ViewBuilder
    private func historyMenu(history: [String],
                             empty: String,
                             onPick: @escaping (String) -> Void,
                             onClear: @escaping () -> Void) -> some View {
        Menu {
            if history.isEmpty {
                Text(empty).foregroundStyle(appTheme.secondaryText)
            } else {
                ForEach(history, id: \.self) { item in
                    Button(item) { onPick(item) }
                }
                Divider()
                Button(role: .destructive) {
                    onClear()
                } label: { Text("findbar.clearHistory", bundle: .module) }
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(appTheme.secondaryText)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .help(L10n.t("findbar.history"))
    }

    // MARK: - Pieces

    @ViewBuilder
    private func optionToggle(_ label: String, help: String, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(minWidth: 18)
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .help(help)
    }

    /// Compact circular close button with an explicit hover ring.
    /// SF Symbol `xmark.circle.fill` alone has no hover affordance,
    /// so we draw the fill ourselves and react to hover.
    private struct CloseButton: View {
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hover ? Color.primary : Color.secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(hover ? Color.primary.opacity(0.10) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(L10n.t("findbar.action.close") + " (Esc)")
        }
    }

    private var statusLabel: some View {
        // Always render a Text so SwiftUI doesn't tear the row down when
        // the bar transitions between "no query / no matches / counted".
        let text = FindBarPresentation.statusText(status: state.status,
                                                  currentMatch: state.currentMatch,
                                                  matchCount: state.matchCount,
                                                  query: state.query)
        return Text(text)
            .font(.system(size: 11))
            .foregroundStyle(appTheme.secondaryText)
            .monospacedDigit()
    }
}
