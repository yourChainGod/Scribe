//
//  FileWatcher.swift
//  Phase 2 — watch a single open file for outside-the-app modifications
//  using GCD's `DispatchSource.makeFileSystemObjectSource`. Lighter than
//  full FSEvents and good enough for individual files.
//
//  Each Document gets one watcher; closing the document or changing its
//  URL replaces the watcher (handled in Workspace).
//

import Foundation

/// Listens for `.write`, `.delete`, and `.rename` events on a file
/// descriptor. Calls `onChange` on the main actor when the underlying
/// file is modified. Cancel by setting the watcher to `nil` (i.e.
/// dropping the last reference).
@MainActor
final class FileWatcher {
    private let url: URL
    private let fd: Int32
    private let source: DispatchSourceFileSystemObject
    private let onChange: @MainActor () -> Void

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let path = url.standardizedFileURL.path
        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return nil }
        self.url = url
        self.fd = fd
        self.onChange = onChange
        self.source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        // Reentry into the actor — DispatchSource fires on the main queue
        // but Swift 6 strict concurrency still wants the hop.
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.onChange() }
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
