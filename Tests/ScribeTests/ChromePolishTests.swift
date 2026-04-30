//
//  ChromePolishTests.swift
//  Guardrails for the custom app chrome polish pass.
//

import AppKit
import XCTest
@testable import Scribe

final class ChromePolishTests: XCTestCase {

    /// Phase 38d — chrome row spans full window width and the
    /// inset clears traffic lights regardless of sidebar state.
    func test_mainChromeLeadingInsetClearsTrafficLights() {
        XCTAssertGreaterThanOrEqual(MainWindowChromeMetrics.leadingPadding(sidebarVisible: true), 64)
        XCTAssertGreaterThanOrEqual(MainWindowChromeMetrics.leadingPadding(sidebarVisible: false), 64)
        XCTAssertLessThanOrEqual(MainWindowChromeMetrics.commandBarHeight, 40)
        XCTAssertLessThanOrEqual(MainWindowChromeMetrics.iconButtonSide, 28)
    }

    func test_sidebarModeSwitcherUsesOneQuietActiveIndicator() {
        XCTAssertEqual(SidebarModeSwitcherMetrics.iconSize, 12)
        XCTAssertFalse(SidebarModeSwitcherMetrics.usesUnderlineIndicator)
        XCTAssertLessThanOrEqual(SidebarModeSwitcherMetrics.activeBackgroundOpacity, 0.16)
    }

    /// Phase 38d — chrome row is full width and owns the
    /// traffic-light inset. Sidebar no longer has its own header
    /// row; mode tabs + collapse moved up into the chrome.
    func test_chromeBarReservesRoomForTrafficLights() {
        XCTAssertGreaterThanOrEqual(MainWindowChromeMetrics.trafficLightInset, 64)
        XCTAssertEqual(MainWindowChromeMetrics.leadingPadding(sidebarVisible: true),
                       MainWindowChromeMetrics.leadingPadding(sidebarVisible: false),
                       "Full-width chrome must use the same leading inset across sidebar states.")
    }

    func test_inlineBlameTooltipFrameIsClampedInsideEditorBounds() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let frame = InlineBlameTooltipPresenter.frame(
            anchor: NSPoint(x: 780, y: 570),
            preferredSize: NSSize(width: 280, height: 96),
            in: bounds
        )

        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX + InlineBlameTooltipPresenter.edgeInset)
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY + InlineBlameTooltipPresenter.edgeInset)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX - InlineBlameTooltipPresenter.edgeInset)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY - InlineBlameTooltipPresenter.edgeInset)
    }
}
