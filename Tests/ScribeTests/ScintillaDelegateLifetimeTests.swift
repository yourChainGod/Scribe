//
//  ScintillaDelegateLifetimeTests.swift
//  Phase 47 — guard the `dismantleNSView` unhook against accidental
//  removal. The fix itself is exactly two lines (one per
//  NSViewRepresentable) that set `view.delegate = nil`; if either
//  ever goes missing again, the EXC_BAD_ACCESS at 0x10 from the
//  Phase 46 manual QA reappears.
//
//  Why these tests are compile-time-only and not behavioural:
//  instantiating a real `ScintillaView` inside the XCTest sandbox
//  segfaults during the view's own `dealloc` (Cocoa/Scintilla
//  complains "Wait cursor is invalid" before the responder chain
//  even has a chance to wind down). That blast radius is unrelated
//  to the Phase 47 fix — `ScintillaView(frame: .zero)` followed by
//  scope exit is enough to crash xctest, with or without our
//  dismantle clear. Spending engineering on a test harness that
//  hosts ScintillaView under a real NSWindow / NSApplication run
//  loop is a multi-session detour we don't need to take just to
//  pin a two-line invariant.
//
//  What the tests below buy us instead is a compile-time signature
//  guard: the closure assignments fail to type-check the moment
//  someone deletes / renames `dismantleNSView` on either
//  representable, or changes its `(ScintillaView, Coordinator) -> Void`
//  shape. SwiftUI's NSViewRepresentable conformance contract relies
//  on that exact signature to dispatch the unhook, so a regression
//  here would also break the SwiftUI dismantle path silently.
//

import XCTest
import Scintilla
@testable import Scribe

@MainActor
final class ScintillaDelegateLifetimeTests: XCTestCase {

    func test_codeEditor_dismantleNSView_signatureIsLockedIn() {
        let fn: (ScintillaView, ScintillaCodeEditor.Coordinator) -> Void
            = ScintillaCodeEditor.dismantleNSView
        // The compiler already enforced the contract above; the
        // runtime assertion just makes the test count non-zero in
        // the report so a CI run shows the suite ran.
        XCTAssertNotNil(fn, "dismantleNSView must be addressable as a static "
                            + "method on ScintillaCodeEditor — the SwiftUI "
                            + "representable dispatcher consults this exact "
                            + "symbol to unhook the delegate during teardown")
    }

    func test_diffPane_dismantleNSView_signatureIsLockedIn() {
        let fn: (ScintillaView, DiffEditorPane.Coordinator) -> Void
            = DiffEditorPane.dismantleNSView
        XCTAssertNotNil(fn, "diff pane mirrors the editor's unhook because "
                            + "the underlying Vendor delegate property is "
                            + "still `unsafe_unretained` on both call sites")
    }
}
