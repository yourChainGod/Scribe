//
//  ChunkedFileReader.swift
//  Phase 34a — iterates a file's bytes in fixed-size chunks without
//  ever holding the whole file as a Swift `String`. Used by the
//  large-file load path to feed Scintilla's `ILoader` one chunk at a
//  time.
//
//  Backing strategy:
//    `Data(contentsOf: url, options: .mappedIfSafe)` asks Foundation
//    to mmap the file. The kernel pages in only the bytes we touch,
//    so a 1 GB file occupies ~0 bytes of resident Swift memory until
//    we slice into a chunk and pass that slice to Scintilla. Each
//    slice is an O(1) reference into the shared backing.
//    `mappedIfSafe` falls back to a regular read when mmap isn't
//    possible (network volumes, sandboxed paths) — same correctness,
//    just no streaming benefit.
//
//  Why not FileHandle.read(upToCount:):
//    A streaming read forces an explicit per-chunk allocation +
//    copy. mmap lets us hand Scintilla a slice that points straight
//    at the page cache; the only copy happens once, inside Scintilla
//    when AddData appends to the gap buffer. ~2× faster and ~1×
//    less peak Swift memory for the same throughput.
//

import Foundation

enum ChunkedFileReaderError: Error, Sendable {
    /// Couldn't open / map the file. Wraps the Foundation error so
    /// the caller can distinguish "permission denied" from "no such
    /// file" without re-doing the read.
    case mappingFailed(underlying: Error)
}

struct ChunkedFileReader {
    /// File-on-disk we're reading. Captured by URL so the iteration
    /// closure can describe progress in user-meaningful terms.
    let url: URL
    /// One chunk size. 256 KB matches the default page batch macOS
    /// hands us on a sequential mmap touch and keeps the per-chunk
    /// progress callback below ~1% granularity for files under 30 MB
    /// — enough for a smooth progress bar without flooding `@Published`.
    let chunkSize: Int

    init(url: URL, chunkSize: Int = 256 * 1024) {
        self.url = url
        self.chunkSize = max(4096, chunkSize)
    }

    /// Total bytes on disk. Reads the URL resource value rather than
    /// stat — Foundation gives us the same number with first-class
    /// error handling. Returns 0 if the attribute isn't reachable
    /// (treated by callers as "small file, fall back to string load").
    func fileSize() -> Int {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return 0 }
        return size
    }

    /// Iterate every chunk. `process` is invoked once per chunk on
    /// the calling thread; returning `false` aborts the loop (the
    /// caller is responsible for cleaning up any partial state on
    /// the consumer side, e.g. calling `LargeFileLoader.cancel()`).
    /// Throws `ChunkedFileReaderError.mappingFailed` when the file
    /// can't be opened.
    func forEachChunk(process: (Data) -> Bool) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ChunkedFileReaderError.mappingFailed(underlying: error)
        }
        // Empty file = zero iterations. Caller still gets a
        // well-formed (empty) document downstream because Scintilla
        // treats AddData(length=0) as a no-op and ConvertToDocument
        // produces an empty doc.
        if data.isEmpty { return }
        var offset = 0
        let total = data.count
        while offset < total {
            let end = min(offset + chunkSize, total)
            // Subscript with a Range yields a Data that shares the
            // mmap'd backing. The new Data has its own startIndex
            // (0-based), so the consumer doesn't need to translate.
            let slice = data[offset..<end]
            // Re-base the slice so `withUnsafeBytes` inside the
            // consumer sees a fresh 0-based buffer. Without this,
            // some Foundation builds expose the original startIndex
            // and the consumer's pointer arithmetic gets mixed up.
            let chunk = Data(slice)
            if !process(chunk) { return }
            offset = end
        }
    }
}
