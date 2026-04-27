//
//  DiffEngine.swift
//  Phase 5 — line-level Myers (1986) diff. Returns a flat `[DiffOp]` list
//  where each op covers a contiguous run of equal / delete / insert / replace
//  lines. Pure Swift, no third-party deps.
//
//  Complexity: O((N+M) * D) where D is the edit distance. For typical
//  source files (a few thousand lines, small diffs) this finishes in
//  milliseconds.
//

import Foundation

public struct DiffOp: Equatable, Sendable {
    public enum Kind: Sendable {
        case equal
        case delete
        case insert
        case replace
    }

    public let kind: Kind
    /// Half-open line range in the *left* (old) file. Empty for pure insertions.
    public let leftRange: Range<Int>
    /// Half-open line range in the *right* (new) file. Empty for pure deletions.
    public let rightRange: Range<Int>

    public var leftCount: Int { leftRange.count }
    public var rightCount: Int { rightRange.count }
}

public struct DiffResult: Sendable {
    public let leftLines: [String]
    public let rightLines: [String]
    public let ops: [DiffOp]

    public var stats: (added: Int, removed: Int, changed: Int) {
        var added = 0, removed = 0, changed = 0
        for op in ops {
            switch op.kind {
            case .equal: break
            case .insert:  added += op.rightCount
            case .delete:  removed += op.leftCount
            case .replace: changed += max(op.leftCount, op.rightCount)
            }
        }
        return (added, removed, changed)
    }
}

public enum DiffEngine {

    public static func compare(_ leftText: String, _ rightText: String) -> DiffResult {
        let leftLines  = splitLines(leftText)
        let rightLines = splitLines(rightText)
        let ops = diff(left: leftLines, right: rightLines)
        return DiffResult(leftLines: leftLines, rightLines: rightLines, ops: ops)
    }

    // MARK: - Line splitting

    /// Splits on \n / \r\n / \r and *keeps* empty trailing lines so a file
    /// ending in a newline produces N+1 line slots — matches Scintilla's
    /// own line counting.
    ///
    /// Implementation note: in Swift `\r\n` is a single grapheme, so we
    /// can't iterate with `for c in text` and check character-by-character.
    /// Instead, normalise both delimiters to `\n` and split.
    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n",
                                omittingEmptySubsequences: false)
                         .map(String.init)
    }

    // MARK: - Myers core

    /// Returns a flat list of ops covering every line in both inputs in order.
    /// Adjacent delete + insert pairs are merged into a single `.replace` so
    /// the UI can show change blocks as one unit.
    static func diff(left a: [String], right b: [String]) -> [DiffOp] {
        // Trace ('V's) of the forward Myers walk so we can backtrack a path.
        let n = a.count
        let m = b.count
        let max_ = n + m
        if max_ == 0 { return [] }

        // V indexed by k offset by max_ to dodge negatives.
        var trace: [[Int]] = []
        trace.reserveCapacity(max_ + 1)

        var v = [Int](repeating: 0, count: 2 * max_ + 1)
        let offset = max_

        var foundD = 0
        outer: for d in 0...max_ {
            // Snapshot before mutation so backtracking can replay each step.
            trace.append(v)
            var k = -d
            while k <= d {
                let kIdx = k + offset
                var x: Int
                if k == -d || (k != d && v[kIdx - 1] < v[kIdx + 1]) {
                    x = v[kIdx + 1]
                } else {
                    x = v[kIdx - 1] + 1
                }
                var y = x - k
                // Snake — extend through matching prefix.
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[kIdx] = x
                if x >= n, y >= m {
                    foundD = d
                    break outer
                }
                k += 2
            }
        }

        // Backtrack to recover the edit script.
        var script: [DiffOp] = []
        var x = n
        var y = m
        for d in stride(from: foundD, through: 1, by: -1) {
            let vPrev = trace[d]
            let k = x - y
            let kIdx = k + offset
            let down = (k == -d) || (k != d && vPrev[kIdx - 1] < vPrev[kIdx + 1])
            let prevK = down ? k + 1 : k - 1
            let prevX = vPrev[prevK + offset]
            let prevY = prevX - prevK

            // Trailing snake of equals (these run from (prevX, prevY) … (x or x-1, y or y-1)).
            while x > prevX, y > prevY, x > 0, y > 0, a[x - 1] == b[y - 1] {
                appendEqual(into: &script, leftIndex: x - 1, rightIndex: y - 1)
                x -= 1
                y -= 1
            }
            if d > 0 {
                if down {
                    // Insertion of b[prevY]
                    appendInsert(into: &script, rightIndex: y - 1)
                    y -= 1
                } else {
                    // Deletion of a[prevX]
                    appendDelete(into: &script, leftIndex: x - 1)
                    x -= 1
                }
            }
        }
        // Initial common prefix (d == 0 leg).
        while x > 0, y > 0, a[x - 1] == b[y - 1] {
            appendEqual(into: &script, leftIndex: x - 1, rightIndex: y - 1)
            x -= 1
            y -= 1
        }

        // The script was built tail-first; reverse + reduce.
        script.reverse()
        return anchorEmptyRanges(reduce(ops: script))
    }

    /// `.insert` / `.delete` ops have one empty range; the builders left
    /// it as `0..<0`. Walk the ops in order and replace the empty range
    /// with `cursor..<cursor` so consumers can iterate either side
    /// without special-casing pure insertions / deletions.
    private static func anchorEmptyRanges(_ ops: [DiffOp]) -> [DiffOp] {
        var leftCursor = 0
        var rightCursor = 0
        var out: [DiffOp] = []
        out.reserveCapacity(ops.count)
        for op in ops {
            let left: Range<Int>
            let right: Range<Int>
            switch op.kind {
            case .equal, .replace:
                left = op.leftRange
                right = op.rightRange
            case .delete:
                left = op.leftRange
                right = rightCursor..<rightCursor
            case .insert:
                left = leftCursor..<leftCursor
                right = op.rightRange
            }
            out.append(DiffOp(kind: op.kind, leftRange: left, rightRange: right))
            leftCursor = left.upperBound
            rightCursor = right.upperBound
        }
        return out
    }

    // MARK: - Builder helpers

    /// Append a single-line equal step, expanding the previous op if it's
    /// already equal + contiguous.
    private static func appendEqual(into script: inout [DiffOp],
                                    leftIndex: Int,
                                    rightIndex: Int) {
        if let last = script.last,
           last.kind == .equal,
           last.leftRange.lowerBound == leftIndex + 1,
           last.rightRange.lowerBound == rightIndex + 1 {
            script[script.count - 1] = DiffOp(
                kind: .equal,
                leftRange: leftIndex..<last.leftRange.upperBound,
                rightRange: rightIndex..<last.rightRange.upperBound
            )
            return
        }
        script.append(DiffOp(
            kind: .equal,
            leftRange: leftIndex..<(leftIndex + 1),
            rightRange: rightIndex..<(rightIndex + 1)
        ))
    }

    private static func appendDelete(into script: inout [DiffOp],
                                     leftIndex: Int) {
        if let last = script.last,
           last.kind == .delete,
           last.leftRange.lowerBound == leftIndex + 1 {
            script[script.count - 1] = DiffOp(
                kind: .delete,
                leftRange: leftIndex..<last.leftRange.upperBound,
                rightRange: last.rightRange
            )
            return
        }
        script.append(DiffOp(
            kind: .delete,
            leftRange: leftIndex..<(leftIndex + 1),
            rightRange: 0..<0
        ))
    }

    private static func appendInsert(into script: inout [DiffOp],
                                     rightIndex: Int) {
        if let last = script.last,
           last.kind == .insert,
           last.rightRange.lowerBound == rightIndex + 1 {
            script[script.count - 1] = DiffOp(
                kind: .insert,
                leftRange: last.leftRange,
                rightRange: rightIndex..<last.rightRange.upperBound
            )
            return
        }
        script.append(DiffOp(
            kind: .insert,
            leftRange: 0..<0,
            rightRange: rightIndex..<(rightIndex + 1)
        ))
    }

    // MARK: - Coalescing

    /// Merges adjacent delete + insert (in either order) into a single
    /// `.replace`, and fixes up empty ranges so the consumer can iterate
    /// without special-casing.
    private static func reduce(ops: [DiffOp]) -> [DiffOp] {
        var out: [DiffOp] = []
        var i = 0
        while i < ops.count {
            let cur = ops[i]
            // Look one step ahead for the delete↔insert merge.
            if i + 1 < ops.count {
                let nxt = ops[i + 1]
                if (cur.kind == .delete && nxt.kind == .insert) ||
                   (cur.kind == .insert && nxt.kind == .delete) {
                    let left = cur.kind == .delete ? cur.leftRange : nxt.leftRange
                    let right = cur.kind == .insert ? cur.rightRange : nxt.rightRange
                    out.append(DiffOp(kind: .replace,
                                      leftRange: left,
                                      rightRange: right))
                    i += 2
                    continue
                }
            }
            out.append(cur)
            i += 1
        }
        return out
    }
}
