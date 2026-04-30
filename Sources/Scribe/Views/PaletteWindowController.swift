//
//  PaletteWindowController.swift
//  Phase 3 — host the SwiftUI CommandPalette inside a borderless NSPanel.
//  Centres horizontally near the top of the active screen, dismisses on
//  Esc / loss of key status / pick.
//

import AppKit
import SwiftUI

@MainActor
final class PaletteWindowController: NSObject, NSWindowDelegate {
    static let shared = PaletteWindowController()
    static let panelStyleMask: NSWindow.StyleMask = [
        .borderless,
        .fullSizeContentView
    ]
    static let panelSize = NSSize(width: CommandPaletteMetrics.width, height: 292)
    static let isFloatingPanel = false
    static let panelLevel: NSWindow.Level = .normal
    static let topOffsetFromKeyWindow: CGFloat = 56
    static let screenPadding: CGFloat = 18

    private var panel: NSPanel?
    private weak var registry: CommandRegistry?

    /// Show the palette. If a panel is already up against a *different*
    /// registry (e.g. ⌘⇧P → ⌘P switch), rebuild it so the new commands
    /// take effect; same registry just refocuses.
    /// `initialQuery` pre-fills the search field; production callers
    /// leave it empty, automated tests use it to drive the panel
    /// without simulating keystrokes.
    func show(registry: CommandRegistry,
              placeholder: String = L10n.t("palette.placeholder.commands"),
              initialQuery: String = "") {
        if let panel = panel, panel.isVisible, registry === self.registry {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        if panel != nil { hide() }
        self.registry = registry
        let panel = makePanel(registry: registry,
                              placeholder: placeholder,
                              initialQuery: initialQuery)
        self.panel = panel

        if let screenFrame = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame {
            let panelSize = panel.frame.size
            panel.setFrameOrigin(Self.panelOrigin(panelSize: panelSize,
                                                  screenFrame: screenFrame,
                                                  keyWindowFrame: NSApp.keyWindow?.frame))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel?.contentView = nil
        panel = nil
    }

    /// Toggle for menu bindings. When the panel is up against the same
    /// registry, hide it; otherwise (closed, or showing a different
    /// registry) show with the requested registry.
    func toggle(registry: CommandRegistry,
                placeholder: String = L10n.t("palette.placeholder.commands")) {
        if let panel = panel, panel.isVisible, registry === self.registry {
            hide()
        } else {
            show(registry: registry, placeholder: placeholder)
        }
    }

    // MARK: - NSWindowDelegate

    /// Auto-dismiss when the panel loses key. macOS gives us this for
    /// free with `NSPanel.becomesKeyOnlyIfNeeded = false` — clicking
    /// elsewhere quietly closes the palette.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in self.hide() }
    }

    // MARK: - Plumbing

    private func makePanel(registry: CommandRegistry,
                           placeholder: String,
                           initialQuery: String = "") -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: Self.panelStyleMask,
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = Self.isFloatingPanel
        panel.level = Self.panelLevel
        panel.backgroundColor = .clear
        panel.hasShadow = false       // shadow is drawn by the SwiftUI view
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let view = CommandPalette(
            registry: registry,
            placeholder: placeholder,
            initialQuery: initialQuery,
            onPick: { [weak self] command in
                self?.hide()
                registry.invoke(command)
            },
            onCancel: { [weak self] in self?.hide() }
        )
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        // Let the SwiftUI view dictate height; the panel resizes to fit.
        let container = NSView(frame: panel.contentLayoutRect)
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        panel.contentView = container
        return panel
    }

    static func panelOrigin(panelSize: NSSize,
                            screenFrame: NSRect,
                            keyWindowFrame: NSRect?) -> NSPoint {
        let anchor = keyWindowFrame ?? screenFrame
        let rawX = anchor.midX - panelSize.width / 2
        let x = min(max(rawX, screenFrame.minX + screenPadding),
                    screenFrame.maxX - panelSize.width - screenPadding)
        let rawY = anchor.maxY - topOffsetFromKeyWindow - panelSize.height
        let y = min(max(rawY, screenFrame.minY + screenPadding),
                    screenFrame.maxY - panelSize.height - screenPadding)
        return NSPoint(x: x, y: y)
    }
}
