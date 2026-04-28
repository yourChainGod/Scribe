//
//  SidebarView.swift
//  Lists open documents and (when opened) the workspace folder tree.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var outline: SymbolOutline
    let findInFiles: FindInFilesEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modeSwitcher
            Divider()
            switch workspace.sidebarMode {
            case .files:   filesPane
            case .search:  FindInFilesSidebar(engine: findInFiles)
            case .outline: OutlineSidebar(outline: outline)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Mode switcher

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            modeButton(.files,   system: "folder",                titleKey: "sidebar.mode.files")
            modeButton(.search,  system: "magnifyingglass",       titleKey: "sidebar.mode.search")
            modeButton(.outline, system: "list.bullet.indent",    titleKey: "sidebar.mode.outline")
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func modeButton(_ mode: SidebarMode,
                            system: String,
                            titleKey: LocalizedStringKey) -> some View {
        ModeSwitcherButton(mode: mode,
                           system: system,
                           titleKey: titleKey,
                           isActive: workspace.sidebarMode == mode,
                           tap: { workspace.sidebarMode = mode })
    }

    // MARK: - Files pane

    private var filesPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                    // OPEN section
                    SectionHeader(titleKey: "sidebar.section.open", systemImage: "doc.text")
                    ForEach(workspace.documents) { doc in
                        DocRow(doc: doc, isSelected: workspace.selectedID == doc.id)
                            .onTapGesture {
                                workspace.selectedID = doc.id
                            }
                    }

                    Spacer().frame(height: 12)

                    // WORKSPACE section
                    HStack {
                        SectionHeader(titleKey: "sidebar.section.workspace", systemImage: "folder")
                        Spacer()
                        if workspace.folderRoot == nil {
                            Button {
                                workspace.openFolder()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 12)
                        } else {
                            Button {
                                workspace.closeFolder()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 12)
                        }
                    }

                    if let root = workspace.folderRoot {
                        FileTreeView(node: root)
                    } else {
                        Button {
                            workspace.openFolder()
                        } label: {
                            HStack {
                                Image(systemName: "folder.badge.plus")
                                Text("sidebar.action.openFolder", bundle: .module)
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 16)
            }
        }
    }
}

/// Pulled out so the per-button `@State hover` doesn't get reset
/// every time the parent re-renders. Sibling buttons get
/// independent hover lifecycles. Lives outside SidebarView so the
/// `@State` survives mode switches.
private struct ModeSwitcherButton: View {
    let mode: SidebarMode
    let system: String
    let titleKey: LocalizedStringKey
    let isActive: Bool
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                Image(systemName: system)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                Text(titleKey, bundle: .module)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.18), value: isActive)
    }

    private var backgroundFill: Color {
        if isActive {
            // Slightly softer than the previous 18% so the active
            // pill doesn't fight the surrounding sidebar chrome.
            return Color.accentColor.opacity(0.14)
        } else if hover {
            return Color.primary.opacity(0.06)
        } else {
            return Color.clear
        }
    }
}

private struct SectionHeader: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    var body: some View {
        Label {
            Text(titleKey, bundle: .module)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct DocRow: View {
    @ObservedObject var doc: Document
    let isSelected: Bool
    @EnvironmentObject var workspace: Workspace
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: doc.languageGuess))
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(doc.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12))
            Spacer()
            if doc.isDirty {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.18)
                      : (hover ? Color.gray.opacity(0.12) : Color.clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // Right-click on an open-document row mirrors the tab-bar
        // context menu so the two surfaces don't drift in feature
        // parity. We share keys via tabContext.* so a translation
        // change for the tabs propagates here automatically.
        .contextMenu {
            Button {
                workspace.close(documentID: doc.id)
            } label: {
                Text("tabContext.close", bundle: .module)
            }
            Button {
                for other in workspace.documents where other.id != doc.id {
                    workspace.close(documentID: other.id)
                }
            } label: {
                Text("tabContext.closeOthers", bundle: .module)
            }
            .disabled(workspace.documents.count <= 1)
            Button {
                for d in workspace.documents {
                    workspace.close(documentID: d.id)
                }
            } label: {
                Text("tabContext.closeAll", bundle: .module)
            }
            Divider()
            Button {
                guard let url = doc.url else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Text("tabContext.revealInFinder", bundle: .module)
            }
            .disabled(doc.url == nil)
            Button {
                guard let url = doc.url else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(url.path, forType: .string)
            } label: {
                Text("tabContext.copyPath", bundle: .module)
            }
            .disabled(doc.url == nil)
        }
    }

    private func iconName(for lang: String) -> String {
        switch lang {
        case "swift": "swift"
        case "md", "markdown": "text.justify"
        case "json": "curlybraces"
        case "py": "chevron.left.forwardslash.chevron.right"
        case "cpp", "c", "h", "hpp": "c.circle"
        case "js", "ts": "j.circle"
        default: "doc.text"
        }
    }
}
