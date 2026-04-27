//
//  MainWindow.swift
//  Top-level layout: sidebar · tabs+editor · status bar.
//

import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @EnvironmentObject var workspace: Workspace
    @State private var dragOver = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            VStack(spacing: 0) {
                TabBarView()
                Divider()
                EditorAreaView()
                Divider()
                StatusBarView()
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    workspace.sidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle Sidebar")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.newDocument() } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .help("New Tab (⌘N)")

                Button { workspace.openDocument() } label: {
                    Image(systemName: "folder")
                }
                .help("Open… (⌘O)")

                Button { workspace.saveCurrent() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save (⌘S)")

                Spacer()

                Button {} label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Find (⌘F)")

                Button {} label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .help("Compare Files")
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
}
