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

    var body: some View {
        HStack(spacing: 4) {
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: iconName)
                .frame(width: 14)
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12))
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 12 + 6)
        .padding(.vertical, 3)
        .padding(.trailing, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(hover ? Color.gray.opacity(0.12) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if node.isDirectory {
                if !node.isExpanded { node.loadChildren() }
                node.isExpanded.toggle()
            } else {
                workspace.openFile(at: node.url)
            }
        }
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
