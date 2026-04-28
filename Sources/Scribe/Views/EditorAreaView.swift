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
        if let doc = workspace.current {
            VStack(spacing: 0) {
                if findState.isVisible {
                    FindBar(state: findState)
                }
                ScintillaCodeEditor(doc: doc, prefs: prefs, findState: findState)
                    .id(doc.id)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            WelcomeView()
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var prefs: EditorPreferences

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
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Scribe")
                .font(.system(size: 28, weight: .light))
            Text("A native macOS text editor.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("New") { workspace.newDocument() }
                    .keyboardShortcut("n")
                Button("Open…") { workspace.openDocument() }
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
            Text("Recent")
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
