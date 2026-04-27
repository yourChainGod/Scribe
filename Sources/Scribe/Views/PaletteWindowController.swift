//
//  PaletteWindowController.swift
//  Phase 3 — host the SwiftUI CommandPalette inside a borderless NSPanel
//  that floats above the main window. Centres horizontally near the top
//  of the active screen, dismisses on Esc / loss of key status / pick.
//

import AppKit
import SwiftUI

@MainActor
final class PaletteWindowController: NSObject, NSWindowDelegate {
    static let shared = PaletteWindowController()

    private var panel: NSPanel?
    private weak var registry: CommandRegistry?

    /// Show the palette. If a panel is already up against a *different*
    /// registry (e.g. ⌘⇧P → ⌘P switch), rebuild it so the new commands
    /// take effect; same registry just refocuses.
    /// `initialQuery` pre-fills the search field; production callers
    /// leave it empty, automated tests use it to drive the panel
    /// without simulating keystrokes.
    func show(registry: CommandRegistry,
              placeholder: String = "Type a command…",
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
            // Centred horizontally, ~25% from the top of the visible screen.
            let x = screenFrame.midX - panelSize.width / 2
            let y = screenFrame.maxY - panelSize.height - screenFrame.height * 0.25
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
                placeholder: String = "Type a command…") {
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
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
}
