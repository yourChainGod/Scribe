//
//  ScintillaBridgeTests.swift
//  Compile-time confirmation that the SwiftPM-vendored Scintilla module
//  imports cleanly and exposes the headline ObjC types to Swift.
//
//  We do NOT instantiate ScintillaView from xctest: ScintillaView's -init
//  reaches into NSCursor which segfaults under xctest's headless environment
//  (no NSApp). Real instantiation is exercised by booting Scribe.app and
//  letting the EditorAreaView mount a ScintillaCodeEditor.
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

    /// Confirms the SwiftUI bridge struct is reachable so refactors to the
    /// view layer surface as compile errors here.
    func testScintillaCodeEditorIsExposed() {
        XCTAssertEqual(String(describing: ScintillaCodeEditor.self), "ScintillaCodeEditor")
    }
}
