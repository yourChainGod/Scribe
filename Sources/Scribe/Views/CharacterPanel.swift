//
//  CharacterPanel.swift
//  Phase 59 — Notepad++-style special-character picker. A sheet with
//  a search box and a LazyVGrid per CharacterCatalog bucket; tap /
//  Return inserts the glyph at every active caret via the existing
//  `.insertSnippet` command, picking up multi-cursor support for
//  free (Phase 20).
//
//  Why a sheet and not a menu extra / floating panel:
//    The catalog is large (~150 entries) and benefits from the
//    search field + scroll + grid layout a full sheet affords. A
//    floating palette like ClipboardHistoryController would force
//    us to reinvent the grid inside a tiny pop-up; the sheet reuses
//    SwiftUI's native layout primitives.
//

import SwiftUI

struct CharacterPanelSheet: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var findState: FindState

    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 520, idealWidth: 560,
               minHeight: 420, idealHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("character.panel.title", bundle: .module)
                .font(.headline)
            Spacer()
            TextField(L10n.t("character.panel.search.placeholder"),
                      text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Button {
                dismiss()
            } label: {
                Text("common.close", bundle: .module)
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let filtered = CharacterCatalog.filter(query)
        if filtered.isEmpty {
            // Empty-state: search produced zero hits. Keep the
            // sheet usable by offering an obvious recovery ("Clear
            // filter") instead of a dead panel.
            VStack(spacing: 12) {
                Spacer()
                Text("character.panel.empty", bundle: .module)
                    .foregroundStyle(appTheme.secondaryText)
                Button {
                    query = ""
                } label: {
                    Text("character.panel.clearSearch", bundle: .module)
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(filtered, id: \.id) { category in
                        CharacterPanelSection(category: category) { ch in
                            insert(ch)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    /// Insert `ch` at every active caret. The editor's Coordinator
    /// picks it up from the `.insertSnippet(_:)` route, which
    /// already drives multi-cursor insertion (Phase 20) and the
    /// read-only guard (Phase 54) for free.
    private func insert(_ ch: SpecialCharacter) {
        findState.commands.send(.insertSnippet(ch.value))
    }
}

// MARK: - Section

private struct CharacterPanelSection: View {
    @Environment(\.appTheme) private var appTheme
    let category: CharacterCategory
    let onTap: (SpecialCharacter) -> Void

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.titleKey.localizedFromBundle())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appTheme.secondaryText)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(category.characters) { ch in
                    CharacterTile(character: ch, onTap: onTap)
                }
            }
        }
    }
}

// MARK: - Tile

private struct CharacterTile: View {
    @Environment(\.appTheme) private var appTheme
    let character: SpecialCharacter
    let onTap: (SpecialCharacter) -> Void
    @State private var hovered = false

    var body: some View {
        Button {
            onTap(character)
        } label: {
            Text(character.value)
                .font(.system(size: 22))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovered
                              ? Color.accentColor.opacity(0.18)
                              : appTheme.chromeSubtleFill)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(character.name)
        .accessibilityLabel(character.name)
    }
}

// MARK: - Localized key helper

private extension String {
    /// `Text(titleKey, bundle: .module)` is the standard
    /// Localizable.strings path, but we render section titles
    /// directly (not inside a `Text`-only view), so route
    /// through `L10n.t` to pick up the module bundle lookup.
    func localizedFromBundle() -> String {
        L10n.t(self)
    }
}
