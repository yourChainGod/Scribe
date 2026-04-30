//
//  EditorAreaView.swift
//  The big text canvas. Backed by ScintillaCodeEditor since Phase 1.7c.
//

import SwiftUI

struct EditorAreaView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var prefs: EditorPreferences
    @EnvironmentObject var findState: FindState

    var body: some View {
        // Phase 35b-4-b — Project Diff multibuffer overlay. We
        // check the workspace flag *before* the document branch
        // so the multibuffer can render even when no document is
        // selected (e.g. after closeAll). The TabBar stays live
        // above us, so re-selecting a tab still flips the flag
        // off via SourceControlSidebar / ESC.
        if workspace.projectDiffVisible {
            ProjectDiffView(engine: workspace.gitStatusEngine)
                .environmentObject(workspace)
        } else if let doc = workspace.current {
            // Indirect through a Document-aware sub-view so SwiftUI
            // tracks per-doc @Published changes (e.g. toggling the
            // markdown preview) and re-evaluates body without us
            // having to mark every doc property as a workspace-level
            // dependency.
            DocumentEditorPane(doc: doc)
                .environmentObject(workspace)
                .environmentObject(prefs)
                .environmentObject(findState)
        } else {
            WelcomeView()
        }
    }
}

/// Editor + (optional) markdown preview for a single document.
/// Lives inside EditorAreaView; broken out so its `@ObservedObject`
/// on the Document picks up `isMarkdownPreviewVisible` flips even
/// though Workspace.documents itself didn't change identity.
private struct DocumentEditorPane: View {
    @ObservedObject var doc: Document
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var prefs: EditorPreferences
    @EnvironmentObject var findState: FindState
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if findState.isVisible {
                FindBar(state: findState)
            }
            if doc.isMarkdown, doc.isMarkdownPreviewVisible {
                // HSplitView lets the user drag the divider; the
                // preview's minWidth keeps it from collapsing into
                // an unreadable strip.
                HSplitView {
                    editor
                    MarkdownPreviewPane(markdown: doc.text,
                                        isDark: colorScheme == .dark)
                        .frame(minWidth: 260)
                }
            } else {
                editor
            }
        }
    }

    private var editor: some View {
        ScintillaCodeEditor(doc: doc, prefs: prefs, findState: findState)
            .id(doc.id)
            .background(Color(rgb: appTheme.editor.background))
            .contextMenu {
                editorContextMenu(doc: doc)
            }
    }

    /// Editor right-click menu. Replaces Scintilla's English built-in
    /// pop-up (suppressed via SCI_USEPOPUP=NEVER in the wrapper).
    /// Every action is routed through `NSApp.sendAction(_:to:from:)`
    /// with `to: nil` so the responder chain hits ScintillaView, which
    /// owns the editor's text. That's the same path the Edit menu's
    /// system items take, so behaviour stays identical.
    @ViewBuilder
    private func editorContextMenu(doc: Document) -> some View {
        Button {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } label: {
            Text("editor.context.undo", bundle: .module)
        }
        Button {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        } label: {
            Text("editor.context.redo", bundle: .module)
        }
        Divider()
        Button {
            NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        } label: {
            Text("context.cut", bundle: .module)
        }
        Button {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        } label: {
            Text("context.copy", bundle: .module)
        }
        Button {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        } label: {
            Text("context.paste", bundle: .module)
        }
        Button {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        } label: {
            Text("context.selectAll", bundle: .module)
        }
        Divider()
        // Common editor utilities — find / find-in-files / save —
        // mirror the same actions accessible from the Edit menu so a
        // user who right-clicks expecting to "do something here" gets
        // the same surface.
        Button {
            findState.show(replaceMode: false)
        } label: {
            Text("editor.context.find", bundle: .module)
        }
        Menu {
            Button {
                workspace.isTextToolsPresented = true
            } label: {
                Text("menu.tools.textTools", bundle: .module)
            }
            Divider()
            TextTransformCommandButtons(findState: findState, workspace: workspace, prefs: prefs)
        } label: {
            Text("editor.context.transform", bundle: .module)
        }
        Divider()
        Button {
            findState.commands.send(.hideInlineBlameTooltip)
            workspace.toggleMarkdownPreview()
        } label: {
            if doc.isMarkdownPreviewVisible {
                Label(L10n.t("menu.view.markdownPreview"),
                      systemImage: "checkmark")
            } else {
                Label(L10n.t("menu.view.markdownPreview"),
                      systemImage: doc.isMarkdown ? "eye" : "eye.slash")
            }
        }
        .disabled(!doc.isMarkdown)
        .help(doc.isMarkdown
              ? L10n.t("menu.view.markdownPreview") + " (⌘⇧V)"
              : L10n.t("menu.view.markdownPreviewUnavailable"))
        if doc.url != nil {
            Divider()
            Button {
                guard let url = doc.url else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Text("editor.context.revealInFinder", bundle: .module)
            }
            Button {
                guard let url = doc.url else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(url.path, forType: .string)
            } label: {
                Text("editor.context.copyPath", bundle: .module)
            }
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var prefs: EditorPreferences
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        // Two-column layout: hero on top, recent files in a
        // scrollable list below. The recent list only renders
        // when there's at least one file remembered, so a
        // first-time user still sees a clean centered hero.
        VStack(spacing: 24) {
            hero
            if !prefs.recentFiles.isEmpty {
                recentList
            }
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(rgb: appTheme.editor.background))
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("welcome.title", bundle: .module)
                .font(.system(size: 28, weight: .light))
            Text("welcome.subtitle", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    workspace.newDocument()
                } label: {
                    Text("welcome.button.new", bundle: .module)
                }
                .keyboardShortcut("n")
                Button {
                    workspace.openDocument()
                } label: {
                    Text("welcome.button.open", bundle: .module)
                }
                .keyboardShortcut("o")
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
    }

    /// Recent-files block. Mirrors the "Recents" surface that
    /// macOS apps like Pages / Numbers show on a blank window —
    /// click to re-open. Capped at 8 entries so the list stays
    /// scannable; the full set lives in Settings → Recent Files.
    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("welcome.recent.header", bundle: .module)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 1) {
                ForEach(prefs.recentFiles.prefix(8), id: \.self) { url in
                    RecentFileRow(url: url) {
                        workspace.openFile(at: url)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .frame(maxWidth: 380)
    }
}

private struct RecentFileRow: View {
    let url: URL
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: url))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(url.deletingLastPathComponent().path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown": return "text.justify"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "cpp", "c", "h", "hpp", "mm", "m": return "c.circle"
        case "js", "ts", "jsx", "tsx": return "j.circle"
        default: return "doc.text"
        }
    }
}
