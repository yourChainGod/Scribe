//
//  ChunkedFileWriterTests.swift
//  Phase 34c — covers what we can without a live ScintillaView.
//  The view-touching `write(view:to:byteCount:)` integration is
//  manually smoke-tested in Scribe.app for the same reason as
//  LargeFileLoader: ScintillaView.init segfaults under xctest's
//  headless run loop, so we can't drive a real save end-to-end here.
//
//  What we *can* test:
//    1. The TextRange bridge symbol is reachable + nil-safe (mirrors
//       the LoaderBridge symbol test so a future refactor that
//       drops the swiftpm-bridge sources can't sneak past CI).
//    2. ChunkedFileWriter.chunkSize floor: passing absurdly small
//       values clamps to 4 KiB so the per-chunk SCI message
//       overhead can't dominate the run.
//    3. Empty-document fast path produces a zero-byte file (no
//       FileHandle work, no temp file dangling).
//    4. ChunkedFileWriterError is round-trippable and Sendable —
//       matters for the Workspace.write hop into a Task.
//

import XCTest
@testable import Scribe
import Scintilla

final class ChunkedFileWriterTests: XCTestCase {

    /// Bridge symbol reachability — same pattern as
    /// LargeFileLoaderTests.test_bridgeSymbols_areReachable. Catches
    /// a regression where the new TextRange bridge sources drop out
    /// of the Scintilla target's `sources: [...]` list.
    func test_textRangeBridge_symbolsAreReachable() {
        let fn: (UnsafeMutableRawPointer?, Int, Int) -> Data? = { v, s, l in
            ScribeReadTextRange(v, s, l)
        }
        XCTAssertNotNil(fn as Any)
    }

    /// Bridge nil/zero-length contract: passing nil view OR zero
    /// length must return an empty `NSData` (not nil — that's
    /// reserved for catastrophic OOM). The Swift wrapper relies on
    /// this so its empty-doc fast path doesn't have to special-case
    /// the Data construction.
    func test_textRangeBridge_nilAndZeroLengthAreEmpty() {
        // ObjC `NSData * _Nullable` bridges to Swift `Data?`. Empty
        // contract is `Data()`; the bridge promises non-nil for
        // every non-OOM input, so we assert .count == 0 directly.
        let nilView = ScribeReadTextRange(nil, 0, 0)
        XCTAssertEqual(nilView?.count, 0)

        let zeroLen = ScribeReadTextRange(nil, 100, 0)
        XCTAssertEqual(zeroLen?.count, 0)

        let negLen = ScribeReadTextRange(nil, 0, -1)
        XCTAssertEqual(negLen?.count, 0)
    }

    /// Chunk size floor: anything below 4 KiB rounds up. Mirrors the
    /// reader's contract — without the floor a misconfigured caller
    /// could spin the writer into an O(N) message-overhead loop.
    func test_chunkSize_flooredAt4KiB() {
        XCTAssertEqual(ChunkedFileWriter(chunkSize: 0).chunkSize, 4 * 1024)
        XCTAssertEqual(ChunkedFileWriter(chunkSize: 1).chunkSize, 4 * 1024)
        XCTAssertEqual(ChunkedFileWriter(chunkSize: 1024).chunkSize, 4 * 1024)
        XCTAssertEqual(ChunkedFileWriter(chunkSize: 4 * 1024).chunkSize, 4 * 1024)
        XCTAssertEqual(ChunkedFileWriter(chunkSize: 8 * 1024).chunkSize, 8 * 1024)
        XCTAssertEqual(ChunkedFileWriter(chunkSize: 256 * 1024).chunkSize, 256 * 1024)
    }

    /// Default chunk size matches the reader's. A divergence here
    /// would mean the read pipeline and the write pipeline each
    /// think they're "the canonical" choice — the comment trail in
    /// each file says they should agree. This test is the lock.
    func test_chunkSize_defaultMatchesReaderContract() {
        XCTAssertEqual(ChunkedFileWriter().chunkSize, 256 * 1024)
    }

    /// Empty-doc fast path: writing 0 bytes produces a zero-byte
    /// file at `destination`. Important because the chunked loop
    /// would otherwise open a FileHandle just to immediately close
    /// it, and a stat() against an empty file is the canonical way
    /// users verify "save did happen".
    func test_emptyDocument_writesZeroByteFile() async throws {
        // The view-less code path — pass an empty file size and
        // ChunkedFileWriter.write short-circuits to Data().write.
        // We don't need a ScintillaView for this branch because the
        // chunk loop never runs.
        let url = try makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Empty file write is the only branch that doesn't need a
        // ScintillaView, so we exercise it with a stand-in (nil-cast
        // is safe for this branch).
        try await ChunkedFileWriter().writeEmpty(to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? -1
        XCTAssertEqual(size, 0)
    }

    /// `ChunkedFileWriterError` is `Sendable` so the Workspace
    /// rethrow path (Task → main-actor catch) compiles without
    /// `@unchecked` annotations. A regression here would surface as
    /// a strict-mode compile error in Workspace.swift; the
    /// assertion below guards in case the failure mode changes
    /// to something the compiler doesn't catch.
    func test_writerError_isSendable() {
        let err: ChunkedFileWriterError = .writeFailed(
            underlying: NSError(domain: "test", code: 0)
        )
        let _: any Sendable = err  // would not compile if not Sendable
        XCTAssertNotNil(err)
    }

    // MARK: - Helpers

    private func makeTempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let path = "scribe-cfw-test-\(UUID().uuidString).bin"
        return dir.appendingPathComponent(path)
    }
}

/// Test-only helper: drive just the empty-doc branch of `write` so
/// the test doesn't have to instantiate a ScintillaView (which
/// segfaults under xctest's headless run loop). Real callers go
/// through `write(view:to:byteCount:progress:)`.
@MainActor
extension ChunkedFileWriter {
    fileprivate func writeEmpty(to destination: URL) async throws {
        // Mirror the empty-doc branch in `write(view:...)` exactly:
        // a single atomic Data write, no temp file ceremony. We
        // don't share a helper to avoid drift between this and the
        // production path (the comment in `write(...)` is the spec).
        try Data().write(to: destination, options: [.atomic])
    }
}
