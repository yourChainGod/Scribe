//
//  ChunkedFileReaderTests.swift
//  Phase 34a — guarantees the chunked iterator hands every byte to
//  the consumer exactly once, in order, with no String materialisation
//  on the way through. These properties matter because the loader on
//  the other side appends bytes blindly — anything we drop or dup
//  ends up in Scintilla's buffer the same way.
//

import XCTest
@testable import Scribe

final class ChunkedFileReaderTests: XCTestCase {

    /// Per-test sandbox in the OS temp dir. Cleaned up in tearDown
    /// so a failing test can't leak into a sibling.
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-cfr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        sandbox = dir
    }

    override func tearDown() {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func write(_ bytes: [UInt8], filename: String = "test.bin") -> URL {
        let url = sandbox.appendingPathComponent(filename)
        try? Data(bytes).write(to: url)
        return url
    }

    /// Read every chunk into memory and concatenate. Matches what the
    /// production loader pipeline produces minus the Scintilla side.
    private func readAll(_ reader: ChunkedFileReader) throws -> Data {
        var seen = Data()
        try reader.forEachChunk { chunk in
            seen.append(chunk)
            return true
        }
        return seen
    }

    // MARK: - File size

    func test_fileSize_reportsActualSize() {
        let url = write(Array(repeating: 0x41 as UInt8, count: 5_000))
        let reader = ChunkedFileReader(url: url)
        XCTAssertEqual(reader.fileSize(), 5_000)
    }

    func test_fileSize_missingFile_returnsZero() {
        let reader = ChunkedFileReader(
            url: sandbox.appendingPathComponent("does-not-exist.bin"))
        XCTAssertEqual(reader.fileSize(), 0)
    }

    // MARK: - Iteration shape

    func test_emptyFile_yieldsNoChunks() throws {
        let url = write([])
        var calls = 0
        try ChunkedFileReader(url: url).forEachChunk { _ in
            calls += 1
            return true
        }
        XCTAssertEqual(calls, 0)
    }

    func test_singleChunkFile_yieldsExactlyOneChunk() throws {
        // Way smaller than chunkSize ⇒ one slice.
        let payload = Array("hello world".utf8)
        let url = write(payload)
        var seen: [Data] = []
        try ChunkedFileReader(url: url, chunkSize: 64 * 1024)
            .forEachChunk { chunk in
                seen.append(chunk)
                return true
            }
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0], Data(payload))
    }

    func test_multiChunkFile_concatenationEqualsOriginal() throws {
        // 5 chunks: bytes 0…3999. Pick a chunk size that doesn't
        // divide evenly so the last slice exercises the partial path.
        var payload: [UInt8] = []
        for i in 0..<4_000 { payload.append(UInt8(i & 0xFF)) }
        let url = write(payload)
        let reader = ChunkedFileReader(url: url, chunkSize: 700)
        let merged = try readAll(reader)
        XCTAssertEqual(merged, Data(payload))
    }

    func test_chunkSize_floorsAt4KiB() throws {
        // Even a tiny request gets clamped — protects callers from
        // pathologically thrashing the AddData round-trip on every
        // 100-byte chunk.
        let payload = Array(repeating: UInt8(0x5A), count: 8_192)
        let url = write(payload)
        let reader = ChunkedFileReader(url: url, chunkSize: 100)
        var sizes: [Int] = []
        try reader.forEachChunk { sizes.append($0.count); return true }
        XCTAssertGreaterThanOrEqual(sizes.first ?? 0, 4_096,
            "chunk size should be clamped to ≥ 4 KiB")
    }

    // MARK: - Early termination

    func test_returningFalse_stopsIteration() throws {
        let payload = Array(repeating: UInt8(0x42), count: 50_000)
        let url = write(payload)
        var calls = 0
        try ChunkedFileReader(url: url, chunkSize: 4_096)
            .forEachChunk { _ in
                calls += 1
                return false  // stop after the first chunk
            }
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Errors

    func test_unreadablePath_throwsMappingFailed() {
        let url = sandbox.appendingPathComponent("nope.bin")
        XCTAssertThrowsError(
            try ChunkedFileReader(url: url).forEachChunk { _ in true }
        ) { err in
            guard case ChunkedFileReaderError.mappingFailed = err else {
                XCTFail("expected mappingFailed, got \(err)")
                return
            }
        }
    }
}
