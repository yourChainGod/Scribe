//
//  CrashRecoverySheet.swift
//  Phase 69 — sheet UI for the crash-recovery prompt. Lists every
//  scratch entry left behind by the previous session, lets the
//  user tick which to restore, and surfaces a warning chip when
//  the original file changed externally between the snapshot and
//  now.
//

import SwiftUI

struct CrashRecoverySheet: View {
    let prompt: CrashRecoveryPrompt
    let onRestore: (Set<UUID>) -> Void
    let onDiscard: () -> Void

    @Environment(\.appTheme) private var appTheme
    @State private var selectedIDs: Set<UUID>

    init(prompt: CrashRecoveryPrompt,
         onRestore: @escaping (Set<UUID>) -> Void,
         onDiscard: @escaping () -> Void) {
        self.prompt = prompt
        self.onRestore = onRestore
        self.onDiscard = onDiscard
        // Default: every entry ticked. Users who want to drop a
        // specific row uncheck it; users who want everything just
        // hit Enter.
        _selectedIDs = State(initialValue: Set(prompt.items.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            entriesList
            Divider()
            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 540, height: 460)
        .background(appTheme.windowBackground)
        .interactiveDismissDisabled()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(appTheme.accent)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 6) {
                Text("crashRecovery.title", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(appTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("crashRecovery.body", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(appTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Entries list

    private var entriesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: toggleSelectAll) {
                    Text(allSelected
                         ? "crashRecovery.deselectAll"
                         : "crashRecovery.selectAll", bundle: .module)
                        .font(.system(size: 12))
                }
                .buttonStyle(.link)
                Spacer()
                Text(L10n.t("crashRecovery.selectionCount",
                            "\(selectedIDs.count)" as NSString,
                            "\(prompt.items.count)" as NSString))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(appTheme.secondaryText)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(prompt.items) { item in
                        CrashRecoveryRow(
                            item: item,
                            isSelected: Binding(
                                get: { selectedIDs.contains(item.id) },
                                set: { newValue in
                                    if newValue { selectedIDs.insert(item.id) }
                                    else        { selectedIDs.remove(item.id) }
                                }))
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)
            .background(appTheme.panelBackground.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(appTheme.separator, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var allSelected: Bool {
        !prompt.items.isEmpty && selectedIDs.count == prompt.items.count
    }

    private func toggleSelectAll() {
        if allSelected {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(prompt.items.map(\.id))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                onDiscard()
            } label: {
                Text("crashRecovery.button.discard", bundle: .module)
            }
            Spacer()
            Button {
                onRestore(selectedIDs)
            } label: {
                Text("crashRecovery.button.restore", bundle: .module)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedIDs.isEmpty)
        }
        .controlSize(.regular)
    }
}

// MARK: - One row

private struct CrashRecoveryRow: View {
    let item: CrashRecoveryItem
    @Binding var isSelected: Bool

    @Environment(\.appTheme) private var appTheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(appTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.externalChanged {
                        badge(textKey: "crashRecovery.badge.externalChanged",
                              tint: .orange)
                    }
                    if item.originalMissing {
                        badge(textKey: "crashRecovery.badge.fileMissing",
                              tint: .red)
                    }
                }
                if let path = item.originalPath {
                    Text(path)
                        .font(.system(size: 11))
                        .foregroundStyle(appTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("crashRecovery.untitled", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundStyle(appTheme.secondaryText)
                }
                Text(relativeSavedAt)
                    .font(.system(size: 10))
                    .foregroundStyle(appTheme.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
    }

    private var relativeSavedAt: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: item.savedAt, relativeTo: Date())
    }

    private func badge(textKey: String, tint: Color) -> some View {
        Text(LocalizedStringKey(textKey), bundle: .module)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .clipShape(Capsule())
    }
}
