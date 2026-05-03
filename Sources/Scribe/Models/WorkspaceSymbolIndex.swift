//
//  WorkspaceSymbolIndex.swift
//  Phase 65 — workspace-wide symbol catalogue powering the
//  ⌘T "Go to Symbol in Workspace…" palette.
//
//  Architecture
//    1. The host app drives `rebuild(using:)` whenever it wants a
//       fresh scan. The index re-parses every file in the supplied
//       FileIndex (filtered by extension support + size cap), then
//       publishes the resulting [WorkspaceSymbol] in a single
//       atomic write so SwiftUI sees the list flip in one tick.
//    2. Heavy lifting (file IO + regex parse) happens off-main on
//       a detached priority pool. The on-main publisher only
//       lands the final array.
//    3. Generation counter cancels stale rebuilds the same way
//       FileIndex does — clicking ⌘T twice in quick succession
//       can't make an old, half-finished scan stomp the new one.
//
//  Cost ceiling
//    - Per file: capped at `maxFileBytes` (defaults to 1 MB). Any
//      bigger and the regex parsers start to drag the run loop.
//      Generated bundles / minified vendor JS is the typical
//      case; their symbols rarely matter for navigation.
//    - Total: capped at `maxSymbols`. A 200 k-file FileIndex
//      stops contributing once the cap fills, which the palette
//      placeholder calls out so the user knows the catalogue is
//      truncated.
//
//  v1 limitations (deliberately deferred to a follow-up phase)
//    - No incremental updates: any FS-watched change re-runs the
//      full scan. For Scribe's typical 1k-10k-file repos this
//      finishes inside the user's "I just pressed ⌘T" reaction
//      window, so the simpler full-rebuild story is fine.
//    - No persistent on-disk cache: the index lives only in
//      memory for the running process. Restart costs a fresh
//      scan, which on an SSD-backed repo measures in tens of ms.
//

import Combine
import Foundation

@MainActor
final class WorkspaceSymbolIndex: ObservableObject {

    /// All symbols collected from the workspace's parseable files,
    /// sorted by `(url.path, line)` so stable result ordering means
    /// fuzzy-match ties don't visibly flip between palette opens.
    @Published private(set) var symbols: [WorkspaceSymbol] = []

    /// `true` between a `rebuild(using:)` start and the
    /// corresponding scan finishing — same shape as
    /// `FileIndex.isIndexing`. The palette placeholder shows a
    /// "Indexing…" hint while this is set.
    @Published private(set) var isIndexing: Bool = false

    /// `true` when the most recent rebuild hit the per-workspace
    /// cap. Surfaces in the palette placeholder so users
    /// understand why a known symbol might be missing.
    @Published private(set) var didTruncate: Bool = false

    /// Workspace root the most recent rebuild ran against. Used by
    /// the palette to decide whether to invalidate cached state
    /// when the user opens a different folder.
    private(set) var sourceRootURL: URL?

    /// Per-file size cap. Files larger than this are skipped.
    /// Tunable as a static so unit tests can shrink it for the
    /// "skipped because too big" path without exposing a mutable
    /// instance property.
    nonisolated static let maxFileBytes: Int = 1_000_000

    /// Total catalogue cap. Keeps the in-memory size bounded for
    /// pathologically symbol-dense repos.
    nonisolated static let maxSymbols: Int = 50_000

    private var rebuildTask: Task<Void, Never>?
    private var rebuildGeneration: Int = 0

    // MARK: - Public surface

    /// (Re)build the symbol catalogue from the supplied FileIndex.
    /// Cancels any in-flight scan first; subsequent reads of
    /// `symbols` return the latest atomic snapshot.
    func rebuild(using fileIndex: FileIndex) {
        rebuild(rootURL: fileIndex.rootURL, files: fileIndex.files)
    }

    /// Variant that takes the file list directly. Used by tests
    /// (which build a tmp-dir repo without spinning a FileIndex)
    /// and by callers that already have a snapshot in hand.
    func rebuild(rootURL: URL?, files: [URL]) {
        rebuildTask?.cancel()
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        sourceRootURL = rootURL
        symbols = []
        didTruncate = false
        isIndexing = true

        rebuildTask = Task { [weak self] in
            // Cap-aware off-main scan. The detached task can't
            // touch self because Coordinator-level mutation has
            // to happen on @MainActor.
            let result = await Task.detached(priority: .utility) {
                Self.parseAll(files: files)
            }.value
            await MainActor.run { [weak self] in
                guard let self,
                      self.rebuildGeneration == generation else { return }
                self.symbols = result.symbols
                self.didTruncate = result.didTruncate
                self.isIndexing = false
            }
        }
    }

    /// Forget the catalogue. Wired from the host app when the
    /// user closes the workspace folder.
    func clear() {
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildGeneration &+= 1
        sourceRootURL = nil
        symbols = []
        didTruncate = false
        isIndexing = false
    }

    // MARK: - Off-main parser

    /// Bundle of "what we collected" + "did we hit the cap?". The
    /// detached task hands one of these back to the @MainActor
    /// publisher.
    /// Module-internal so the static `parseAll` (also internal,
    /// for direct test access without round-tripping through
    /// `rebuild`) can return it.
    struct ScanResult: Sendable {
        var symbols: [WorkspaceSymbol]
        var didTruncate: Bool
    }

    /// Pure scan over a list of file URLs. Filters out files we
    /// can't parse (extension not in `SymbolParserCatalog`) or
    /// won't parse (size cap). Stops appending once `maxSymbols`
    /// is reached and reports the truncation through the result.
    nonisolated static func parseAll(files: [URL]) -> ScanResult {
        var out: [WorkspaceSymbol] = []
        out.reserveCapacity(min(files.count * 4, Self.maxSymbols))
        var truncated = false

        let fm = FileManager.default
        for url in files {
            if Task.isCancelled {
                return ScanResult(symbols: out, didTruncate: truncated)
            }
            let ext = url.pathExtension.lowercased()
            guard let parser = SymbolParserCatalog.parser(forExtension: ext) else {
                continue
            }
            // Size gate. Treat "no attributes available" as
            // "small file" so an unreadable size doesn't drop
            // legitimate sources — the read itself will fail
            // gracefully if the file really is gone.
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            if size > Self.maxFileBytes { continue }
            // UTF-8 decode failures (binary blobs the extension
            // map didn't catch) silently skip the file rather
            // than aborting the whole scan.
            guard let data = try? Data(contentsOf: url, options: [.uncached]),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            let entries = parser.parse(text)
            for entry in entries {
                if out.count >= Self.maxSymbols {
                    truncated = true
                    return ScanResult(symbols: out, didTruncate: truncated)
                }
                out.append(WorkspaceSymbol(
                    id: WorkspaceSymbol.makeID(url: url,
                                               line: entry.lineNumber,
                                               name: entry.name),
                    name: entry.name,
                    kind: entry.kind,
                    url: url,
                    line: entry.lineNumber,
                    depth: entry.depth
                ))
            }
        }
        // Stable ordering — fuzzy match preserves insertion order
        // for ties, so deterministic input yields deterministic
        // output rendering. Sort by path then line so symbols
        // from the same file land contiguously, easing eyeball
        // scans of the palette list.
        out.sort { lhs, rhs in
            if lhs.url.path != rhs.url.path {
                return lhs.url.path < rhs.url.path
            }
            return lhs.line < rhs.line
        }
        return ScanResult(symbols: out, didTruncate: truncated)
    }
}
