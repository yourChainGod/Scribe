//
//  LargeFileLoaderTests.swift
//  Phase 34a — symbol-reachability tests for the loader plumbing.
//  Live ILoader integration cannot run from xctest because
//  `ScintillaView.init` reaches into NSCursor and crashes under the
//  headless test environment (same constraint documented on
//  ScintillaBridgeTests). We exercise the live path manually by
//  booting Scribe.app and opening a large file when Phase 34b wires
//  the loader into Workspace.openFile.
//
//  What we *can* lock in here:
//    1. ScribeLoader* shim symbols compile + link from Swift, so a
//       refactor can't silently drop the bridge sources from the
//       Scintilla target's `sources: […]` list.
//    2. ScribeLoaderRelease(nil) is a defensive no-op (the bridge
//       guards against nil internally; this proves it works at the
//       Swift / ObjC bridge boundary too).
//    3. ScribeLoaderAddData(nil, …) returns a non-success status
//       without crashing — Swift wrapper relies on this for its
//       defensive path when init fails.
//

import XCTest
@testable import Scribe
import Scintilla

final class LargeFileLoaderTests: XCTestCase {

    /// Catches the regression where the swiftpm-bridge directory drops
    /// out of the Scintilla target's `sources` list — the Swift
    /// compiler silently treats unresolved C symbols as a link error
    /// at the executable target, but a renamed type would hide here.
    func test_bridgeSymbols_areReachable() {
        let releaseFn: (UnsafeMutableRawPointer?) -> Void = ScribeLoaderRelease
        let addFn: (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int) -> Int32 = { p, b, n in
            Int32(ScribeLoaderAddData(p, b, n))
        }
        let convertFn: (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? = ScribeLoaderConvertToDocument
        // Swallow them so the optimizer can't elide the references.
        XCTAssertNotNil(releaseFn as Any)
        XCTAssertNotNil(addFn as Any)
        XCTAssertNotNil(convertFn as Any)
    }

    func test_bridgeNilGuards_defensiveNoOp() {
        // Bridge promises: passing nil is safe, returns a sentinel
        // (-1 for AddData / nil for Convert / no-op for Release).
        ScribeLoaderRelease(nil)                       // must not crash
        let addStatus = ScribeLoaderAddData(nil, nil, 0)
        XCTAssertNotEqual(addStatus, 0,
            "AddData(nil) should report a non-success status")
        XCTAssertNil(ScribeLoaderConvertToDocument(nil))
    }
}
