//
//  SidebarView.swift
//  Lists open documents and (when opened) the workspace folder tree.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // OPEN section
                    SectionHeader(title: "OPEN", systemImage: "doc.text")
                    ForEach(workspace.documents) { doc in
                        DocRow(doc: doc, isSelected: workspace.selectedID == doc.id)
                            .onTapGesture {
                                workspace.selectedID = doc.id
                            }
                    }

                    Spacer().frame(height: 12)

                    // WORKSPACE section
                    HStack {
                        SectionHeader(title: "WORKSPACE", systemImage: "folder")
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
                                Text("Open Folder…")
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
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}

private struct DocRow: View {
    @ObservedObject var doc: Document
    let isSelected: Bool
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
