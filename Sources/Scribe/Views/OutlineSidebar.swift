//
//  OutlineSidebar.swift
//  Phase 7 — sidebar tab #3: symbol outline of the active document.
//  Click a row → editor scrolls to that line via Document.pendingScrollLine,
//  the same hook Find-in-Files uses for jump-to-match.
//

import SwiftUI

struct OutlineSidebar: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var outline: SymbolOutline

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text("OUTLINE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if outline.isParsing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
            Spacer()
            if !outline.symbols.isEmpty {
                Text("\(outline.symbols.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if workspace.current == nil {
            placeholder("No document open")
        } else if outline.symbols.isEmpty && !outline.isParsing {
            placeholder("No symbols in this file")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(outline.symbols) { sym in
                        OutlineRow(symbol: sym)
                            .onTapGesture { jump(to: sym) }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer(minLength: 24)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    // MARK: - Actions

    /// Re-uses Document.pendingScrollLine — the hook
    /// ScintillaCodeEditor reads inside makeNSView/updateNSView to
    /// reposition the caret + scroll. No bespoke wiring needed.
    private func jump(to symbol: SymbolEntry) {
        guard let doc = workspace.current else { return }
        doc.pendingScrollLine = symbol.lineNumber
    }
}

private struct OutlineRow: View {
    let symbol: SymbolEntry
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            // Markdown headings indent by depth so the H1/H2/H3
            // hierarchy shows. Other languages stay at depth 0 → no
            // indent for now.
            if symbol.depth > 0 {
                Spacer().frame(width: CGFloat(symbol.depth * 12))
            }
            Image(systemName: symbol.kind.icon)
                .foregroundStyle(symbol.kind.tint)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(symbol.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text("\(symbol.lineNumber)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(hover
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
