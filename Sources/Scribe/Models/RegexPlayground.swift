//
//  RegexPlayground.swift
//  Phase 41e — pure model for the Regex Playground sheet. Wraps
//  `NSRegularExpression` so the SwiftUI surface can stay focused
//  on layout: it asks for matches, gets back a list of `Match`
//  records (each carrying its full range plus capture groups),
//  and renders the rest.
//
//  The model deliberately does NOT do its own attributed-string
//  rendering — that lives in the view. Keeping the model purely
//  data lets unit tests assert structure without dragging AppKit
//  highlighting into the test target.
//

import Foundation

enum RegexPlayground {

    enum RegexError: Error, Equatable {
        /// Pattern itself is invalid. `reason` is whatever NSRegularExpression
        /// surfaces (we strip the leading "Error Domain=…" noise).
        case invalidPattern(String)
    }

    /// User-facing toggle bag for regex evaluation. Mirrors the
    /// flags every regex GUI tool ships: case sensitivity, `^` / `$`
    /// scope, `.` newline behaviour, and free-spacing comment
    /// support. Mapped to NSRegularExpression.Options at compile
    /// time.
    struct Options: Equatable {
        var caseInsensitive: Bool = false
        /// `^` and `$` match line bounds, not just string bounds.
        var multiline: Bool = false
        /// `.` matches `\n`. Off by default — most users expect `.`
        /// to stop at newlines (the legacy behaviour).
        var dotAll: Bool = false
        /// Free-spacing mode: whitespace and `# comment` are ignored.
        var allowComments: Bool = false

        var asNSOptions: NSRegularExpression.Options {
            var o: NSRegularExpression.Options = []
            if caseInsensitive { o.insert(.caseInsensitive) }
            if multiline       { o.insert(.anchorsMatchLines) }
            if dotAll          { o.insert(.dotMatchesLineSeparators) }
            if allowComments   { o.insert(.allowCommentsAndWhitespace) }
            return o
        }
    }

    /// One regex match in a subject string. Ranges are NSRange (UTF-16
    /// offsets) so they line up with the AttributedString surface
    /// SwiftUI renders. `groups` is index-aligned: `groups[0]` is the
    /// full match, `groups[1...]` are the capture groups (each
    /// optional because a group can be missing if its alternation
    /// branch didn't fire).
    struct Match: Equatable {
        let range: NSRange
        let value: String
        let groups: [String?]
    }

    /// Compile + run `pattern` over `subject` with `options`. Returns
    /// every match in document order. Throws `.invalidPattern` only
    /// — a successfully-compiled regex that finds nothing returns
    /// `[]` so the UI can render "no matches" without a try/catch.
    static func matches(in subject: String,
                        pattern: String,
                        options: Options = Options()) throws -> [Match]
    {
        guard !pattern.isEmpty else { return [] }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern,
                                            options: options.asNSOptions)
        } catch {
            throw RegexError.invalidPattern(humanise(error))
        }
        let ns = subject as NSString
        let nsLen = ns.length
        let range = NSRange(location: 0, length: nsLen)
        var out: [Match] = []
        regex.enumerateMatches(in: subject,
                               options: [],
                               range: range) { result, _, _ in
            guard let result else { return }
            var groups: [String?] = []
            groups.reserveCapacity(result.numberOfRanges)
            for i in 0..<result.numberOfRanges {
                let r = result.range(at: i)
                if r.location == NSNotFound {
                    groups.append(nil)
                } else {
                    groups.append(ns.substring(with: r))
                }
            }
            let full = result.range(at: 0)
            let value = ns.substring(with: full)
            out.append(Match(range: full, value: value, groups: groups))
        }
        return out
    }

    /// Apply `template` as an NSRegularExpression replacement string
    /// against every match. Capture-group references (`$1`, `$&`)
    /// resolve through `NSRegularExpression`. Returns the rewritten
    /// subject; throws on invalid pattern (same as `matches`).
    static func replace(in subject: String,
                        pattern: String,
                        template: String,
                        options: Options = Options()) throws -> String
    {
        guard !pattern.isEmpty else { return subject }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern,
                                            options: options.asNSOptions)
        } catch {
            throw RegexError.invalidPattern(humanise(error))
        }
        let ns = subject as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: subject,
                                              options: [],
                                              range: range,
                                              withTemplate: template)
    }

    /// NSRegularExpression's `localizedDescription` is fine but the
    /// default error string starts with "Error Domain=…". Strip
    /// that so toasts read cleanly.
    private static func humanise(_ error: Error) -> String {
        let raw = (error as NSError).localizedDescription
        if let r = raw.range(of: "userInfo") {
            return String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }
}
