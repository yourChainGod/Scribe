//
//  MergeConflictBannerView.swift
//  Phase 68 — floating button strip the editor overlay drops on
//  top of every git merge conflict block. Three accept buttons
//  (Current / Incoming / Both) plus a label that surfaces the
//  marker labels (e.g. "HEAD ↔ feature-branch") so the user
//  knows what they're choosing between.
//
//  Pure AppKit — kept out of the Coordinator extension so the
//  banner's layout / styling is testable in isolation and so
//  Coordinator+MergeConflict.swift stays focused on the
//  Scintilla glue.
//

import AppKit

/// Resolution callback shape — the banner just reports the
/// choice; the Coordinator owns the SCI_REPLACETARGET path.
typealias MergeConflictBannerAction = (MergeConflictChoice) -> Void

final class MergeConflictBannerView: NSView {

    /// Snapshot of the conflict at banner-creation time. Used by
    /// the Coordinator's resolution path to look the live block
    /// up again (in case throttled SCN_MODIFIED hasn't synced
    /// `doc.text` yet) and to compute the banner's y-position
    /// from `conflict.startLine`.
    let conflict: MergeConflict

    private let onAccept: MergeConflictBannerAction
    private let onCompare: () -> Void
    private let stack = NSStackView()
    private let label = NSTextField(labelWithString: "")

    /// Shared height — banner sits in a single row above the
    /// `<<<<<<<` marker. 26pt matches Scintilla's default
    /// `SCI_TEXTHEIGHT` plus a touch of padding so the banner
    /// reads as a peer of source lines without crowding them.
    static let bannerHeight: CGFloat = 26

    init(conflict: MergeConflict,
         onAccept: @escaping MergeConflictBannerAction,
         onCompare: @escaping () -> Void) {
        self.conflict = conflict
        self.onAccept = onAccept
        self.onCompare = onCompare
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.92).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        configureLabel()
        configureStack()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Layout

    private func configureLabel() {
        let current = conflict.currentLabel.isEmpty ? "ours" : conflict.currentLabel
        let incoming = conflict.incomingLabel.isEmpty ? "theirs" : conflict.incomingLabel
        // Format: "ours ↔ theirs". A two-arrow glyph reads as
        // "between two sides" without needing localised verbs.
        label.stringValue = "\(current) ↔ \(incoming)"
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureStack() {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8,
                                        bottom: 2, right: 8)

        let acceptCurrent = makeButton(
            titleKey: "merge.conflict.button.acceptCurrent",
            action: #selector(handleAcceptCurrent))
        let acceptIncoming = makeButton(
            titleKey: "merge.conflict.button.acceptIncoming",
            action: #selector(handleAcceptIncoming))
        let acceptBoth = makeButton(
            titleKey: "merge.conflict.button.acceptBoth",
            action: #selector(handleAcceptBoth))
        let compare = makeButton(
            titleKey: "merge.conflict.button.compare",
            action: #selector(handleCompare))

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(NSView()) // spacer pushes buttons right
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(acceptCurrent)
        stack.addArrangedSubview(acceptIncoming)
        stack.addArrangedSubview(acceptBoth)
        stack.addArrangedSubview(compare)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeButton(titleKey: String, action: Selector) -> NSButton {
        let title = L10n.t(titleKey)
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    // MARK: - Actions

    @objc private func handleAcceptCurrent() { onAccept(.current) }
    @objc private func handleAcceptIncoming() { onAccept(.incoming) }
    @objc private func handleAcceptBoth() { onAccept(.both) }
    @objc private func handleCompare() { onCompare() }
}
