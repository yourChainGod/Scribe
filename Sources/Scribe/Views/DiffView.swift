//
//  DiffView.swift
//  Phase 5 — top-level Compare-Files screen. Toolbar at the top with
//  Open / Next / Previous / Swap / Close, two DiffEditorPanes side by
//  side underneath.
//

import SwiftUI

struct DiffView: View {
    @ObservedObject var session: DiffSession
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let result = session.result {
                splitPanes(result: result)
            } else {
                placeholder
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                session.chooseAndCompare()
            } label: {
                Label("Open Pair…", systemImage: "doc.on.doc")
            }

            Button {
                swap()
            } label: {
                Label("Swap", systemImage: "arrow.left.arrow.right")
            }
            .disabled(session.result == nil)

            Spacer().frame(width: 12)

            Button {
                session.previousHunk()
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(session.hunks.isEmpty)
            .help("Previous Diff (⌥⌘[)")

            Button {
                session.nextHunk()
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(session.hunks.isEmpty)
            .help("Next Diff (⌥⌘])")

            statusText

            Spacer()

            Button {
                onClose()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var statusText: some View {
        if session.isComputing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Diffing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let result = session.result {
            let stats = result.stats
            let hunkLabel = session.hunks.isEmpty
                ? "no diffs"
                : "diff \(session.activeHunk + 1) of \(session.hunks.count)"
            Text("+\(stats.added)  -\(stats.removed)  ~\(stats.changed)  ·  \(hunkLabel)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else if let err = session.error {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Panes

    private func splitPanes(result: DiffResult) -> some View {
        HSplitView {
            VStack(spacing: 0) {
                paneHeader(title: session.leftLabel
                            ?? session.leftURL?.lastPathComponent
                            ?? "Left",
                           path: session.leftSubtitle
                            ?? session.leftURL?.deletingLastPathComponent().path
                            ?? "")
                Divider()
                DiffEditorPane(
                    text: session.leftText,
                    ops: result.ops,
                    side: .left,
                    activeHunkIndex: session.activeHunk,
                    session: session,
                    onLineClicked: { _ in }
                )
            }
            VStack(spacing: 0) {
                paneHeader(title: session.rightLabel
                            ?? session.rightURL?.lastPathComponent
                            ?? "Right",
                           path: session.rightSubtitle
                            ?? session.rightURL?.deletingLastPathComponent().path
                            ?? "")
                Divider()
                DiffEditorPane(
                    text: session.rightText,
                    ops: result.ops,
                    side: .right,
                    activeHunkIndex: session.activeHunk,
                    session: session,
                    onLineClicked: { _ in }
                )
            }
        }
    }

    @ViewBuilder
    private func paneHeader(title: String, path: String) -> some View {
        HStack {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            if !path.isEmpty {
                Text(path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Empty state

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Compare Files")
                .font(.system(size: 22, weight: .light))
            Text("Pick two files to see a side-by-side diff with synchronized scrolling.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Choose Files…") { session.chooseAndCompare() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Actions

    private func swap() {
        // Symmetric swap: every left↔right slot moves together so a
        // git-diff pane (left=HEAD, right=Working) flips to (left=
        // Working, right=HEAD) with all its labels intact.
        let lu = session.leftURL,    ru = session.rightURL
        let lt = session.leftText,   rt = session.rightText
        let ll = session.leftLabel,  rl = session.rightLabel
        let ls = session.leftSubtitle, rs = session.rightSubtitle
        session.leftURL = ru;       session.rightURL = lu
        session.leftText = rt;      session.rightText = lt
        session.leftLabel = rl;     session.rightLabel = ll
        session.leftSubtitle = rs;  session.rightSubtitle = ls
        Task { await session.recompute() }
    }
}
