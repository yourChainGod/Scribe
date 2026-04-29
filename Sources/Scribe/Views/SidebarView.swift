//
//  SidebarView.swift
//  Lists open documents and (when opened) the workspace folder tree.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var outline: SymbolOutline
    @Environment(\.appTheme) private var appTheme
    let findInFiles: FindInFilesEngine

    var body: some View {
        GeometryReader { proxy in
            sidebarContent(showModeSwitcher: proxy.size.width >= 180)
        }
        .background(appTheme.sidebarBackground)
    }

    private func sidebarContent(showModeSwitcher: Bool) -> some View {
        // Phase 38d — sidebar is just content now. The mode tabs
        // and collapse button moved up into the full-width chrome
        // toolbar, so the sidebar starts directly with whatever
        // pane the active mode wants.
        _ = showModeSwitcher
        return VStack(alignment: .leading, spacing: 0) {
            switch workspace.sidebarMode {
            case .files:         filesPane
            case .search:        FindInFilesSidebar(engine: findInFiles)
            case .outline:       OutlineSidebar(outline: outline)
            case .sourceControl: SourceControlSidebar(engine: workspace.gitStatusEngine)
            }
        }
        .background(appTheme.sidebarBackground)
        .clipped()
    }

    // MARK: - Mode switcher

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
                        .contextMenu {
                            Button {
                                workspace.newDocument()
                            } label: { Text("sidebar.action.newFile", bundle: .module) }
                            Button {
                                workspace.openDocument()
                            } label: { Text("menu.file.open", bundle: .module) }
                        }
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
                            .contextMenu {
                                if workspace.folderRoot == nil {
                                    Button {
                                        workspace.openFolder()
                                    } label: { Text("sidebar.action.openFolder", bundle: .module) }
                                } else {
                                    Button {
                                        workspace.openFolder()
                                    } label: { Text("sidebar.action.openFolder", bundle: .module) }
                                    Divider()
                                    Button(role: .destructive) {
                                        workspace.closeFolder()
                                    } label: { Text("sidebar.action.closeFolder", bundle: .module) }
                                }
                            }
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

enum SidebarModeSwitcherMetrics {
    static let iconSize: CGFloat = 12
    static let itemSpacing: CGFloat = 5
    static let buttonWidth: CGFloat = 30
    static let buttonHeight: CGFloat = 26
    static let activeBackgroundOpacity: Double = 0.14
    static let usesUnderlineIndicator = false
    /// Phase 38c — single header row matches the chrome
    /// commandBar's 36pt so both panes' first content row
    /// baselines across the splitter.
    static let headerRowHeight: CGFloat = 36
    /// Sidebar lives at the window's leading edge, so the macOS
    /// traffic-light buttons float over its top-left corner. The
    /// header row needs to clear that 70pt-ish area or the first
    /// mode tab ends up underneath the close button.
    static let trafficLightInset: CGFloat = 72
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
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        Button(action: tap) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundFill)
                Image(systemName: system)
                    .font(.system(size: SidebarModeSwitcherMetrics.iconSize, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isActive ? appTheme.accent : appTheme.secondaryText)
            }
            .frame(width: SidebarModeSwitcherMetrics.buttonWidth,
                   height: SidebarModeSwitcherMetrics.buttonHeight)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(Text(titleKey, bundle: .module))
        .accessibilityLabel(Text(titleKey, bundle: .module))
        .onHover { hover = $0 }
    }

    private var backgroundFill: Color {
        if isActive {
            return appTheme.accent.opacity(SidebarModeSwitcherMetrics.activeBackgroundOpacity)
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
    @Environment(\.appTheme) private var appTheme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: doc.languageGuess))
                .frame(width: 14)
                .foregroundStyle(appTheme.secondaryText)
            Text(doc.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12))
            Spacer()
            if doc.isDirty {
                Circle()
                    .fill(appTheme.accent)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected
                      ? appTheme.accent.opacity(0.18)
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
