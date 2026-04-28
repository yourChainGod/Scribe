//
//  TabBarView.swift
//  Chrome-like tab strip above the editor.
//

import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.documents) { doc in
                    TabItem(doc: doc, isSelected: workspace.selectedID == doc.id)
                        .onTapGesture {
                            workspace.selectedID = doc.id
                        }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabItem: View {
    @ObservedObject var doc: Document
    let isSelected: Bool
    @EnvironmentObject var workspace: Workspace
    @State private var hover = false
    @State private var closeHover = false

    var body: some View {
        HStack(spacing: 6) {
            // File-type glyph keeps a visual hook for users who
            // skim by language. Same icon vocabulary the sidebar
            // DocRow uses, so the two stay consistent.
            Image(systemName: iconName(for: doc.languageGuess))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(isSelected ? Color.primary.opacity(0.85) : Color.secondary)

            Text(doc.title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)

            // Trailing widget — either dirty dot OR close button,
            // not both at once. Dirty dot melts into the close
            // button on hover so the layout doesn't shift.
            ZStack {
                if doc.isDirty && !hover {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                } else {
                    Button {
                        workspace.close(documentID: doc.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(closeHover ? Color.primary : Color.secondary)
                            .frame(width: 16, height: 16)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(closeHover ? Color.primary.opacity(0.10) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { closeHover = $0 }
                    .opacity(hover || isSelected ? 1 : 0)
                }
            }
            .frame(width: 16, height: 16)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(alignment: .top) {
            if isSelected {
                // Hairline accent stripe — feels closer to Xcode 15
                // than the heavier 2pt bar. Lives in the overlay so
                // the rounded corners of the parent fill stay clean.
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 1.5)
                    .clipShape(.rect(topLeadingRadius: 6, topTrailingRadius: 6))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.18), value: isSelected)
        // Right-click menu — Xcode/VSCode parity. Sourced through
        // .module so every label resolves through the locale catalogue.
        .contextMenu {
            Button {
                workspace.close(documentID: doc.id)
            } label: {
                Text("tabContext.close", bundle: .module)
            }
            Button {
                closeOthers()
            } label: {
                Text("tabContext.closeOthers", bundle: .module)
            }
            .disabled(workspace.documents.count <= 1)
            Button {
                closeAll()
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

    private func closeOthers() {
        // Iterate over a snapshot copy because workspace.close
        // mutates the underlying array.
        for other in workspace.documents where other.id != doc.id {
            workspace.close(documentID: other.id)
        }
    }

    private func closeAll() {
        for d in workspace.documents {
            workspace.close(documentID: d.id)
        }
    }

    private var backgroundFill: Color {
        if isSelected {
            return Color(nsColor: .textBackgroundColor)
        } else if hover {
            return Color.primary.opacity(0.05)
        } else {
            return Color.clear
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
