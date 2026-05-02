//
//  TabBarView.swift
//  Chrome-like tab strip above the editor.
//

import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var workspace: Workspace
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                // Phase 48c — index-aware enumeration so the loop can
                // drop a hairline separator between the trailing
                // pinned tab and the leading unpinned tab. Without
                // the cue the strip reads as one continuous run; the
                // line gives the eye an anchor for the "pinned float
                // to the front" invariant we established in Phase 46b.
                // Boundary detection lives in `Workspace.pinBoundaryIndex`
                // so the rule is unit-testable without a headless view
                // harness.
                let boundary = workspace.pinBoundaryIndex
                ForEach(Array(workspace.documents.enumerated()), id: \.element.id) { idx, doc in
                    TabItem(doc: doc, isSelected: workspace.selectedID == doc.id)
                        .onTapGesture {
                            workspace.selectedID = doc.id
                        }
                    if boundary == idx,
                       idx + 1 < workspace.documents.count {
                        TabBarPinSeparator()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .frame(height: 34)
        .background(appTheme.windowBackground)
    }
}

/// Phase 48c — slim vertical bar that appears between the last
/// pinned tab and the first unpinned tab. Mirrors the
/// `StatusBarSeparator` styling used in the bottom strip so the
/// chrome reads as one cohesive system.
private struct TabBarPinSeparator: View {
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        Rectangle()
            .fill(appTheme.separator.opacity(0.55))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
            .help(L10n.t("tabbar.pinDivider.tooltip"))
            .accessibilityLabel(L10n.t("tabbar.pinDivider.tooltip"))
    }
}

private struct TabItem: View {
    @ObservedObject var doc: Document
    let isSelected: Bool
    @EnvironmentObject var workspace: Workspace
    @Environment(\.appTheme) private var appTheme
    @State private var hover = false
    @State private var closeHover = false
    /// Phase 46a — true while a drag is currently hovering over this
    /// tab as a drop target. Drives the leading-edge accent stripe
    /// that gives the user a pre-commit drop cue.
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            // Phase 46b — pinned tabs swap the language glyph for a
            // pin so the user sees which rows are persistent. Icon
            // tint stays in sync with the selection state so the row
            // still reads as active when highlighted.
            Image(systemName: doc.isPinned
                    ? "pin.fill"
                    : iconName(for: doc.languageGuess))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(isSelected ? Color.primary.opacity(0.85) : Color.secondary)
                .rotationEffect(doc.isPinned ? .degrees(45) : .zero)

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
                        .fill(appTheme.accent)
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
                    .fill(appTheme.accent)
                    .frame(height: 1.5)
                    .clipShape(.rect(topLeadingRadius: 6, topTrailingRadius: 6))
            }
        }
        // Phase 46a — drop-target cue. A 2pt vertical stripe on the
        // leading edge of the hovered tab tells the user "your drag
        // will land next to this one", matching the pattern VSCode /
        // Xcode use during a tab reorder drag.
        .overlay(alignment: .leading) {
            if dropTargeted {
                Rectangle()
                    .fill(appTheme.accent)
                    .frame(width: 2)
                    .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.18), value: isSelected)
        .animation(.easeOut(duration: 0.08), value: dropTargeted)
        // Phase 46a — tab reorder via drag-drop. The payload is the
        // source doc's UUID as a String so the drop handler can find
        // the originating Document without a bespoke Transferable
        // type (UUID-parse validation in the handler rejects any
        // unrelated String payload, e.g. text dragged from another
        // app). The draggable preview mirrors the tab's own row so
        // the drag feedback feels continuous with the strip.
        .draggable(doc.id.uuidString) {
            TabDragPreview(title: doc.title,
                           iconName: doc.isPinned
                             ? "pin.fill"
                             : iconName(for: doc.languageGuess),
                           iconRotated: doc.isPinned)
                .environment(\.appTheme, appTheme)
        }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items: items)
        } isTargeted: { active in
            dropTargeted = active
        }
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
            // Phase 46b — Pin / Unpin. Label flips to match the
            // action the click would perform; the persistence side
            // lives entirely in Workspace.togglePin so the view
            // stays declarative.
            Button {
                workspace.togglePin(doc)
            } label: {
                Text(doc.isPinned
                     ? "tabContext.unpin"
                     : "tabContext.pin",
                     bundle: .module)
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

    /// Phase 46a — resolve a drop. Parses the dragged payload as a
    /// UUID and, if it matches an existing tab, moves it to land
    /// next to the target tab (this view). We pick the destination
    /// so dragging **rightwards** inserts AFTER the target, and
    /// dragging **leftwards** inserts BEFORE it — matches the
    /// muscle memory from every other tab strip on macOS. Any non-
    /// UUID payload or unknown id returns false so SwiftUI surfaces
    /// the red "no" cursor to the user.
    private func handleDrop(items: [String]) -> Bool {
        guard let first = items.first,
              let draggedID = UUID(uuidString: first),
              draggedID != doc.id,
              let fromIdx = workspace.documents.firstIndex(where: { $0.id == draggedID }),
              let toIdx = workspace.documents.firstIndex(where: { $0.id == doc.id })
        else { return false }
        // Convert "target tab index" → "insert-before offset":
        //   dragging rightwards (from < to) ⇒ insert AFTER target
        //     ⇒ offset = toIdx + 1
        //   dragging leftwards  (from > to) ⇒ insert BEFORE target
        //     ⇒ offset = toIdx
        let destination = fromIdx < toIdx ? toIdx + 1 : toIdx
        workspace.moveDocument(fromIndex: fromIdx, toIndex: destination)
        return true
    }

    private var backgroundFill: Color {
        if isSelected {
            return Color(rgb: appTheme.editor.background)
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

/// Phase 46a — drag preview shown under the cursor while a tab is
/// being dragged. A compact capsule with the same icon + title the
/// user grabbed; uses the panel background so it reads as "detached
/// from the strip" against any window chrome the drag crosses.
private struct TabDragPreview: View {
    let title: String
    let iconName: String
    /// Phase 46b — `true` renders the glyph at 45° so the pin
    /// in the preview matches the tilt of the pin shown in the
    /// source tab.
    var iconRotated: Bool = false
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.85))
                .rotationEffect(iconRotated ? .degrees(45) : .zero)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(appTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(appTheme.separator.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}
