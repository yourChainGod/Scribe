//
//  FileTreeView.swift
//  Recursive lazy file browser.
//

import SwiftUI

struct FileTreeView: View {
    @ObservedObject var node: FileNode
    @EnvironmentObject var workspace: Workspace
    var depth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileRow(node: node, depth: depth)
            if node.isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileTreeView(node: child, depth: depth + 1)
                }
            }
        }
    }
}

private struct FileRow: View {
    @ObservedObject var node: FileNode
    @EnvironmentObject var workspace: Workspace
    let depth: Int
    @State private var hover = false

    /// True when this row corresponds to the document the editor is
    /// currently showing. Lights up the row so the user can see
    /// where in the tree they are after opening a file via Quick
    /// Open / search results.
    private var isActive: Bool {
        guard !node.isDirectory else { return false }
        // Compare by `standardizedFileURL.path` rather than raw URL
        // equality. The Document loaded via openFile may have gone
        // through bookmark resolution / symlink expansion, so its
        // URL can differ from the FileNode's URL even when both
        // point at the same file. The path strings are stable
        // after standardisation.
        return workspace.current?.url?.standardizedFileURL.path
            == node.url.standardizedFileURL.path
    }

    var body: some View {
        HStack(spacing: 4) {
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
                    .animation(.easeOut(duration: 0.15), value: node.isExpanded)
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: iconName)
                .font(.system(size: 11))
                .frame(width: 14)
                .foregroundStyle(iconTint)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.85))
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 12 + 6)
        .padding(.vertical, 4)
        .padding(.trailing, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(backgroundFill)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if node.isDirectory {
                if !node.isExpanded { node.loadChildren() }
                withAnimation(.easeOut(duration: 0.18)) {
                    node.isExpanded.toggle()
                }
            } else {
                workspace.openFile(at: node.url)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    private var backgroundFill: Color {
        if isActive {
            // Same tint family as the sidebar mode switcher's
            // active pill so the "what's selected where" reading
            // is consistent across the sidebar.
            return Color.accentColor.opacity(0.14)
        } else if hover {
            return Color.primary.opacity(0.06)
        } else {
            return Color.clear
        }
    }

    private var iconTint: Color {
        if node.isDirectory {
            return Color.accentColor
        }
        return Color.secondary
    }

    private var iconName: String {
        if node.isDirectory {
            return node.isExpanded ? "folder.fill" : "folder"
        }
        let ext = node.url.pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "md", "markdown": return "text.justify"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "cpp", "c", "h", "hpp", "mm", "m": return "c.circle"
        case "js", "ts", "jsx", "tsx": return "j.circle"
        case "png", "jpg", "jpeg", "gif", "svg", "icns": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz", "7z": return "archivebox"
        default: return "doc.text"
        }
    }
}
