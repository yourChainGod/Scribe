//
//  PaletteWindowControllerTests.swift
//  Phase 36d — palette panel lifecycle guardrails.
//

import AppKit
import XCTest
@testable import Scribe

@MainActor
final class PaletteWindowControllerTests: XCTestCase {

    func test_palettePanelStyleAllowsKeyWindowFocus() {
        let styleMask = PaletteWindowController.panelStyleMask

        XCTAssertTrue(styleMask.contains(.borderless))
        XCTAssertTrue(styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(styleMask.contains(.nonactivatingPanel))
    }

    func test_palettePanelDoesNotFloatAboveOtherApps() {
        XCTAssertFalse(PaletteWindowController.isFloatingPanel)
        XCTAssertEqual(PaletteWindowController.panelLevel, .normal)
    }

    func test_palettePanelUsesSpotlightScaledMetrics() {
        XCTAssertGreaterThanOrEqual(PaletteWindowController.panelSize.width, 560)
        XCTAssertLessThanOrEqual(PaletteWindowController.panelSize.width, 620)
        XCTAssertLessThanOrEqual(PaletteWindowController.panelSize.height, 320)
        XCTAssertLessThanOrEqual(CommandPaletteMetrics.rowIconBox, 20)
        XCTAssertLessThanOrEqual(CommandPaletteMetrics.rowMinHeight, 36)
        XCTAssertLessThanOrEqual(CommandPaletteMetrics.maxListHeight, 220)
    }

    func test_palettePanelOpensNearTopOfKeyWindow() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let keyWindow = NSRect(x: 120, y: 80, width: 1080, height: 740)
        let origin = PaletteWindowController.panelOrigin(panelSize: PaletteWindowController.panelSize,
                                                         screenFrame: screen,
                                                         keyWindowFrame: keyWindow)

        XCTAssertLessThanOrEqual(PaletteWindowController.topOffsetFromKeyWindow, 64)
        XCTAssertGreaterThanOrEqual(PaletteWindowController.topOffsetFromKeyWindow, 44)
        XCTAssertEqual(origin.y + PaletteWindowController.panelSize.height,
                       keyWindow.maxY - PaletteWindowController.topOffsetFromKeyWindow,
                       accuracy: 0.5)
    }
}
