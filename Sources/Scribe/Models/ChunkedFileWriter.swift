//
//  ChunkedFileWriter.swift
//  Phase 34c — flip side of `ChunkedFileReader`. Streams a Scintilla
//  buffer to disk one bounded chunk at a time so a multi-GB save
//  doesn't have to materialise the whole document as a Swift String
//  first. Writes go to a sibling temp file, then rename atomically
//  on top of the destination — same semantics the small-file save
//  path gets from `Data.write(to:options: [.atomic])`.
//
//  Why a struct, not a class:
//    The writer holds no observable state — its only "memory" is the
//    `FileHandle` it owns for the duration of the save call, which
//    is closed deterministically before the rename. A value type
//    keeps the API trivial to reason about.
//
//  Threading contract:
//    `write(view:to:flags:byteCount:progress:)` is `@MainActor`
//    because each per-chunk read goes through the Scintilla view's
//    message dispatcher, which only accepts main-thread access.
//    Between chunks we `await Task.yield()` so the run loop can
//    repaint the UI (status bar progress, cursor blink, etc.) —
//    saving 1 GB at the default 256 KiB chunk size is ~4 k yields,
//    which is imperceptible on the user's side.
//

import AppKit
import Foundation
import Scintilla

/// Failure modes specific to the chunked save path. Plain enum —
/// every case is recoverable by re-running the save (no partial
/// corruption possible because the rename is atomic).
enum ChunkedFileWriterError: Error, Sendable {

    /// The temp file couldn't be created in the destination's
    /// directory — usually a permissions issue or out-of-space.
    /// `underlying` carries the system error so callers can surface
    /// a localized message.
    case openTempFailed(underlying: Error)

    /// `FileHandle.write(contentsOf:)` failed mid-stream. Typically
    /// disk-full; partial bytes have been discarded by closing the
    /// handle before the rename runs.
    case writeFailed(underlying: Error)

    /// `SCI_GETTEXTRANGEFULL` returned nil (allocation failure inside
    /// the ObjC bridge). We don't have a partial buffer to flush, so
    /// abandoning the save without dirtying the destination is
    /// always safe.
    case readFailed(start: Int, length: Int)

    /// `FileManager.replaceItem(at:withItemAt:…)` couldn't promote
    /// the temp file over the destination. Rare (cross-volume,
    /// destination locked); we leave the temp on disk so the user
    /// can recover manually.
    case replaceFailed(underlying: Error)
}

/// Phase 34c — chunk size used by `ChunkedFileWriter.write(...)`.
/// 256 KiB matches the reader; large enough that the per-chunk
/// `SCI_GETTEXTRANGEFULL` overhead amortises against the kernel
/// `write()` syscall, small enough to keep the main-actor pause
/// imperceptible (one chunk read + write is ~few-hundred microseconds
/// even on the slow path).
struct ChunkedFileWriter: Sendable {

    let chunkSize: Int

    init(chunkSize: Int = 256 * 1024) {
        // Floor at 4 KiB to mirror ChunkedFileReader's contract:
        // anything smaller and the SCI message overhead dominates
        // without a measurable memory benefit.
        self.chunkSize = max(4 * 1024, chunkSize)
    }

    /// Write `byteCount` bytes from `view`'s Scintilla buffer to
    /// `destination`. Atomic: on success the file at `destination`
    /// is the new content, on failure it's untouched.
    ///
    /// `progress` (optional) is invoked on the main actor with the
    /// running byte count after each chunk write. Use it to update
    /// a status bar; the writer doesn't introduce any of its own UI.
    ///
    /// `byteCount` typically comes from `SCI_GETLENGTH`; we accept it
    /// as a parameter rather than re-querying so callers can sample
    /// it under whatever consistency story makes sense for their
    /// use case (the default is "one read at the start of save").
    @MainActor
    func write(view: ScintillaView,
               to destination: URL,
               byteCount: Int,
               progress: ((Int) -> Void)? = nil) async throws {
        // Defensive: an empty document still produces a valid empty
        // file. We bypass the chunk loop entirely so an O-byte file
        // never opens a useless FileHandle.
        if byteCount == 0 {
            try Data().write(to: destination, options: [.atomic])
            progress?(0)
            return
        }

        // Sibling temp inside the same directory so the rename stays
        // on the same volume (replaceItem fails across volumes on
        // some configurations even with .usingNewMetadataOnly).
        let directory = destination.deletingLastPathComponent()
        let tempURL = directory
            .appendingPathComponent(".scribe-save-\(UUID().uuidString)")
            .appendingPathExtension("tmp")

        // FileManager.createFile is the cheapest way to materialise
        // a zero-byte file at a path we own; FileHandle then takes
        // it over for the streaming writes.
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw ChunkedFileWriterError.openTempFailed(underlying: error)
        }

        // Make sure the temp file is removed if anything below throws
        // before the atomic replace runs. We close the handle first
        // (the unlink is fine without it on POSIX, but explicit close
        // surfaces any lingering errors via the catch).
        do {
            var written = 0
            while written < byteCount {
                let length = Swift.min(chunkSize, byteCount - written)
                guard let chunk = ScribeReadTextRange(
                    Unmanaged.passUnretained(view).toOpaque(),
                    written,
                    length
                ) else {
                    try handle.close()
                    try? FileManager.default.removeItem(at: tempURL)
                    throw ChunkedFileWriterError.readFailed(start: written,
                                                            length: length)
                }
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: tempURL)
                    throw ChunkedFileWriterError.writeFailed(underlying: error)
                }
                written += length
                progress?(written)
                // Yield between chunks so SwiftUI gets a tick to
                // repaint progress / accept user input. Without this
                // a 1 GB save would freeze the run loop for several
                // seconds; with it the only blocking work is the
                // syscall itself.
                await Task.yield()
            }

            // fsync via synchronizeFile() so the bytes hit disk
            // before the rename swaps them in. Skipping this risks
            // a power-loss window where the rename succeeded but
            // the data is still in page cache.
            try handle.synchronize()
            try handle.close()
        } catch {
            // Re-raise after cleanup; cleanup itself errors are
            // intentionally swallowed (best-effort).
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // Atomic rename: on POSIX `rename(2)` is the canonical
        // atomic replace. FileManager.replaceItem wraps that with
        // backup-file bookkeeping that doesn't apply to our case
        // (no original to back up if the destination is missing),
        // so we use it with .usingNewMetadataOnly to keep things
        // predictable.
        do {
            // replaceItemAt returns the (possibly new) URL of the
            // file at the destination. We only need the side effect.
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw ChunkedFileWriterError.replaceFailed(underlying: error)
        }
    }
}
