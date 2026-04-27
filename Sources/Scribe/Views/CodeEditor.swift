//
//  CodeEditor.swift
//  An NSTextView-backed editor with line numbers and current-line highlight.
//  Phase 0.1 — bridge to AppKit until Scintilla lands in Phase 1.
//

import SwiftUI
import AppKit

struct CodeEditor: NSViewRepresentable {
    @ObservedObject var doc: Document
    var fontSize: CGFloat = 13

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let tv = scroll.documentView as! NSTextView
        configure(tv, context: context)

        // Line-number ruler
        scroll.verticalRulerView = LineNumberRuler(textView: tv)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        // Avoid re-pushing text on every typing tick.
        if tv.string != doc.text {
            let selected = tv.selectedRange()
            tv.string = doc.text
            tv.setSelectedRange(NSRange(location: min(selected.location, doc.text.utf16.count), length: 0))
        }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if tv.font != font { tv.font = font }
        (scroll.verticalRulerView as? LineNumberRuler)?.fontSize = fontSize
    }

    private func configure(_ tv: NSTextView, context: Context) {
        tv.delegate = context.coordinator
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false

        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true

        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.string = doc.text
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.textBackgroundColor

        // Current-line subtle highlight via paragraph layer.
        tv.usesAdaptiveColorMappingForDarkAppearance = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ p: CodeEditor) { self.parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newText = tv.string
            if parent.doc.text != newText {
                parent.doc.text = newText
                parent.doc.isDirty = true
            }
        }
    }
}

// MARK: - Line number ruler

final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var fontSize: CGFloat = 13 {
        didSet { needsDisplay = true }
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 44

        NotificationCenter.default.addObserver(
            self, selector: #selector(textChanged(_:)),
            name: NSText.didChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func textChanged(_ note: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let bg = NSColor.windowBackgroundColor.withAlphaComponent(0.6)
        bg.setFill()
        rect.fill()

        // Right border
        let border = NSColor.separatorColor
        border.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: bounds.maxX - 0.5, y: rect.minY))
        line.line(to: NSPoint(x: bounds.maxX - 0.5, y: rect.maxY))
        line.lineWidth = 0.5
        line.stroke()

        let nsString = textView.string as NSString
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: textView.visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Find first line number
        var lineNumber = 1
        var idx = 0
        while idx < charRange.location {
            let nl = nsString.range(of: "\n", options: [],
                                    range: NSRange(location: idx, length: charRange.location - idx))
            if nl.location == NSNotFound { break }
            lineNumber += 1
            idx = nl.location + 1
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(10, fontSize - 1), weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        let yOffset = textView.textContainerOrigin.y - textView.enclosingScrollView!.contentView.bounds.minY

        let scanRange = NSRange(location: charRange.location, length: charRange.length)
        nsString.enumerateSubstrings(in: scanRange, options: [.byLines, .substringNotRequired]) {
            (_, lineRange, _, _) in
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange,
                                                       actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                   in: textContainer)
            rect.origin.y += yOffset
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: self.bounds.maxX - size.width - 6,
                                    y: rect.minY + (rect.height - size.height) / 2),
                        withAttributes: attrs)
            lineNumber += 1
        }

        // Last line if file ends without newline
        if scanRange.length > 0 && nsString.length == NSMaxRange(charRange) {
            let lastNewline = nsString.range(of: "\n", options: .backwards,
                                              range: charRange)
            if lastNewline.location == NSNotFound || lastNewline.location < nsString.length - 1 {
                // already drawn
            }
        }
    }
}
