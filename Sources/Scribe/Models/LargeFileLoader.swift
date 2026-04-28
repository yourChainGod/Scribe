//
//  LargeFileLoader.swift
//  Phase 34a — Swift wrapper around the `Scintilla::ILoader *` returned
//  by `SCI_CREATELOADER`. Lets the chunked file-read pipeline push
//  bytes into Scintilla without ever materialising the whole file as a
//  Swift `String`.
//
//  Why this layer exists:
//    - `SCI_CREATELOADER` returns a C++ pointer that Swift sees as
//      `Int` (sptr_t). The `AddData / ConvertToDocument / Release`
//      calls live on the C++ vtable, unreachable from Swift. The
//      ObjC++ shim in `Vendor/scintilla/swiftpm-bridge` exposes
//      C-callable forwarders; this Swift class wraps them in a safe,
//      lifetime-tracked façade.
//
//  Lifetime contract:
//    - `init(view:initialSize:options:)` allocates the loader.
//    - `addChunk(_:)` may be called any number of times.
//    - Exactly *one* of `convertToDocument()` or `cancel()` must run.
//      After either, the wrapper is consumed and further calls
//      no-op (with a precondition fail in debug — bugs we want
//      surfaced loud, not silently swallowed).
//
//  Threading:
//    - `nonisolated` so it can run on a `Task.detached`. The
//      Scintilla `view.message` calls are safe off-main here because
//      `SCI_CREATELOADER` builds an isolated document, not the live
//      one — Scintilla's docs explicitly green-light loader use from
//      a background thread. Once we hand the doc back via
//      `SCI_SETDOCPOINTER` we hop to main.
//

import Foundation
import Scintilla

/// Status of a single `addChunk` call. Mirrors Scintilla's
/// `SC_STATUS_*` codes; `success` is 0, anything else is a real
/// failure (typically `SC_STATUS_BADALLOC`).
enum LargeFileLoaderStatus {
    case success
    case failure(code: Int)
}

/// Thin Swift wrapper over `Scintilla::ILoader`. Not actor-isolated so
/// the chunked-read pipeline (which runs on a detached priority task)
/// can drive it without main-actor hops between every chunk.
///
/// Construction is split across two surfaces:
///   - `LargeFileLoader.allocate(on:initialSize:options:)` is `@MainActor`
///     because `SCI_CREATELOADER` touches the live ScintillaView.
///   - The instance returned from `allocate` can then cross actor
///     boundaries; `addChunk` runs `nonisolated` so a detached read
///     pipeline drives it without per-chunk hops.
final class LargeFileLoader: @unchecked Sendable {

    /// Opaque ILoader pointer obtained from `SCI_CREATELOADER`. Set
    /// to nil after `convertToDocument` / `cancel` so subsequent
    /// calls fail fast.
    private var loader: UnsafeMutableRawPointer?

    /// Total bytes appended via `addChunk` so far. Lets the caller
    /// build a progress bar without keeping a separate counter.
    private(set) var bytesWritten: Int = 0

    /// Main-actor entry point. Returns nil when Scintilla can't
    /// allocate a loader (very rare — surfaces as a graceful "fall
    /// back to String load" path in the caller). `initialSize` is a
    /// hint that lets Scintilla pre-size its gap buffer instead of
    /// doubling up from a small default; pass the on-disk byte count.
    @MainActor
    static func allocate(on view: ScintillaView,
                         initialSize: Int,
                         options: Int) -> LargeFileLoader? {
        // SCI_CREATELOADER(initial, options) → ILoader* (as sptr_t)
        let raw = view.message(SCI.CREATELOADER,
                               wParam: UInt(initialSize),
                               lParam: options)
        guard raw != 0,
              let pointer = UnsafeMutableRawPointer(bitPattern: Int(raw))
        else {
            return nil
        }
        return LargeFileLoader(rawLoader: pointer)
    }

    /// Internal initialiser. Direct callers (mostly tests) hand in a
    /// pre-allocated pointer; production code goes through
    /// `allocate(on:initialSize:options:)` so the main-actor hop is
    /// the only place a ScintillaView is touched.
    init(rawLoader: UnsafeMutableRawPointer) {
        self.loader = rawLoader
    }

    deinit {
        // Defensive: a dropped LargeFileLoader without explicit
        // teardown would leak the C++ object. In practice the
        // pipeline always converts or cancels; this is the seatbelt.
        if let loader {
            ScribeLoaderRelease(loader)
        }
    }

    /// Append one chunk of bytes. Returns the Scintilla status so
    /// callers can decide whether to retry (almost always: stop and
    /// fall back to the String path on any non-success).
    func addChunk(_ data: Data) -> LargeFileLoaderStatus {
        guard let loader else {
            assertionFailure("LargeFileLoader.addChunk after teardown")
            return .failure(code: -1)
        }
        // Withhold the call when there's nothing to add — Scintilla
        // would accept a 0-length AddData, but the round-trip is
        // wasted work and the caller usually didn't mean it.
        if data.isEmpty { return .success }
        let result = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int32 in
            // baseAddress is non-nil for non-empty Data; the guard
            // above made that explicit.
            guard let base = buf.baseAddress else { return -1 }
            return Int32(ScribeLoaderAddData(loader, base, buf.count))
        }
        if result == 0 {
            bytesWritten += data.count
            return .success
        }
        return .failure(code: Int(result))
    }

    /// Convert the loader into a Scintilla document pointer the
    /// caller can hand to `SCI_SETDOCPOINTER`. The wrapper is
    /// consumed; subsequent `addChunk` calls hit a precondition.
    /// Returns nil if Scintilla refused conversion (extremely rare
    /// — typically only after a previous failed AddData).
    func convertToDocument() -> UnsafeMutableRawPointer? {
        guard let loader else {
            assertionFailure("LargeFileLoader.convertToDocument after teardown")
            return nil
        }
        let doc = ScribeLoaderConvertToDocument(loader)
        // ConvertToDocument also releases the loader's reference;
        // we drop our local pointer so deinit doesn't double-free.
        self.loader = nil
        return doc
    }

    /// Abort the load. After this call the wrapper is consumed.
    /// Use when the user cancels mid-load or a chunk read failed
    /// — the partially-built document never reaches the editor.
    func cancel() {
        guard let loader else { return }
        ScribeLoaderRelease(loader)
        self.loader = nil
    }
}
