//
//  MainWindow.swift
//  Top-level layout: sidebar · tabs+editor · status bar.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainWindow: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var prefs: EditorPreferences
    @EnvironmentObject var findState: FindState
    @EnvironmentObject var findInFiles: FindInFilesState
    let findInFilesEngine: FindInFilesEngine
    @State private var dragOver = false
    @Environment(\.appTheme) private var appTheme
    /// Phase 38h — NavigationSplitView's column visibility binding.
    /// Bridges to `workspace.sidebarVisible` (the legacy boolean
    /// the rest of the app, including command palette + tests,
    /// reads & writes). NavigationSplitView gives us the
    /// macOS-native sidebar-extends-to-top look (traffic lights
    /// sit ON the sidebar, not above it), free Finder-style
    /// slide-in/out animation, and proper Scintilla resize on
    /// collapse — fixing the dark-stripe rendering glitch the
    /// HStack+frame(width:0) approach left behind.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        // Phase 43-T — wrap both editor and compare-files screens
        // in a single overlay host so toasts render above every
        // workspace state. The overlay only intercepts hits while a
        // banner is visible (`allowsHitTesting` lives inside
        // `ToastOverlay`).
        Group {
            if let session = workspace.compareSession {
                DiffView(session: session, onClose: {
                    workspace.compareSession = nil
                })
            } else {
                editorLayout
            }
        }
        .overlay {
            ToastOverlay(center: workspace.toastCenter)
        }
    }

    /// Sidebar column — header row (4 mode tabs centered) above
    /// the active sidebar pane. NavigationSplitView extends the
    /// column's background to the window's top edge, so the
    /// traffic lights end up sitting over the sidebar (macOS
    /// Finder / Mail / Notes style).
    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            sidebarHeaderRow
            Divider()
            SidebarView(findInFiles: findInFilesEngine)
        }
        // Phase 36 — paint the sidebar column edge-to-edge so the
        // traffic-light row + sidebarHeaderRow + content are one
        // continuous block of `appTheme.sidebarBackground`.
        // NavigationSplitView's default vibrancy material would
        // otherwise show through above the headerRow and reintroduce
        // the system grey we just stripped from every other surface.
        .background(appTheme.sidebarBackground)
    }

    /// Detail column — tab bar above the editor canvas and
    /// status bar. The macOS unified toolbar sits above this
    /// column (the .toolbar modifier on NavigationSplitView).
    private var detailColumn: some View {
        VStack(spacing: 0) {
            TabBarView()
            Divider()
            EditorAreaView()
            Divider()
            StatusBarView()
        }
        .background(Color(rgb: appTheme.editor.background))
    }

    private var editorLayout: some View {
        // Phase 38h — NavigationSplitView replaces the custom
        // HStack+splitter approach. Three wins:
        //   1. Sidebar extends to the very top of the window —
        //      macOS draws the traffic-light buttons ON TOP of
        //      the sidebar's background, the way Finder does it.
        //   2. Free macOS-native slide-in/out animation when
        //      collapsing/expanding (no manual width tween, no
        //      HStack layout glitches).
        //   3. The detail column is resized cleanly on toggle,
        //      so Scintilla no longer leaves dark vertical
        //      stripes when the sidebar slides away.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 380)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            sidebarToggleToolbar
            fileOpsToolbar
            editOpsToolbar
            zoomToolbar
        }
        // Phase 36 — hide the unified toolbar's default material so
        // the sidebar's `appTheme.sidebarBackground` and the detail
        // column's `appTheme.editor.background` reach all the way up
        // to the traffic-light row. Without this, macOS draws its
        // own translucent grey strip across the toolbar and breaks
        // the theme's continuity at the very top of the window.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onChange(of: columnVisibility) { _, vis in
            workspace.sidebarVisible = (vis != .detailOnly)
        }
        .onChange(of: workspace.sidebarVisible) { _, visible in
            withAnimation(MainWindowChromeMetrics.sidebarAnimation) {
                columnVisibility = visible ? .all : .detailOnly
            }
        }
        .onChange(of: workspace.isTextToolsPresented) { _, presented in
            if presented {
                findState.commands.send(.hideInlineBlameTooltip)
            }
        }
        .navigationTitle(workspace.current?.title ?? "Scribe")
        .navigationSubtitle(workspace.current?.url?.path ?? "")
        .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                           isDir.boolValue {
                            // Drop a folder → open as workspace
                            let root = FileNode(url: url)
                            root.isExpanded = true
                            root.loadChildren()
                            workspace.folderRoot = root
                        } else {
                            workspace.openFile(at: url)
                        }
                    }
                }
            }
            return true
        }
        .overlay {
            if dragOver {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(appTheme.accent, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $workspace.externalChangePrompt) { prompt in
            ExternalChangeSheet(prompt: prompt) { reloadFromDisk in
                workspace.resolveExternalChange(prompt, reloadFromDisk: reloadFromDisk)
            }
        }
        .sheet(isPresented: $workspace.isTextToolsPresented) {
            TextToolsWorkbench()
                .environmentObject(workspace)
                .environmentObject(findState)
        }
    }

    /// Sidebar column's header row — 4 mode tabs on the leading
    /// edge. 34pt high to match TabBarView so the sidebar's first
    /// content row and the editor's first text row baseline across
    /// the splitter. The collapse button used to live here too,
    /// but it was a duplicate of the unified-toolbar toggle and
    /// has been removed (Phase 38h). No leading inset for traffic
    /// lights — they sit above the HStack inside the macOS
    /// unified toolbar.
    /// Sidebar header row — 4 mode tabs centered across the
    /// row's full width. 34pt high so the sidebar's first
    /// content row baselines with the editor's first text row
    /// across the splitter. Collapse button lives in the
    /// unified toolbar (toolbar(removing: .sidebarToggle) +
    /// our custom sidebarToggleToolbar replacement), so this
    /// row holds only the four mode-switch icons.
    private var sidebarHeaderRow: some View {
        HStack(spacing: MainWindowChromeMetrics.itemSpacing) {
            Spacer()
            sidebarModeButton(.files,         icon: "folder",                helpKey: "sidebar.mode.files")
            sidebarModeButton(.search,        icon: "magnifyingglass",       helpKey: "sidebar.mode.search")
            sidebarModeButton(.outline,       icon: "list.bullet.indent",    helpKey: "sidebar.mode.outline")
            sidebarModeButton(.sourceControl, icon: "arrow.triangle.branch", helpKey: "sidebar.mode.sourceControl")
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
    }

    /// Sidebar mode button — same visual idiom as ChromeToolbarButton,
    /// active when the sidebar is visible AND showing this mode.
    /// Tap active → collapse sidebar. Tap inactive → switch mode
    /// (auto-expand if hidden).
    private func sidebarModeButton(_ mode: SidebarMode,
                                   icon: String,
                                   helpKey: String) -> some View {
        let isActive = workspace.sidebarVisible && workspace.sidebarMode == mode
        return ChromeToolbarButton(systemName: icon,
                                   titleKey: LocalizedStringKey(helpKey),
                                   helpText: L10n.t(helpKey),
                                   isActive: isActive) {
            withAnimation(MainWindowChromeMetrics.sidebarAnimation) {
                if isActive {
                    workspace.sidebarVisible = false
                } else {
                    workspace.sidebarVisible = true
                    workspace.sidebarMode = mode
                }
            }
        }
    }

    // MARK: - macOS unified toolbar contents

    /// Sidebar toggle in the unified toolbar's leading
    /// (.navigation) slot — the sole sidebar collapse/expand
    /// affordance after Phase 38h pulled the duplicate out of the
    /// in-sidebar header. Icon swaps between filled (sidebar open,
    /// accent-tinted) and outlined (sidebar collapsed, secondary)
    /// so a glance at the toolbar tells you the current state.
    @ToolbarContentBuilder
    private var sidebarToggleToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(MainWindowChromeMetrics.sidebarAnimation) {
                    workspace.sidebarVisible.toggle()
                }
            } label: {
                Image(systemName: workspace.sidebarVisible
                                  ? "sidebar.left"
                                  : "sidebar.leading")
                    .symbolVariant(workspace.sidebarVisible ? .fill : .none)
                    .foregroundStyle(workspace.sidebarVisible
                                     ? appTheme.accent
                                     : appTheme.secondaryText)
            }
            .help(L10n.t("toolbar.toggleSidebar"))
        }
    }

    @ToolbarContentBuilder
    private var fileOpsToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Button { workspace.newDocument() } label: {
                Image(systemName: "square.and.pencil")
            }
            .help(L10n.t("toolbar.newFile") + " (⌘N)")

            Button { workspace.openDocument() } label: {
                Image(systemName: "folder")
            }
            .help(L10n.t("toolbar.openFile") + " (⌘O)")

            Button { workspace.saveCurrent() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(workspace.current == nil)
            .help(L10n.t("toolbar.save") + " (⌘S)")
        }
    }

    @ToolbarContentBuilder
    private var editOpsToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Button {
                findState.show(replaceMode: false)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .disabled(workspace.current == nil)
            .help(L10n.t("toolbar.find") + " (⌘F)")

            Button {
                showFindInFiles()
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .disabled(workspace.folderRoot == nil)
            .help(L10n.t("toolbar.findInFiles") + " (⌘⇧F)")

            Button {
                startCompare()
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help(L10n.t("toolbar.compare") + " (⌥⌘D)")

            if let doc = workspace.current {
                Button {
                    findState.commands.send(.hideInlineBlameTooltip)
                    workspace.toggleMarkdownPreview()
                } label: {
                    Image(systemName: markdownIcon(for: doc))
                        .symbolVariant(doc.isMarkdownPreviewVisible ? .fill : .none)
                }
                .disabled(!doc.isMarkdown)
                .help(markdownHelp(for: doc))
            }
        }
    }

    @ToolbarContentBuilder
    private var zoomToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { prefs.zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(prefs.fontSize <= EditorPreferences.fontSizeMin)
            .help(L10n.t("toolbar.zoomOut") + " (⌘-)")

            Text("\(Int(prefs.fontSize))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 22)
                .help(L10n.t("toolbar.zoomReset"))

            Button { prefs.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(prefs.fontSize >= EditorPreferences.fontSizeMax)
            .help(L10n.t("toolbar.zoomIn") + " (⌘+)")
        }
    }

    /// Pop the open panel, load the two picked files, switch
    /// MainWindow into Compare mode.
    private func startCompare() {
        let session = DiffSession()
        session.chooseAndCompare()
        // Only show the diff view if the user actually chose two files.
        if session.leftURL != nil, session.rightURL != nil {
            workspace.compareSession = session
        }
    }

    private func showFindInFiles() {
        workspace.sidebarVisible = true
        workspace.sidebarMode = .search
        let selection = workspace.activeSelection
        if !selection.isEmpty {
            findInFiles.query = selection
            if let root = workspace.folderRoot?.url {
                let opts = FindInFilesOptions(
                    query: selection,
                    matchCase: findInFiles.matchCase,
                    wholeWord: findInFiles.wholeWord,
                    regex: false,
                    includeGlobs: [],
                    excludeGlobs: []
                )
                findInFilesEngine.search(options: opts,
                                         root: root,
                                         into: findInFiles)
            }
        }
    }

    private func markdownIcon(for doc: Document) -> String {
        guard doc.isMarkdown else { return "eye.slash" }
        return doc.isMarkdownPreviewVisible ? "eye.fill" : "eye"
    }

    private func markdownHelp(for doc: Document) -> String {
        guard doc.isMarkdown else {
            return L10n.t("menu.view.markdownPreviewUnavailable")
        }
        return L10n.t("menu.view.markdownPreview") + " (⌘⇧V)"
    }
}

enum MainWindowChromeMetrics {
    static let commandBarHeight: CGFloat = 38
    static let iconButtonSide: CGFloat = 26
    static let itemSpacing: CGFloat = 4
    /// Always reserve room for the macOS traffic-light buttons.
    /// The chrome row spans the full window width since Phase 38d,
    /// so the inset no longer changes with the sidebar state.
    static let trafficLightInset: CGFloat = 72

    /// Phase 38c — single source of truth for the sidebar
    /// open/close animation. Soft easing with a tiny bounce
    /// reads as "alive" rather than the mechanical feel of a
    /// fixed-duration easeInOut. Same curve drives both the
    /// chrome's expand and collapse paths.
    static let sidebarAnimation: Animation = .smooth(duration: 0.55, extraBounce: 0.05)
    /// Sidebar width clamps. Replaces the HSplitView's
    /// minWidth/idealWidth/maxWidth on the sidebar's frame —
    /// MainWindow now owns the width state directly so the
    /// custom splitter can drive it.
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 380

    /// Chrome leading padding always clears the traffic lights
    /// since the chrome row is full-width. Parameter kept for
    /// API compatibility with older callers / tests.
    static func leadingPadding(sidebarVisible: Bool) -> CGFloat {
        _ = sidebarVisible
        return trafficLightInset
    }
}

private struct ChromeToolbarButton: View {
    let systemName: String
    let titleKey: LocalizedStringKey
    let helpText: String
    var isDisabled = false
    var isActive = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: MainWindowChromeMetrics.iconButtonSide,
                       height: MainWindowChromeMetrics.iconButtonSide)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .foregroundStyle(foregroundColor)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundColor)
        )
        .help(helpText)
        .accessibilityLabel(Text(titleKey, bundle: .module))
        .onHover { hover = $0 }
    }

    private var foregroundColor: Color {
        if isDisabled { return appTheme.secondaryText.opacity(0.45) }
        if isActive { return appTheme.accent }
        return appTheme.secondaryText
    }

    private var backgroundColor: Color {
        if isDisabled { return .clear }
        if isActive { return appTheme.accent.opacity(0.14) }
        if hover { return Color.primary.opacity(0.06) }
        return .clear
    }
}

private struct ChromeToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }
}

/// Phase 38h — invisible bridge that reaches up to the host
/// NSWindow and turns off the hairline that AppKit normally draws
/// between the unified toolbar and the content view. With the
/// separator gone, the sidebar's controlBackgroundColor abuts the
/// toolbar with no visual gap, and the vertical splitter between
/// sidebar and detail column reads as if it ran from the toolbar
/// down to the status bar in one continuous stroke.
private struct ExternalChangeSheet: View {
    let prompt: ExternalChangePrompt
    let resolve: (Bool) -> Void
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("alert.diskChanged.title", prompt.title as NSString))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("alert.diskChanged.body", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button(role: .destructive) {
                    resolve(true)
                } label: {
                    Text("alert.button.reload", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)

                Button(role: .cancel) {
                    resolve(false)
                } label: {
                    Text("alert.button.keepChanges", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 460)
        .background(appTheme.windowBackground)
        .interactiveDismissDisabled()
    }
}
