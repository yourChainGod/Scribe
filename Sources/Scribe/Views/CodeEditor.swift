//
//  CodeEditor.swift
//  An NSTextView-backed editor with line numbers and current-line highlight.
//  Phase 0.1 — bridge to AppKit until Scintilla lands in Phase 1.
//

import SwiftUI
import AppKit

struct CodeEditor: NSViewRepresentable {
    @ObservedObject var doc: Document
    @ObservedObject var prefs: EditorPreferences

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let tv = scroll.documentView as! NSTextView
        context.coordinator.attach(textView: tv)
        configure(tv, context: context)

        // Line-number ruler
        scroll.verticalRulerView = LineNumberRuler(textView: tv)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        // Initial cursor sync
        context.coordinator.syncCursorPosition(tv)

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        // Avoid re-pushing text on every typing tick.
        if tv.string != doc.text {
            let selected = tv.selectedRange()
            tv.string = doc.text
            tv.setSelectedRange(NSRange(location: min(selected.location, doc.text.utf16.count), length: 0))
            context.coordinator.syncCursorPosition(tv)
        }
        let font = prefs.resolvedFont()
        if tv.font != font {
            tv.font = font
            tv.typingAttributes = Self.typingAttributes(font: font, tabWidth: prefs.tabWidth)
            tv.defaultParagraphStyle = Self.paragraphStyle(font: font, tabWidth: prefs.tabWidth)
            applyParagraphStyleToWholeDocument(tv, font: font, tabWidth: prefs.tabWidth)
        }
        (scroll.verticalRulerView as? LineNumberRuler)?.fontSize = prefs.fontSize
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

        let font = prefs.resolvedFont()
        tv.font = font
        tv.string = doc.text
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.usesAdaptiveColorMappingForDarkAppearance = true

        let style = Self.paragraphStyle(font: font, tabWidth: prefs.tabWidth)
        tv.defaultParagraphStyle = style
        tv.typingAttributes = Self.typingAttributes(font: font, tabWidth: prefs.tabWidth)
        applyParagraphStyleToWholeDocument(tv, font: font, tabWidth: prefs.tabWidth)
    }

    // MARK: - Paragraph / typing attributes

    private static func paragraphStyle(font: NSFont, tabWidth: Int) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = tabAdvance(font: font, tabWidth: tabWidth)
        return style
    }

    private static func typingAttributes(font: NSFont, tabWidth: Int) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle(font: font, tabWidth: tabWidth)
        ]
    }

    private static func tabAdvance(font: NSFont, tabWidth: Int) -> CGFloat {
        let sample = " " as NSString
        let width = sample.size(withAttributes: [.font: font]).width
        return width * CGFloat(tabWidth)
    }

    private func applyParagraphStyleToWholeDocument(_ tv: NSTextView,
                                                    font: NSFont,
                                                    tabWidth: Int) {
        guard let storage = tv.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        let style = Self.paragraphStyle(font: font, tabWidth: tabWidth)
        storage.beginEditing()
        storage.addAttribute(.paragraphStyle, value: style, range: range)
        storage.addAttribute(.font, value: font, range: range)
        storage.endEditing()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?

        init(_ p: CodeEditor) { self.parent = p }

        func attach(textView: NSTextView) {
            self.textView = textView
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newText = tv.string
            if parent.doc.text != newText {
                parent.doc.text = newText
                parent.doc.isDirty = true
            }
            syncCursorPosition(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            syncCursorPosition(tv)
        }

        // Soft-tab: replace the Tab key with N spaces when prefs.softTabs is on.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) && parent.prefs.softTabs {
                let spaces = String(repeating: " ", count: parent.prefs.tabWidth)
                if textView.shouldChangeText(in: textView.selectedRange(),
                                             replacementString: spaces) {
                    textView.replaceCharacters(in: textView.selectedRange(),
                                               with: spaces)
                    textView.didChangeText()
                }
                return true
            }
            return false
        }

        @MainActor
        func syncCursorPosition(_ tv: NSTextView) {
            let (line, col) = Self.lineColumn(in: tv.string, location: tv.selectedRange().location)
            if parent.doc.cursorLine != line { parent.doc.cursorLine = line }
            if parent.doc.cursorColumn != col { parent.doc.cursorColumn = col }
        }

        /// 1-indexed line and column from a UTF-16 offset.
        static func lineColumn(in text: String, location: Int) -> (Int, Int) {
            let nsText = text as NSString
            let clamped = max(0, min(location, nsText.length))
            var line = 1
            var lineStart = 0
            var i = 0
            while i < clamped {
                if nsText.character(at: i) == 0x0A { // '\n'
                    line += 1
                    lineStart = i + 1
                }
                i += 1
            }
            let column = clamped - lineStart + 1
            return (line, column)
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
