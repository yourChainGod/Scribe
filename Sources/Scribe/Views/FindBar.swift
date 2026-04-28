//
//  FindBar.swift
//  Phase 4 — the strip that drops in above the editor when ⌘F or ⌘R
//  fires. Pure UI: it reads + writes FindState and emits commands; the
//  Scintilla coordinator owns the actual search logic.
//

import SwiftUI

struct FindBar: View {
    @ObservedObject var state: FindState
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
        .background(.bar)
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
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Toggle Replace")

            historyMenu(
                history: state.queryHistory,
                empty: "No recent searches",
                onPick: { state.query = $0 },
                onClear: { state.clearHistory() }
            )

            TextField("Find", text: $state.query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .font(.system(size: 12))
                .frame(maxWidth: 280)
                .onSubmit {
                    state.commitQueryToHistory()
                    state.commands.send(.findNext)
                }
                .onChange(of: state.query) { _, _ in
                    // Live-search like VSCode: every keystroke confirms
                    // the current hit (or moves to the next one) and
                    // refreshes the highlight overlay.
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

            optionToggle("Aa", help: "Match Case", binding: $state.matchCase)
            optionToggle("ab\u{2009}|", help: "Whole Word", binding: $state.wholeWord)
            optionToggle(".*", help: "Regular Expression", binding: $state.regex)

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
            .help("Find Previous (⇧⌘G)")

            Button {
                state.commands.send(.findNext)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("g", modifiers: .command)
            .help("Find Next (⌘G)")

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
                empty: "No recent replacements",
                onPick: { state.replacement = $0 },
                onClear: { state.replacementHistory = [] }
            )

            TextField("Replace", text: $state.replacement)
                .textFieldStyle(.roundedBorder)
                .focused($replaceFocused)
                .font(.system(size: 12))
                .frame(maxWidth: 280)
                .onSubmit {
                    state.commitQueryToHistory()
                    state.commitReplacementToHistory()
                    state.commands.send(.replaceCurrent)
                }

            Button("Replace") {
                state.commitQueryToHistory()
                state.commitReplacementToHistory()
                state.commands.send(.replaceCurrent)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.query.isEmpty)

            Button("Replace All") {
                state.commitQueryToHistory()
                state.commitReplacementToHistory()
                state.commands.send(.replaceAll)
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
                Text(empty).foregroundStyle(.secondary)
            } else {
                ForEach(history, id: \.self) { item in
                    Button(item) { onPick(item) }
                }
                Divider()
                Button("Clear History", role: .destructive) { onClear() }
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .help("Recent — click to reuse")
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
            .help("Close (Esc)")
        }
    }

    private var statusLabel: some View {
        // Always render a Text so SwiftUI doesn't tear the row down when
        // the bar transitions between "no query / no matches / counted".
        let text: String
        if !state.status.isEmpty {
            text = state.status
        } else if state.matchCount > 0 {
            text = "\(state.currentMatch) of \(state.matchCount)"
        } else if !state.query.isEmpty {
            text = "0 results"
        } else {
            text = ""
        }
        return Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}
