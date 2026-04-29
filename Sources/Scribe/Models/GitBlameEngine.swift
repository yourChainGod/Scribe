//
//  GitBlameEngine.swift
//  Phase 35c-ii-β — backbone of Inline Git Blame.
//
//  Mirrors GitGutterEngine / GitStatusEngine in shape:
//    - One shared instance per workspace.
//    - request(for:url:) shells out to `git blame --porcelain`
//      on a detached task; the parsed result lands on the main
//      actor as a [Int: BlameLine] map per URL.
//    - Save / external-change paths call refresh(for:) so the
//      cache stays in sync with the on-disk file.
//    - Tab switches call request(for:); the cache-hit guard
//      means a re-visit is free.
//
//  Concurrency:
//    - The class is @MainActor; every read + write of
//      blameByURL / inFlight happens on the main thread.
//    - The shell-out runs on Task.detached(.userInitiated) so a
//      slow blame on a deep-history file doesn't stutter typing.
//    - We hop back to main via `await self.handleResult(...)`,
//      which is what SwiftUI's diff loop expects for @Published.
//
//  Why per-URL cache:
//    Inline-blame UI follows the caret on the active doc, but a
//    user with N tabs switches between them constantly. Caching
//    by absolute URL means a tab swap is O(1) — the engine
//    doesn't re-blame a file that just got the same data 200ms
//    ago.
//
//  What we deliberately don't do:
//    - No timer-based refresh. FSEvents + the explicit save
//      hooks already cover every meaningful mutation; polling
//      would just burn process spawns.
//    - No background prefetch. Inline blame is a "just-in-time
//      annotation on the visible caret line", so we only blame
//      the file the user actually looked at.
//    - No per-line lazy fetch. `git blame` over a whole file is
//      the same shell-out cost as one line; per-line would only
//      win on multi-MB files where blame is dominated by parse
//      time, which is a Phase-35c-iv problem.
//

import Foundation

@MainActor
final class GitBlameEngine: ObservableObject {

    /// Per-URL blame map, keyed by line number (1-based) →
    /// `BlameLine`. An empty map means "we asked git and there
    /// is no blame for this URL" (untracked or not in repo);
    /// a missing key means "we haven't asked yet". Distinguishing
    /// the two lets the inline-blame UI know whether to call
    /// `request(for:)` or stay quiet.
    @Published private(set) var blameByURL: [URL: [Int: GitClient.BlameLine]] = [:]

    /// Per-URL current git author name (`git config user.name`).
    /// Used only for presentation ("You" instead of the raw author).
    private var currentAuthorByURL: [URL: String] = [:]

    /// URLs currently being blamed. A second request for the
    /// same URL while one is already in flight collapses to a
    /// no-op, so a tab-switch storm doesn't fan out into
    /// duplicate `git blame` invocations.
    private var inFlight: Set<URL> = []

    init() {}

    // MARK: - Public

    /// Schedule a blame fetch for `url`.
    ///
    /// Cache-hit short-circuit: if `blameByURL[url]` is already
    /// populated, this method is a no-op. Callers that need a
    /// forced re-fetch (save lands, FSEvents fires) call
    /// `refresh(for:)` instead, which invalidates the entry
    /// before re-requesting.
    ///
    /// In-flight short-circuit: a second call for a URL whose
    /// blame is already running is dropped so we don't fan out
    /// duplicate shell-outs on a tab-switch storm.
    ///
    /// nil URL (untitled / scratch document) is silently ignored.
    func request(for url: URL?) {
        guard let url else { return }
        let key = url.standardizedFileURL
        if blameByURL[key] != nil { return }      // cache hit
        if inFlight.contains(key)  { return }      // already running
        inFlight.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            let repo = GitClient.findRepoRoot(for: key)
            let currentAuthor = repo.flatMap { GitClient.currentUserName(repo: $0) }
            let result = GitClient.blame(file: key)
            await self?.handleResult(url: key,
                                     result: result,
                                     currentAuthorName: currentAuthor)
        }
    }

    /// Drop the cache entry for `url` and re-fetch. Used by save /
    /// external-change paths so the next caret tick gets a fresh
    /// blame instead of stale annotations from before the edit.
    func refresh(for url: URL?) {
        guard let url else { return }
        let key = url.standardizedFileURL
        blameByURL[key] = nil
        request(for: key)
    }

    /// Drop the cache entry without re-requesting. Used when a
    /// file is closed (no consumer left, no point keeping the
    /// rows alive).
    func invalidate(for url: URL?) {
        guard let url else { return }
        let key = url.standardizedFileURL
        blameByURL[key] = nil
        currentAuthorByURL[key] = nil
    }

    /// Drop every cache entry. Used when the workspace switches
    /// folders — the current rows belong to the old repo and
    /// would be misleading for any file the new folder reopens
    /// at the same path.
    ///
    /// We do not also clear `inFlight`: the in-flight task's
    /// `handleResult` will land its row, then the next code path
    /// that cares (caret tick / save) will re-request. Forcing
    /// the flight to "give up" would just leak the pending
    /// shell-out's CPU instead of using the result.
    func invalidateAll() {
        blameByURL = [:]
        currentAuthorByURL = [:]
    }

    /// Read cached blame for one line. Returns nil if either no
    /// blame has been fetched for this URL or the line isn't in
    /// the result (e.g. an EOF blank line that git skipped).
    /// `url == nil` mirrors the read side of `request(for:)`.
    func blameLine(for url: URL?, line lineNo: Int) -> GitClient.BlameLine? {
        guard let url else { return nil }
        return blameByURL[url.standardizedFileURL]?[lineNo]
    }

    func blameLines(for url: URL?) -> [Int: GitClient.BlameLine]? {
        guard let url else { return nil }
        return blameByURL[url.standardizedFileURL]
    }

    func currentAuthorName(for url: URL?) -> String? {
        guard let url else { return nil }
        return currentAuthorByURL[url.standardizedFileURL]
    }

    // MARK: - Private

    /// Land a finished `git blame` result on the cache. Called by
    /// the detached Task hopping back to the main actor.
    ///
    /// Empty maps for `.untracked` / `.notInRepo` are intentional:
    /// they pin "we asked, the answer is nothing" so a later
    /// caret tick doesn't keep re-requesting. `.error` is treated
    /// as transient (corrupt object, …) and we keep whatever was
    /// in the cache; this mirrors GitStatusEngine's policy of not
    /// blanking the sidebar on a flaky git call.
    private func handleResult(url: URL,
                              result: GitClient.BlameResult,
                              currentAuthorName: String?) {
        inFlight.remove(url)
        currentAuthorByURL[url] = currentAuthorName
        switch result {
        case .ok(let lines):
            var map: [Int: GitClient.BlameLine] = [:]
            map.reserveCapacity(lines.count)
            for line in lines { map[line.lineNo] = line }
            blameByURL[url] = map
        case .untracked, .notInRepo:
            blameByURL[url] = [:]
        case .error:
            break
        }
    }
}
