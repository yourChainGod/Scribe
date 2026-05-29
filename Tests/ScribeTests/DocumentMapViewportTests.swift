//
//  DocumentMapViewportTests.swift
//  Phase 64 — guardrails around the minimap viewport overlay's
//  state surface. Behavioural coverage of the pixel-space rectangle
//  painting lives in the manual-QA path (it needs a live
//  ScintillaView with real line layout, same constraint as the
//  Phase 56 click-to-jump tests). These tests lock down:
//    1. `Document.viewportBottomLine` exists, defaults sensibly,
//       and is `@Published`.
//    2. `DocumentMapViewportOverlay.update(topY:height:)` is
//       idempotent — identical values don't schedule redundant
//       redraws, changed values do.
//    3. `hitTest(_:)` returns nil so clicks pass through to the
//       Scintilla sibling (preserves the Phase 56 click-to-jump).
//

import Combine
import XCTest
@testable import Scribe

@MainActor
final class DocumentMapViewportTests: XCTestCase {

    // MARK: - Document publishing contract

    func test_document_hasDefaultViewportBottomLine() {
        let doc = Document(title: "x.swift", text: "")
        XCTAssertEqual(doc.viewport.viewportBottomLine, 1,
                       "default must be 1 so the overlay can start as a thin strip before V_SCROLL fires")
    }

    /// Publishing `viewportBottomLine` drives SwiftUI `updateNSView`
    /// ticks on DocumentMapPane, which in turn repaints the overlay
    /// rectangle. Confirm the property is actually `@Published`.
    func test_document_viewportBottomLine_isPublished() {
        let doc = Document(title: "x.swift", text: "")
        var observed: [Int] = []
        let sub = doc.viewport.$viewportBottomLine.sink { observed.append($0) }
        doc.viewport.viewportBottomLine = 1        // initial publish
        doc.viewport.viewportBottomLine = 42       // changed publish
        doc.viewport.viewportBottomLine = 42       // same value
        // First publish mirrors the @Published default; the 42
        // assignment has to land at least once for SwiftUI to pick
        // up the change.
        XCTAssertTrue(observed.contains(1),
                      "initial publish missing; got \(observed)")
        XCTAssertTrue(observed.contains(42),
                      "change publish missing; got \(observed)")
        sub.cancel()
    }

    // MARK: - Overlay update contract

    func test_overlay_update_ignoresIdenticalValues() {
        let overlay = DocumentMapViewportOverlay(frame: NSRect(x: 0,
                                                               y: 0,
                                                               width: 120,
                                                               height: 400))
        // First call lands the state transition.
        XCTAssertTrue(overlay.update(topY: 10, height: 80),
                      "first call with new values must report a change")
        XCTAssertEqual(overlay.currentTopY, 10)
        XCTAssertEqual(overlay.currentHeight, 80)

        // Re-invoke with the same values — should NOT flip
        // needsDisplay back on.
        XCTAssertFalse(overlay.update(topY: 10, height: 80),
                       "identical update must be a no-op (prevents flicker)")
    }

    func test_overlay_update_schedulesRedrawOnChange() {
        let overlay = DocumentMapViewportOverlay(frame: NSRect(x: 0,
                                                               y: 0,
                                                               width: 120,
                                                               height: 400))
        overlay.update(topY: 0, height: 0)
        XCTAssertTrue(overlay.update(topY: 42, height: 80),
                      "changed update must report that it mutated state")
        XCTAssertEqual(overlay.currentTopY, 42)
        XCTAssertEqual(overlay.currentHeight, 80)
    }

    // MARK: - Click-through contract

    /// The overlay must be transparent to mouse events — clicks
    /// inside the rectangle have to fall through to the
    /// ScintillaView sibling so the Phase 56 click-to-jump monitor
    /// still sees them. A non-nil return from hitTest would make
    /// the overlay absorb the click.
    func test_overlay_hitTest_returnsNil() {
        let overlay = DocumentMapViewportOverlay(frame: NSRect(x: 0,
                                                               y: 0,
                                                               width: 120,
                                                               height: 400))
        XCTAssertNil(overlay.hitTest(NSPoint(x: 10, y: 20)),
                     "overlay must pass mouse events through to Scintilla")
        XCTAssertNil(overlay.hitTest(NSPoint(x: 60, y: 200)),
                     "hitTest must be nil regardless of location")
    }

    // MARK: - Container wiring contract
    //
    // Constructing `DocumentMapContainerView` in the test harness
    // recursively constructs a `ScintillaView`, which in turn
    // reaches into AppKit for cursor / notification plumbing that
    // isn't available in a headless XCTest bundle (fails with
    // "Wait cursor is invalid."). Container + ScintillaView
    // integration coverage therefore lives in the manual-QA path,
    // alongside the Phase 56 click-to-jump and rendering checks.
}
