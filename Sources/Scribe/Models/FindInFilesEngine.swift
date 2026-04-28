//
//  FindInFilesEngine.swift
//  Phase 4b — workspace-wide search ("Find in Files"). Walks the
//  workspace folder tree off the main thread, searches each text file
//  with NSRegularExpression, and streams results back to
//  FindInFilesState in batches so the sidebar can update progressively.
//
//  Skip rules (mirror what ripgrep / VSCode do by default):
//    - hidden directories (".git", ".svn", …)
//    - well-known build / dependency dumps (".build", "node_modules",
//      "DerivedData", "Pods", "target", "dist", "build", ".next")
//    - files whose first 8 KB contain a NUL byte (binary heuristic)
//    - files larger than `maxBytesPerFile`
//

import Foundation

/// Search options the engine takes per run; built from FindInFilesState
/// at the moment the search is kicked off so changes mid-search don't
/// confuse the streamer.
struct FindInFilesOptions: Sendable {
    let query: String
    let matchCase: Bool
    let wholeWord: Bool
    let regex: Bool
    let includeGlobs: [String]
    let excludeGlobs: [String]
}

/// Outcome of a workspace-wide replace pass. `errors` carries
/// per-file failure descriptions (read errors, encoding errors, write
/// errors); the rest are aggregate counts for the post-replace summary.
struct ReplaceSummary: Sendable {
    var filesScanned: Int = 0
    var filesChanged: Int = 0
    var totalReplacements: Int = 0
    var errors: [(URL, String)] = []
}

@MainActor
final class FindInFilesEngine {
    /// 5 MB — Scintilla itself is fine with larger files but our
    /// in-memory match list isn't, and 5 MB covers >99 % of source
    /// files.
    /// `nonisolated` because `run(_:)` and `scan(_:)` execute off
    /// the main actor and need to read the cap from inside a detached
    /// task. Plain `let` constant — safe across actors.
    nonisolated static let maxBytesPerFile: Int = 5 * 1024 * 1024

    /// Hard cap on matches per file — past this point a single
    /// generated file would dominate the result list.
    nonisolated static let maxMatchesPerFile: Int = 200

    // Directory pruning uses IgnoredPaths.shouldSkipDirectory(named:)
    // directly — keeping that in IgnoredPaths means Find-in-Files,
    // FileIndex, and any future workspace walker stay in sync.

    /// Currently in-flight search task. New `.search()` calls cancel
    /// any previous one before starting.
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Kick off a workspace-wide search. Streams partial results back
    /// to `state` every `flushEveryNFiles` files so the user sees a
    /// growing list rather than a frozen one.
    func search(options: FindInFilesOptions,
                root: URL,
                into state: FindInFilesState) {
        cancel()
        guard !options.query.isEmpty else {
            state.reset()
            state.setSearching(false)
            return
        }
        state.reset()
        state.setSearching(true)

        let regex: NSRegularExpression?
        do {
            regex = try buildRegex(options: options)
        } catch {
            state.error = "Invalid regex: \(error.localizedDescription)"
            state.setSearching(false)
            return
        }

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.run(options: options,
                           root: root,
                           regex: regex,
                           into: state)
        }
    }

    /// Walk the workspace and replace every `options.query` match with
    /// `replacement`. Limited to the file set the most recent `search`
    /// returned (passed in via `urls`) so the user only ever rewrites
    /// files they could see in the result tree. Reports aggregate
    /// counts via `completion` on the main actor.
    ///
    /// We deliberately re-read each file's current bytes (rather than
    /// trust the in-memory snapshot search captured) — minutes can pass
    /// between search and replace, and operating on stale text would
    /// reintroduce the very bug atomic write is meant to avoid.
    func replaceAll(options: FindInFilesOptions,
                    replacement: String,
                    urls: [URL],
                    excludedLinesByURL: [URL: Set<Int>] = [:],
                    into state: FindInFilesState,
                    completion: @escaping @MainActor (ReplaceSummary) -> Void) {
        cancel()
        guard !options.query.isEmpty else {
            state.setReplacing(false)
            completion(ReplaceSummary())
            return
        }
        let regex: NSRegularExpression?
        do {
            regex = try buildRegex(options: options)
        } catch {
            state.error = "Invalid regex: \(error.localizedDescription)"
            state.setReplacing(false)
            completion(ReplaceSummary())
            return
        }
        guard let regex else {
            state.setReplacing(false)
            completion(ReplaceSummary())
            return
        }

        state.setReplacing(true)
        // NSRegularExpression.replacementString accepts $1, $2, $0 etc.
        // For literal-mode we still need to escape user-supplied $ / \
        // so they don't accidentally form a backref.
        let template = options.regex
            ? replacement
            : NSRegularExpression.escapedTemplate(for: replacement)

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let summary = await self.runReplace(urls: urls,
                                                regex: regex,
                                                template: template,
                                                excludedLinesByURL: excludedLinesByURL)
            await MainActor.run {
                state.setReplacing(false)
                completion(summary)
            }
        }
    }

    private nonisolated func runReplace(urls: [URL],
                                        regex: NSRegularExpression,
                                        template: String,
                                        excludedLinesByURL: [URL: Set<Int>])
        async -> ReplaceSummary
    {
        var summary = ReplaceSummary()
        for url in urls {
            if Task.isCancelled { break }
            summary.filesScanned += 1
            do {
                let original = try Data(contentsOf: url)
                guard let text = String(data: original, encoding: .utf8) else {
                    summary.errors.append((url, "Not valid UTF-8"))
                    continue
                }
                let excludedLines = excludedLinesByURL[url] ?? []
                let count: Int
                let newText: String
                if excludedLines.isEmpty {
                    // Fast path: no per-line opt-outs ⇒ full-file regex
                    // pass. Same code we've used since Phase 4c.
                    let mutable = NSMutableString(string: text)
                    let range = NSRange(location: 0, length: mutable.length)
                    count = regex.replaceMatches(in: mutable,
                                                 options: [],
                                                 range: range,
                                                 withTemplate: template)
                    newText = mutable as String
                } else {
                    // Slow path: walk each match, skip the ones whose
                    // line number the user opted out of. We mutate from
                    // the END of the string forward so earlier offsets
                    // stay valid as we splice in the replacement text.
                    let nsText = text as NSString
                    let lineStarts = Self.lineStartOffsets(in: text)
                    let allMatches = regex.matches(
                        in: text,
                        options: [],
                        range: NSRange(location: 0, length: nsText.length)
                    )
                    let mutable = NSMutableString(string: text)
                    var localCount = 0
                    for m in allMatches.reversed() {
                        let lineNumber = Self.lineNumber(forUTF16Offset: m.range.location,
                                                         lineStarts: lineStarts)
                        if excludedLines.contains(lineNumber) { continue }
                        let replacement = regex.replacementString(
                            for: m, in: text, offset: 0, template: template
                        )
                        mutable.replaceCharacters(in: m.range, with: replacement)
                        localCount += 1
                    }
                    count = localCount
                    newText = mutable as String
                }
                if count == 0 { continue }

                guard let bytes = newText.data(using: .utf8) else {
                    summary.errors.append((url, "Re-encoded text is not UTF-8"))
                    continue
                }
                // .atomic = write to sibling temp file + rename, so a
                // crash mid-write never leaves a partially-written file.
                try bytes.write(to: url, options: .atomic)
                summary.filesChanged += 1
                summary.totalReplacements += count
            } catch {
                summary.errors.append((url, error.localizedDescription))
            }
        }
        return summary
    }

    /// Sorted UTF-16 offsets of each line start. lineStarts[i] is the
    /// 0-based UTF-16 offset of the start of the (i+1)-th line. Used
    /// by `lineNumber(forUTF16Offset:)` to map a match offset back to
    /// the 1-based line number the UI reports.
    private nonisolated static func lineStartOffsets(in text: String) -> [Int] {
        var out: [Int] = [0]
        let ns = text as NSString
        let length = ns.length
        var i = 0
        while i < length {
            let ch = ns.character(at: i)
            if ch == 0x0A {                          // LF
                out.append(i + 1)
            } else if ch == 0x0D {                   // CR / CRLF
                if i + 1 < length, ns.character(at: i + 1) == 0x0A {
                    i += 1                            // consume LF, count once
                }
                out.append(i + 1)
            }
            i += 1
        }
        return out
    }

    /// 1-based line number containing a given UTF-16 offset. Binary
    /// search keeps replace passes on multi-MB files responsive.
    private nonisolated static func lineNumber(forUTF16Offset offset: Int,
                                               lineStarts: [Int]) -> Int {
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo + 1
    }

    // MARK: - Implementation

    private nonisolated func run(options: FindInFilesOptions,
                                 root: URL,
                                 regex: NSRegularExpression?,
                                 into state: FindInFilesState) async {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            await MainActor.run { state.setSearching(false) }
            return
        }

        var collected: [FileResult] = []
        var total = 0
        var scanned = 0
        var withMatches = 0
        var pendingFlush = 0

        // Swift 6 strict concurrency disallows `for case let url as URL
        // in enumerator` from an async context (`makeIterator` is
        // `@available(*, unavailable)` for FileManager.DirectoryEnumerator
        // there). The `nextObject()` loop is the equivalent C-style
        // walk and is fine in async code.
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            if Task.isCancelled { break }

            // Directory pruning happens via skipDescendants on the enumerator.
            let lastComponent = url.lastPathComponent
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                if IgnoredPaths.shouldSkipDirectory(named: lastComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            // Hidden files
            if lastComponent.hasPrefix(".") { continue }

            if !Self.matchesGlobs(name: lastComponent,
                                  include: options.includeGlobs,
                                  exclude: options.excludeGlobs) {
                continue
            }

            // Size + binary gate
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attrs?.isRegularFile == true else { continue }
            if let size = attrs?.fileSize, size > Self.maxBytesPerFile { continue }

            scanned += 1

            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            if Self.looksBinary(data) { continue }
            guard let text = String(data: data, encoding: .utf8) else { continue }

            let matches = Self.scan(text: text, query: options.query,
                                    options: options, regex: regex)
            if !matches.isEmpty {
                collected.append(FileResult(url: url, matches: matches))
                total += matches.count
                withMatches += 1
            }

            // Flush every 25 files so the UI animates rather than
            // jumps from "Searching…" to a finished list.
            pendingFlush += 1
            if pendingFlush >= 25 {
                pendingFlush = 0
                let snapshot = collected
                let totalSnapshot = total
                let scannedSnapshot = scanned
                let withMatchesSnapshot = withMatches
                await MainActor.run {
                    state.update(results: snapshot,
                                 totalMatches: totalSnapshot,
                                 filesScanned: scannedSnapshot,
                                 filesWithMatches: withMatchesSnapshot)
                }
            }
        }

        // Final flush.
        let finalSnapshot = collected
        let totalFinal = total
        let scannedFinal = scanned
        let withMatchesFinal = withMatches
        await MainActor.run {
            state.update(results: finalSnapshot,
                         totalMatches: totalFinal,
                         filesScanned: scannedFinal,
                         filesWithMatches: withMatchesFinal)
            state.setSearching(false)
        }
    }

    // MARK: - Regex / scan

    private nonisolated func buildRegex(options: FindInFilesOptions) throws -> NSRegularExpression? {
        var pattern = options.query
        if !options.regex {
            pattern = NSRegularExpression.escapedPattern(for: pattern)
        }
        if options.wholeWord {
            pattern = "\\b" + pattern + "\\b"
        }
        var nsOptions: NSRegularExpression.Options = []
        if !options.matchCase { nsOptions.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: nsOptions)
    }

    private nonisolated static func scan(text: String,
                                         query: String,
                                         options: FindInFilesOptions,
                                         regex: NSRegularExpression?) -> [LineMatch] {
        guard let regex else { return [] }
        var out: [LineMatch] = []
        var lineNumber = 0
        text.enumerateLines { line, stop in
            lineNumber += 1
            let nsLine = line as NSString
            let nsRange = NSRange(location: 0, length: nsLine.length)
            let matches = regex.matches(in: line, options: [], range: nsRange)
            if !matches.isEmpty {
                let ranges = matches.map { $0.range.lowerBound..<$0.range.upperBound }
                out.append(LineMatch(lineNumber: lineNumber,
                                     lineText: line,
                                     matchRanges: ranges))
                if out.count >= maxMatchesPerFile { stop = true }
            }
        }
        return out
    }

    // MARK: - Helpers

    /// Quick-and-dirty binary check: a NUL in the first 8 KB is a strong
    /// signal that the file isn't text. Matches what ripgrep does.
    private nonisolated static func looksBinary(_ data: Data) -> Bool {
        let head = data.prefix(8 * 1024)
        return head.contains(0)
    }

    /// True if `name` passes the include filter (matches at least one
    /// pattern, or include is empty) and the exclude filter (matches no
    /// pattern). Glob translation: `*` and `?` only — anything fancier
    /// can come later.
    private nonisolated static func matchesGlobs(name: String,
                                                 include: [String],
                                                 exclude: [String]) -> Bool {
        if !include.isEmpty {
            let any = include.contains { matchGlob(name: name, pattern: $0) }
            if !any { return false }
        }
        if exclude.contains(where: { matchGlob(name: name, pattern: $0) }) {
            return false
        }
        return true
    }

    private nonisolated static func matchGlob(name: String, pattern: String) -> Bool {
        // Translate *.swift → ^.*\.swift$, ?.txt → ^.\.txt$, etc.
        var regexPattern = "^"
        for ch in pattern {
            switch ch {
            case "*": regexPattern.append(".*")
            case "?": regexPattern.append(".")
            case ".", "+", "(", ")", "[", "]", "{", "}", "|", "^", "$", "\\":
                regexPattern.append("\\")
                regexPattern.append(ch)
            default: regexPattern.append(ch)
            }
        }
        regexPattern.append("$")
        guard let re = try? NSRegularExpression(pattern: regexPattern,
                                                options: [.caseInsensitive]) else {
            return false
        }
        let nsName = name as NSString
        let r = NSRange(location: 0, length: nsName.length)
        return re.firstMatch(in: name, options: [], range: r) != nil
    }
}
