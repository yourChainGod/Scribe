//
//  DirectoryWatcher.swift
//  Phase 9 — recursive folder watcher backed by FSEvents. Used by
//  FileIndex (so ⌘P sees on-disk changes) and FileNode tree (so the
//  sidebar reflects external `git checkout` / `npm install` /
//  `mv` operations). Per-document edits are still tracked by
//  FileWatcher; this is the workspace-wide complement.
//
//  Why FSEvents instead of one DispatchSource per directory:
//    1. macOS-native, kernel-batched, gives us recursive coverage out
//       of the box. We open exactly one stream per workspace.
//    2. File-descriptor frugal — typical Scribe project (50 dirs,
//       1k files) costs us 1 fd, not 50.
//    3. Coalesced delivery: rapid changes (e.g. `git checkout` of a
//       100-file branch) arrive as a small handful of callbacks, not
//       100 separate ones.
//

import Foundation

/// Listens for any file-tree change under `url` (recursive). Calls
/// `onChange` on the main queue with no payload — the listener is
/// expected to invalidate whatever it cached and re-scan.
///
/// Event coalescing happens at two levels: FSEvents itself batches
/// rapid changes inside the kernel, and we add a 250 ms debounce on
/// top so a `git checkout` that touches 100 files fires `onChange`
/// once rather than e.g. five times.
@MainActor
final class DirectoryWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    /// FSEvents stream — referenced from `deinit` (which is
    /// nonisolated under Swift 6 strict concurrency) so we mark it
    /// `nonisolated(unsafe)` and rely on the CF/FSEvents APIs being
    /// thread-safe. We never mutate `stream` after `start()` returns,
    /// and the only access from outside the main actor is the
    /// stop/invalidate/release triplet in `deinit`.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?

    /// Debounce window between FSEvents callbacks and our `onChange`
    /// invocation. 250 ms keeps a `git checkout` that touches a
    /// hundred files to a single rebuild while still feeling instant
    /// after a single `mv`.
    private static let debounceNanos: UInt64 = 250_000_000

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url.standardizedFileURL
        self.onChange = onChange
        guard start() else { return nil }
    }

    deinit {
        // Capture before crossing actor boundary; cancel/invalidate
        // are CF-thread-safe.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: - Internals

    /// Returns true if the FSEventStream was created + started successfully.
    private func start() -> Bool {
        let pathArray = [url.path] as CFArray
        // Pass `self` raw to the C callback. The callback uses it as a
        // pointer to look the watcher back up; lifetime is bound by
        // the lifetime of the FSEventStream which we own.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // FSEvents callback signature is C; we hop back into Swift via
        // Unmanaged.fromOpaque, then schedule a main-actor task.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info)
                .takeUnretainedValue()
            Task { @MainActor in watcher.scheduleNotify() }
        }

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // FSEvents-internal coalescing latency. Tiny because we do
            // our own debounce on top — keeping FSEvents responsive
            // means a single edit doesn't get held for half a second
            // before it even reaches our callback.
            0.05,
            flags
        ) else { return false }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        return true
    }

    /// Coalesce bursts of FSEvents callbacks into a single onChange.
    private func scheduleNotify() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.onChange()
            }
        }
    }
}
