//
//  TabBarView.swift
//  Chrome-like tab strip above the editor.
//

import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(workspace.documents) { doc in
                    TabItem(doc: doc, isSelected: workspace.selectedID == doc.id)
                        .onTapGesture {
                            workspace.selectedID = doc.id
                        }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabItem: View {
    @ObservedObject var doc: Document
    let isSelected: Bool
    @EnvironmentObject var workspace: Workspace
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(doc.title)
                .font(.system(size: 12))
                .lineLimit(1)
            if doc.isDirty {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
            }
            Button {
                workspace.close(documentID: doc.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hover || isSelected ? Color.primary : Color.secondary.opacity(0.0))
                    .frame(width: 14, height: 14)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(hover ? 0.2 : 0.0))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected
                      ? Color(nsColor: .textBackgroundColor)
                      : Color.clear)
        )
        .overlay(alignment: .top) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .clipShape(.rect(topLeadingRadius: 5, topTrailingRadius: 5))
            }
        }
        .onHover { hover = $0 }
    }
}
