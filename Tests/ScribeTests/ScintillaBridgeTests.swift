//
//  ScintillaBridgeTests.swift
//  Phase 1.6 — Compile-time confirmation that the SwiftPM-vendored Scintilla
//  module imports cleanly and exposes the headline ObjC types to Swift.
//
//  We do NOT instantiate ScintillaView from xctest: ScintillaView's -init
//  reaches into NSCursor which segfaults under xctest's headless environment
//  (no NSApp). Real instantiation is exercised by the in-app probe (see
//  Sources/Scribe/Views/ScintillaProbe.swift) and by booting Scribe.app.
//

import XCTest
@testable import Scribe
import Scintilla

final class ScintillaBridgeTests: XCTestCase {

    /// If this file compiles, Swift could resolve the Scintilla module map and
    /// the umbrella header, which is the part most likely to break across
    /// Scintilla upstream releases.
    func testTypesAreReachable() {
        let viewType: AnyClass = ScintillaView.self
        XCTAssertEqual(NSStringFromClass(viewType), "ScintillaView")
    }

    /// Sanity: ScintillaProbe entry point exists and is callable from Swift.
    /// We don't actually invoke makeView() here for the reasons in the file
    /// header — only check the metatype.
    func testProbeFactoryIsExposed() {
        XCTAssertEqual(String(describing: ScintillaProbe.self), "ScintillaProbe")
    }
}
