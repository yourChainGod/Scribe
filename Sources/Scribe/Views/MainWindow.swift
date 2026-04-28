//
//  MainWindow.swift
//  Top-level layout: sidebar · tabs+editor · status bar.
//

import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var prefs: EditorPreferences
    @EnvironmentObject var findState: FindState
    @EnvironmentObject var findInFiles: FindInFilesState
    let findInFilesEngine: FindInFilesEngine
    @State private var dragOver = false
    /// Visibility binding for `NavigationSplitView`. SwiftUI on macOS
    /// 14 ships its own toolbar toggle that mutates this state, but
    /// without an explicit binding our toolbar's `workspace.
    /// sidebarVisible.toggle()` would be a no-op — the published
    /// flag had no path back to the layout. We mirror the two so a
    /// programmatic flip from a Cmd-Palette command still works.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        if let session = workspace.compareSession {
            DiffView(session: session, onClose: {
                workspace.compareSession = nil
            })
        } else {
            editorLayout
        }
    }

    /// Detail pane extracted so the editorLayout can attach
    /// .onChange / .onAppear modifiers to the NavigationSplitView
    /// without dropping them onto the inner VStack.
    private var detailContent: some View {
        VStack(spacing: 0) {
            TabBarView()
            Divider()
            EditorAreaView()
            Divider()
            StatusBarView()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var editorLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(findInFiles: findInFilesEngine)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 380)
        } detail: {
            detailContent
        }
        // Keep the workspace flag in lockstep with the column
        // visibility so command-palette / menu commands that read or
        // mutate `workspace.sidebarVisible` continue to work.
        .onAppear {
            columnVisibility = workspace.sidebarVisible ? .all : .detailOnly
        }
        .onChange(of: workspace.sidebarVisible) { _, want in
            let target: NavigationSplitViewVisibility = want ? .all : .detailOnly
            if columnVisibility != target {
                withAnimation(.easeInOut(duration: 0.20)) {
                    columnVisibility = target
                }
            }
        }
        .onChange(of: columnVisibility) { _, vis in
            let visible = vis != .detailOnly
            if workspace.sidebarVisible != visible {
                workspace.sidebarVisible = visible
            }
        }
        .toolbar {
            // Sidebar toggle stays anchored on the left, separate
            // from the file / edit / view button groups so it
            // tracks the macOS Mail / Xcode convention.
            ToolbarItem(placement: .navigation) {
                Button {
                    // Use SwiftUI's animated transaction so the
                    // sidebar slide is one smooth pass instead of
                    // two — without `.linear(duration: 0.18)` macOS
                    // 14 sometimes splits the visibility change
                    // across two render passes which felt janky.
                    withAnimation(.easeInOut(duration: 0.20)) {
                        columnVisibility = (columnVisibility == .all)
                            ? .detailOnly
                            : .all
                    }
                } label: {
                    Label {
                        Text("toolbar.toggleSidebar", bundle: .module)
                    } icon: {
                        Image(systemName: columnVisibility == .all
                              ? "sidebar.left"
                              : "sidebar.leading")
                    }
                }
                .help(L10n.t("toolbar.toggleSidebar"))
                .keyboardShortcut("\\", modifiers: .command)
            }

            // — File ops group — square.and.pencil for new comes
            // from the modern macOS document idiom (Mail / Notes
            // both use the same glyph for "compose"). folder /
            // tray.and.arrow.down are the unambiguous open / save
            // pair.
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.newDocument() } label: {
                    Label {
                        Text("toolbar.newFile", bundle: .module)
                    } icon: {
                        Image(systemName: "square.and.pencil")
                    }
                }
                .help(L10n.t("toolbar.newFile") + " (⌘N)")

                Button { workspace.openDocument() } label: {
                    Label {
                        Text("toolbar.openFile", bundle: .module)
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
                .help(L10n.t("toolbar.openFile") + " (⌘O)")

                Button { workspace.saveCurrent() } label: {
                    Label {
                        Text("toolbar.save", bundle: .module)
                    } icon: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                }
                .help(L10n.t("toolbar.save") + " (⌘S)")
                .disabled(workspace.current == nil)
            }

            // — Search / compare group — split off so SwiftUI
            // inserts the standard toolbar item-group spacing
            // between file ops and the search trio.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    findState.show(replaceMode: false)
                } label: {
                    Label {
                        Text("toolbar.find", bundle: .module)
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .help(L10n.t("toolbar.find") + " (⌘F)")
                .disabled(workspace.current == nil)

                Button {
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
                } label: {
                    Label {
                        Text("toolbar.findInFiles", bundle: .module)
                    } icon: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                }
                .help(L10n.t("toolbar.findInFiles") + " (⌘⇧F)")
                .disabled(workspace.folderRoot == nil)

                Button {
                    startCompare()
                } label: {
                    Label {
                        Text("toolbar.compare", bundle: .module)
                    } icon: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                }
                .help(L10n.t("toolbar.compare") + " (⌥⌘D)")
            }

            // — View / zoom group — on the far right because
            // macOS users expect view-state toggles last.
            ToolbarItemGroup(placement: .primaryAction) {
                Button { prefs.zoomOut() } label: {
                    Label {
                        Text("toolbar.zoomOut", bundle: .module)
                    } icon: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                }
                .help(L10n.t("toolbar.zoomOut") + " (⌘-)")
                .disabled(prefs.fontSize <= EditorPreferences.fontSizeMin)

                // Compact font-size readout. Tertiary-coloured so
                // it doesn't read as an interactive control —
                // users won't try to click it as a dropdown.
                // `monospacedDigit` keeps the width stable as the
                // value crosses 9 → 10.
                Text("\(Int(prefs.fontSize))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(minWidth: 18)
                    .help(L10n.t("toolbar.zoomReset"))

                Button { prefs.zoomIn() } label: {
                    Label {
                        Text("toolbar.zoomIn", bundle: .module)
                    } icon: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }
                .help(L10n.t("toolbar.zoomIn") + " (⌘+)")
                .disabled(prefs.fontSize >= EditorPreferences.fontSizeMax)
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
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
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
}
