//
//  InlineBlameTooltipPresenter.swift
//  In-editor tooltip surface for inline blame details.
//

import AppKit
import Scintilla

enum InlineBlameTooltipPresenter {
    static let edgeInset: CGFloat = 8
    static let anchorOffset = NSSize(width: 8, height: 6)
    static let maxWidth: CGFloat = 340

    static func frame(anchor: NSPoint,
                      preferredSize: NSSize,
                      in bounds: NSRect) -> NSRect {
        let availableWidth = max(0, bounds.width - edgeInset * 2)
        let availableHeight = max(0, bounds.height - edgeInset * 2)
        let width = min(preferredSize.width, maxWidth, availableWidth)
        let height = min(preferredSize.height, availableHeight)
        let minX = bounds.minX + edgeInset
        let minY = bounds.minY + edgeInset
        let maxX = max(minX, bounds.maxX - edgeInset - width)
        let maxY = max(minY, bounds.maxY - edgeInset - height)
        let x = min(max(minX, anchor.x), maxX)
        let y = min(max(minY, anchor.y), maxY)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    @discardableResult
    @MainActor
    static func show(text: String,
                     position: Int,
                     line0: Int,
                     in view: ScintillaView,
                     replacing existing: NSView?) -> NSView {
        dismissNativeCalltip(in: view)

        let bubble: InlineBlameTooltipBubble
        if let existing = existing as? InlineBlameTooltipBubble {
            bubble = existing
            bubble.update(text: text)
        } else {
            existing?.removeFromSuperview()
            bubble = InlineBlameTooltipBubble(text: text)
        }

        if bubble.superview !== view {
            view.addSubview(bubble)
        }

        let x = CGFloat(view.message(SCI.POINTXFROMPOSITION,
                                     wParam: 0,
                                     lParam: position))
        let y = CGFloat(view.message(SCI.POINTYFROMPOSITION,
                                     wParam: 0,
                                     lParam: position))
        let lineHeight = CGFloat(view.message(SCI.TEXTHEIGHT,
                                              wParam: UInt(max(0, line0))))
        let anchor = NSPoint(x: x + anchorOffset.width,
                             y: y + lineHeight + anchorOffset.height)
        bubble.frame = frame(anchor: anchor,
                             preferredSize: bubble.fittingSize,
                             in: view.bounds)
        return bubble
    }

    @MainActor
    static func hide(_ tooltipView: NSView?, in view: ScintillaView) {
        tooltipView?.removeFromSuperview()
        dismissNativeCalltip(in: view)
    }

    @MainActor
    private static func dismissNativeCalltip(in view: ScintillaView) {
        view.message(SCI.CALLTIPCANCEL)
        view.message(SCI.CANCEL)
    }
}

private final class InlineBlameTooltipBubble: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        label.preferredMaxLayoutWidth = InlineBlameTooltipPresenter.maxWidth - 20
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])

        update(text: text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(text: String) {
        label.stringValue = text
        needsLayout = true
    }
}
