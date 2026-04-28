//
//  Coordinator+LargeFile.swift
//  Phase 34b — owns the editor side of the chunked large-file load.
//  The String-based open path (Workspace.openFile → loadAndDecode →
//  applyText) doesn't run for files >= LargeFilePolicy.thresholdBytes.
//  Instead Workspace tags the placeholder Document with
//  `isLargeFile = true` and we drive the load from here, where the
//  live ScintillaView is reachable.
//
//  Pipeline:
//    1. `beginLargeFileLoadIfNeeded` runs at the end of makeNSView.
//       - guards against re-entry via `largeFileLoadStarted`
//       - allocates a `LargeFileLoader` (main-actor only, touches view)
//       - hands all subsequent work to a detached priority Task
//    2. Background Task iterates `ChunkedFileReader` and feeds each
//       chunk into the loader. No main-actor hops per chunk.
//    3. On completion the Task hops back to main with either a
//       Scintilla document pointer (success) or an error.
//    4. Main-side commit calls `SCI_SETDOCPOINTER` to swap the
//       view's document — Scintilla releases the previous (empty)
//       placeholder document automatically.
//    5. Failure path: cancel the loader, flip Document state back to
//       "load error", let the user re-open. v1 doesn't surface an
//       NSAlert; v2 (Phase 34c) wires up the status-bar progress
//       affordance which doubles as the error surface.
//
//  Why a separate file:
//    Coordinator.swift already hosts theme + find + multi-cursor
//    extensions; the large-file logic is its own concern with its
//    own threading shape (detached Task + main-actor commit) and
//    benefits from being read in isolation.
//

import AppKit
import Foundation
import Scintilla

/// Failure modes the chunked load surfaces back to the main-actor
/// commit step. Plain enum — every case is recoverable by simply
/// re-opening the file the normal way.
enum LargeFileLoadError: Error, Sendable {
    /// `ILoader.AddData` returned a non-success Scintilla status
    /// (typically `SC_STATUS_BADALLOC`).
    case addDataFailed(code: Int)
    /// `ILoader.ConvertToDocument` returned nil. Extremely rare —
    /// usually only after a previous AddData failure, which we
    /// already report separately.
    case convertFailed
    /// The file disappeared mid-load (move / delete / network).
    case readFailed(underlying: Error)
}

extension ScintillaCodeEditor.Coordinator {

    /// Entry point called from `makeNSView` once the view is fully
    /// configured. No-op when:
    ///   - doc isn't a large file (the standard String path handles it)
    ///   - we already started a load on this Coordinator instance
    ///   - the doc has no URL (large-file path requires on-disk bytes)
    ///   - the load already finished (`loadProgress >= 1`)
    @MainActor
    func beginLargeFileLoadIfNeeded(in view: ScintillaView) {
        guard doc.isLargeFile,
              !largeFileLoadStarted,
              let url = doc.url,
              doc.loadProgress < 1 else {
            return
        }
        largeFileLoadStarted = true

        let fileSize = ChunkedFileReader(url: url).fileSize()
        let options = LargeFilePolicy.loaderOptions(forSize: fileSize)
        guard let loader = LargeFileLoader.allocate(on: view,
                                                    initialSize: fileSize,
                                                    options: options) else {
            // Couldn't even reserve a loader — Scintilla's allocator
            // is starved. Fail soft: clear the large-file flags so
            // the empty placeholder doc doesn't lie about being mid-
            // load forever.
            handleLargeFileLoadFailure(error: .convertFailed)
            return
        }

        let docID = doc.id
        let docRef = doc
        let viewRef = view

        // Outer Task is main-actor by inheritance from the call site;
        // the inner Task.detached carries the per-chunk work. The
        // doc-pointer crosses the actor boundary as `Int` (the raw
        // address) because `UnsafeMutableRawPointer` itself isn't
        // Sendable under strict concurrency. We rebuild the pointer
        // on the main side before passing it to Scintilla.
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.runChunkedLoad(loader: loader, url: url)
            }.value

            guard let self else { return }
            // Doc may have been swapped (user opened another file
            // while this one streamed in). The view's current doc
            // is now somebody else; abandon the load instead of
            // overwriting their content.
            guard self.doc.id == docID else {
                if case .success(let docAddress) = result {
                    // We hold an isolated document Scintilla just
                    // produced; release it cleanly so it doesn't
                    // leak. SCI_RELEASEDOCUMENT(0, doc) decrements
                    // its refcount; the doc never having been
                    // attached to a view means refcount goes to 0
                    // and Scintilla frees it.
                    viewRef.message(SCI.RELEASEDOCUMENT,
                                    wParam: 0,
                                    lParam: docAddress)
                }
                return
            }
            switch result {
            case .success(let docAddress):
                self.commitLargeFileDocument(address: docAddress,
                                             in: viewRef,
                                             doc: docRef)
            case .failure(let error):
                self.handleLargeFileLoadFailure(error: error)
            }
        }
    }

    // MARK: - Off-main pipeline

    /// Pure background work: iterate the file in chunks, feed the
    /// loader, convert when done. `nonisolated` so it can run from a
    /// detached Task without a main-actor hop per chunk.
    ///
    /// Returns the doc pointer **as `Int`** (its raw bit pattern)
    /// rather than `UnsafeMutableRawPointer` so the result is
    /// trivially Sendable across the actor boundary that hops back
    /// to main. The main side rebuilds the pointer before handing
    /// it to Scintilla — no information is lost in the round-trip.
    nonisolated private static func runChunkedLoad(
        loader: LargeFileLoader,
        url: URL
    ) -> Result<Int, LargeFileLoadError> {
        let reader = ChunkedFileReader(url: url)
        // forEachChunk's closure can't throw, so we hoist the first
        // failure into a captured variable and short-circuit by
        // returning false from the callback.
        var addError: LargeFileLoadError? = nil
        do {
            try reader.forEachChunk { chunk in
                switch loader.addChunk(chunk) {
                case .success:
                    return true
                case .failure(let code):
                    addError = .addDataFailed(code: code)
                    return false
                }
            }
        } catch {
            // Mapping failed (file vanished, permission revoked).
            // The loader is unconverted; release it.
            loader.cancel()
            return .failure(.readFailed(underlying: error))
        }
        if let err = addError {
            loader.cancel()
            return .failure(err)
        }
        guard let docPtr = loader.convertToDocument() else {
            return .failure(.convertFailed)
        }
        return .success(Int(bitPattern: docPtr))
    }

    // MARK: - Main-actor commit / failure

    /// Hand the freshly-built Scintilla document to the view via
    /// `SCI_SETDOCPOINTER`. The view releases its previous (empty)
    /// document automatically; we don't have to call RELEASEDOCUMENT
    /// on it.
    ///
    /// The address comes in as `Int` (Sendable across the actor
    /// hop). Scintilla's `sptr_t` is `intptr_t`, so the same Int
    /// is what its message dispatcher already expects.
    @MainActor
    private func commitLargeFileDocument(
        address: Int,
        in view: ScintillaView,
        doc: Document
    ) {
        view.message(SCI.SETDOCPOINTER, wParam: 0, lParam: address)
        doc.loadProgress = 1
        doc.isLoading = false
    }

    /// Reset the document into a "load failed, please retry" state.
    /// `isLargeFile` flips back to false so the user can re-open the
    /// file via the standard path and get a real error message
    /// (Workspace.applyLoadResult surfaces the underlying NSError).
    @MainActor
    private func handleLargeFileLoadFailure(error: LargeFileLoadError) {
        // We deliberately *don't* show an NSAlert here in v1 — the
        // placeholder doc is still on screen and the user can
        // attempt to re-open the file. v2 will surface a status-bar
        // affordance with retry copy.
        _ = error
        doc.isLargeFile = false
        doc.loadProgress = -1
        doc.isLoading = false
    }
}
