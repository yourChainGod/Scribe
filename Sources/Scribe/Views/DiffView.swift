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
    @Environment(\.appTheme) private var appTheme

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
        .background(appTheme.windowBackground)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                session.chooseAndCompare()
            } label: {
                Label {
                    Text("diff.button.openPair", bundle: .module)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
            .controlSize(.regular)

            Button {
                swap()
            } label: {
                Label {
                    Text("diff.button.swap", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.left.arrow.right")
                }
            }
            .disabled(session.result == nil)

            DiffToolbarSeparator()

            Button {
                session.previousHunk()
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(session.hunks.isEmpty)
            .help(L10n.t("diff.button.previous") + " (⌥⌘[)")

            Button {
                session.nextHunk()
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(session.hunks.isEmpty)
            .help(L10n.t("diff.button.next") + " (⌥⌘])")

            statusText

            Spacer()

            Button {
                onClose()
            } label: {
                Label {
                    Text("diff.button.close", bundle: .module)
                } icon: {
                    Image(systemName: "xmark")
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(appTheme.barBackground)
    }

    /// Hairline vertical separator inside the diff toolbar — same
    /// visual recipe as `StatusBarSeparator`. Keeps the toolbar
    /// from looking like an undifferentiated row of icons by
    /// cleaving file-ops from navigation-ops.
    private struct DiffToolbarSeparator: View {
        @Environment(\.appTheme) private var appTheme
        var body: some View {
            Rectangle()
                .fill(appTheme.separator.opacity(0.6))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if session.isComputing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("diff.status.diffing", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let result = session.result {
            let stats = result.stats
            let hunkLabel = session.hunks.isEmpty
                ? L10n.t("diff.summary.noDiffs")
                : L10n.t("diff.summary.diffOf", session.activeHunk + 1, session.hunks.count)
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
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            if !path.isEmpty {
                Text(path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(appTheme.sidebarBackground)
        .overlay(alignment: .bottom) {
            // Hairline so the pane header reads as a distinct
            // strip rather than melting into the editor body.
            Rectangle()
                .fill(appTheme.separator.opacity(0.5))
                .frame(height: 0.5)
        }
    }

    // MARK: - Empty state

    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("diff.empty.title", bundle: .module)
                    .font(.system(size: 22, weight: .light))
                Text("diff.empty.subtitle", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 380)
            }
            Button {
                session.chooseAndCompare()
            } label: {
                Text("diff.empty.button", bundle: .module)
            }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appTheme.windowBackground)
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
