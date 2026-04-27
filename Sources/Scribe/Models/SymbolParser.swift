//
//  SymbolParser.swift
//  Phase 7 — regex-based symbol parsers, one per supported language.
//  Stays deliberately simple: line-by-line, anchored patterns, no
//  attempt at understanding nesting or scope. That's good enough for
//  a "jump to symbol" outline; full tree-sitter integration is a
//  later phase.
//
//  Adding a new language is one file change here:
//    1. Add a struct conforming to SymbolParser.
//    2. Wire it into SymbolParserCatalog.parser(forExtension:).
//

import Foundation

protocol SymbolParser: Sendable {
    /// Returns the symbol entries discovered in `text`, sorted by line
    /// number ascending. Implementations should be pure (no IO).
    func parse(_ text: String) -> [SymbolEntry]
}

/// Maps a file extension (lowercased, no leading dot) to the parser
/// that knows how to outline it.
enum SymbolParserCatalog {
    static func parser(forExtension ext: String) -> SymbolParser? {
        switch ext.lowercased() {
        case "swift":
            return SwiftSymbolParser()
        case "py", "pyi":
            return PythonSymbolParser()
        case "js", "jsx", "mjs", "cjs", "ts", "tsx":
            return JavaScriptSymbolParser()
        case "rs":
            return RustSymbolParser()
        case "go":
            return GoSymbolParser()
        case "md", "markdown":
            return MarkdownSymbolParser()
        case "c", "cpp", "cc", "cxx", "h", "hpp", "hh", "m", "mm":
            return CSymbolParser()
        default:
            return nil
        }
    }
}

// MARK: - Helpers shared by parsers

/// Compile a regex once per parser type. NSRegularExpression is
/// thread-safe so `static let` cached patterns are fine.
private func regex(_ pattern: String,
                   options: NSRegularExpression.Options = []) -> NSRegularExpression {
    // The patterns we ship are vetted in tests; force-try is acceptable.
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: pattern, options: options)
}

/// Walk `text` line by line, applying each (regex, pattern handler) in
/// `rules`. The handler turns a regex match on the line into a
/// SymbolEntry; returning nil skips it. Single pass over the text;
/// each line is tested against every rule in order until one matches.
///
/// `tracksBraces`: when true, scanLines maintains a running `{ } `
/// depth counter. Each emitted entry inherits that depth, and
/// .function entries that appear inside one or more `{` get
/// re-tagged as .method. This is the brace-balanced-language path
/// (Swift/JS/Rust/Go/C/Obj-C). Markdown / Python use the legacy
/// path because their nesting isn't expressed with `{` `}`.
///
/// Brace counting is intentionally naïve — strings and comments are
/// not stripped first. In practice, a misplaced `{` inside a string
/// literal makes one method look like a free function (or vice
/// versa) until the next balancing `}` brings the counter back; the
/// rest of the file is unaffected. Acceptable trade-off for an
/// outline that's purely a navigation aid.
private func scanLines(_ text: String,
                       rules: [(regex: NSRegularExpression,
                                make: (NSTextCheckingResult, String, Int) -> SymbolEntry?)],
                       tracksBraces: Bool = false)
    -> [SymbolEntry]
{
    var out: [SymbolEntry] = []
    var lineNumber = 0
    var braceDepth = 0
    text.enumerateLines { line, _ in
        lineNumber += 1
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        for rule in rules {
            if let m = rule.regex.firstMatch(in: line, options: [], range: range) {
                if var entry = rule.make(m, line, lineNumber) {
                    if tracksBraces {
                        // The line `class Foo {` declares Foo at the
                        // OUTER depth; the open brace only takes effect
                        // for subsequent lines. So we tag the entry
                        // BEFORE updating the brace counter.
                        entry.depth = braceDepth
                        // A function discovered while we're already
                        // inside something else (a class/struct/extension/
                        // namespace) is conventionally a method. Test
                        // functions stay .test — the test runner badge
                        // is more useful than the method designation.
                        if braceDepth > 0, entry.kind == .function {
                            entry.kind = .method
                        }
                    }
                    out.append(entry)
                }
                break   // one rule wins per line — keeps `func test_x` from
                        // appearing as both .function AND .test
            }
        }
        if tracksBraces {
            // Update AFTER emitting so the symbol on this line keeps
            // the outer depth (see comment above).
            for ch in line {
                if ch == "{" { braceDepth += 1 }
                else if ch == "}" { braceDepth = max(0, braceDepth - 1) }
            }
        }
    }
    return out
}

/// Extract the captured group (1-based) from a match against `line`.
/// Returns "" if the group is missing — better than crashing on a
/// regex authoring slip.
private func capture(_ match: NSTextCheckingResult,
                     group: Int,
                     in line: String) -> String {
    guard group < match.numberOfRanges else { return "" }
    let r = match.range(at: group)
    guard r.location != NSNotFound else { return "" }
    let ns = line as NSString
    return ns.substring(with: r)
}

// MARK: - Swift

struct SwiftSymbolParser: SymbolParser {
    private static let modifiers =
        "(?:public |private |internal |fileprivate |open |final |static |class |override |dynamic )*"

    private static let funcRule = regex(
        "^\\s*\(modifiers)func\\s+([A-Za-z_][A-Za-z0-9_]*)"
    )
    private static let typeRule = regex(
        "^\\s*\(modifiers)(class|struct|enum|protocol|extension|actor)\\s+([A-Za-z_][A-Za-z0-9_]*)"
    )
    private static let typealiasRule = regex(
        "^\\s*\(modifiers)typealias\\s+([A-Za-z_][A-Za-z0-9_]*)"
    )
    private static let propertyRule = regex(
        "^\\s*\(modifiers)(?:lazy\\s+)?(?:var|let)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*[:=]"
    )

    func parse(_ text: String) -> [SymbolEntry] {
        scanLines(text, rules: [
            (Self.funcRule, { m, line, ln in
                let name = capture(m, group: 1, in: line)
                let kind: SymbolKind = name.hasPrefix("test")
                    ? .test
                    : .function
                return SymbolEntry(kind: kind, name: name, lineNumber: ln)
            }),
            (Self.typeRule, { m, line, ln in
                let keyword = capture(m, group: 1, in: line)
                let name = capture(m, group: 2, in: line)
                let kind: SymbolKind
                switch keyword {
                case "class", "actor": kind = .classDecl
                case "struct":         kind = .structDecl
                case "enum":           kind = .enumDecl
                case "protocol":       kind = .protocolDecl
                case "extension":      kind = .extensionDecl
                default:               kind = .classDecl
                }
                return SymbolEntry(kind: kind, name: name, lineNumber: ln)
            }),
            (Self.typealiasRule, { m, line, ln in
                let name = capture(m, group: 1, in: line)
                return SymbolEntry(kind: .typealiasDecl, name: name, lineNumber: ln)
            }),
            (Self.propertyRule, { m, line, ln in
                let name = capture(m, group: 1, in: line)
                return SymbolEntry(kind: .property, name: name, lineNumber: ln)
            }),
        ], tracksBraces: true)
    }
}

// MARK: - Python

struct PythonSymbolParser: SymbolParser {
    private static let funcRule = regex(
        "^\\s*(?:async\\s+)?def\\s+([A-Za-z_][A-Za-z0-9_]*)"
    )
    private static let classRule = regex(
        "^\\s*class\\s+([A-Za-z_][A-Za-z0-9_]*)"
    )

    func parse(_ text: String) -> [SymbolEntry] {
        scanLines(text, rules: [
            (Self.funcRule, { m, line, ln in
                let name = capture(m, group: 1, in: line)
                let kind: SymbolKind = name.hasPrefix("test_") ? .test : .function
                return SymbolEntry(kind: kind, name: name, lineNumber: ln)
            }),
            (Self.classRule, { m, line, ln in
                let name = capture(m, group: 1, in: line)
                return SymbolEntry(kind: .classDecl, name: name, lineNumber: ln)
            }),
        ])
    }
}

// MARK: - JavaScript / TypeScript

struct JavaScriptSymbolParser: SymbolParser {
    // Top-level function declaration: function foo(...
    private static let funcDeclRule = regex(
        "^\\s*(?:export\\s+)?(?:async\\s+)?function\\s+\\*?\\s*([A-Za-z_$][A-Za-z0-9_$]*)"
    )
    // class Foo {  (allow `extends X` etc. on the same line)
    private static let classRule = regex(
        "^\\s*(?:export\\s+(?:default\\s+)?)?(?:abstract\\s+)?class\\s+([A-Za-z_$][A-Za-z0-9_$]*)"
    )
    // const foo = (...) => { … } / const foo = function …
    private static let arrowRule = regex(
        "^\\s*(?:export\\s+)?(?:const|let|var)\\s+([A-Za-z_$][A-Za-z0-9_$]*)\\s*=\\s*(?:async\\s+)?(?:\\([^)]*\\)\\s*=>|function)"
    )
    // TypeScript: interface Foo {
    private static let interfaceRule = regex(
        "^\\s*(?:export\\s+)?interface\\s+([A-Za-z_$][A-Za-z0-9_$]*)"
    )
    // TypeScript: type Foo = ... or type Foo<T, U> = ...
    private static let typeRule = regex(
        "^\\s*(?:export\\s+)?type\\s+([A-Za-z_$][A-Za-z0-9_$]*)(?:\\s*<[^>]*>)?\\s*="
    )

    func parse(_ text: String) -> [SymbolEntry] {
        scanLines(text, rules: [
            (Self.funcDeclRule, { m, line, ln in
                let name = capture(m, group: 1, in: line)
                let kind: SymbolKind = name.hasPrefix("test") ? .test : .function
                return SymbolEntry(kind: kind, name: name, lineNumber: ln)
            }),
            (Self.classRule, { m, line, ln in
                SymbolEntry(kind: .classDecl,
                            name: capture(m, group: 1, in: line),
                            lineNumber: ln)
            }),
            (Self.arrowRule, { m, line, ln in
                SymbolEntry(kind: .function,
                            name: capture(m, group: 1, in: line),
                            lineNumber: ln)
            }),
            (Self.interfaceRule, { m, line, ln in
                SymbolEntry(kind: .protocolDecl,
                            name: capture(m, group: 1, in: line),
                            lineNumber: ln)
            }),
            (Self.typeRule, { m, line, ln in
                SymbolEntry(kind: .typealiasDecl,
                            name: capture(m, group: 1, in: line),
                            lineNumber: ln)
            }),
        ], tracksBraces: true)
    }
}

// MARK: - Rust

struct RustSymbolParser: SymbolParser {
    private static let funcRule = regex(
        "^\\s*(?:pub(?:\\([^)]*\\))?\\s+)?(?:async\\s+)?(?:unsafe\\s+)?(?:const\\s+)?fn\\s+([A-Za-z_][A-Za-z0-9_]*)"
    )
    private static let typeRule = regex(
        "^\\s*(?:pub(?:\\([^)]*\\))?\\s+)?(struct|enum|trait|impl|type|mod)\\s+([A-Za-z_][A-Za-z0-9_]*)"
    )

    func parse(_ text: String) -> [SymbolEntry] {
        scanLines(text, rules: [
            (Self.funcRule, { m, line, ln in
                let name = capture(m, group: 1, in: line)
                let kind: SymbolKind = name.hasPrefix("test_") ? .test : .function
                return SymbolEntry(kind: kind, name: name, lineNumber: ln)
            }),
            (Self.typeRule, { m, line, ln in
                let keyword = capture(m, group: 1, in: line)
                let name = capture(m, group: 2, in: line)
                let kind: SymbolKind
                switch keyword {
                case "struct":          kind = .structDecl
                case "enum":            kind = .enumDecl
                case "trait":           kind = .protocolDecl
                case "impl":            kind = .extensionDecl
                case "type":            kind = .typealiasDecl
                case "mod":             kind = .classDecl
                default:                kind = .structDecl
                }
                return SymbolEntry(kind: kind, name: name, lineNumber: ln)
            }),
        ], tracksBraces: true)
    }
}

// MARK: - Go

struct GoSymbolParser: SymbolParser {
    // func Foo(...) | func (r *T) Foo(...)
    private static let funcRule = regex(
        "^func\\s+(?:\\([^)]*\\)\\s+)?([A-Za-z_][A-Za-z0-9_]*)"
    )
    private static let typeRule = regex(
        "^type\\s+([A-Za-z_][A-Za-z0-9_]*)\\s+(struct|interface|=)"
    )

    func parse(_ text: String) -> [SymbolEntry] {
        scanLines(text, rules: [
            (Self.funcRule, { m, line, ln in
                let name = capture(m, group: 1, in: line)
                let kind: SymbolKind = name.hasPrefix("Test") ? .test : .function
                return SymbolEntry(kind: kind, name: name, lineNumber: ln)
            }),
            (Self.typeRule, { m, line, ln in
                let name = capture(m, group: 1, in: line)
                let keyword = capture(m, group: 2, in: line)
                let kind: SymbolKind
                switch keyword {
                case "struct":      kind = .structDecl
                case "interface":   kind = .protocolDecl
                default:            kind = .typealiasDecl
                }
                return SymbolEntry(kind: kind, name: name, lineNumber: ln)
            }),
        ], tracksBraces: true)
    }
}

// MARK: - Markdown

struct MarkdownSymbolParser: SymbolParser {
    private static let headingRule = regex("^(#{1,6})\\s+(.+?)\\s*#*\\s*$")

    func parse(_ text: String) -> [SymbolEntry] {
        scanLines(text, rules: [
            (Self.headingRule, { m, line, ln in
                let hashes = capture(m, group: 1, in: line)
                let title = capture(m, group: 2, in: line)
                return SymbolEntry(kind: .heading,
                                   name: title,
                                   lineNumber: ln,
                                   depth: hashes.count - 1)
            }),
        ])
    }
}

// MARK: - C / C++ / Objective-C

struct CSymbolParser: SymbolParser {
    // Best-effort: a line that starts with a return-type-ish token and
    // ends with `(` likely declares a function. Anchored to the
    // beginning of the line so we ignore inline calls.
    //
    // We accept type qualifiers and `static`/`inline` prefixes. Strict
    // C grammar is out of scope; this is good enough to populate the
    // outline.
    private static let funcRule = regex(
        "^\\s*(?:static\\s+|inline\\s+|extern\\s+|__attribute__[^)]*\\)\\s*)*"
        + "(?:[A-Za-z_][\\w*\\s]+\\s+)+"           // return type (one or more tokens, may end with *)
        + "([A-Za-z_][A-Za-z0-9_]*)\\s*\\("        // function name + open paren
    )
    // class Foo / struct Foo / enum Foo
    private static let typeRule = regex(
        "^\\s*(class|struct|enum)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*[\\{:;]"
    )

    func parse(_ text: String) -> [SymbolEntry] {
        scanLines(text, rules: [
            (Self.typeRule, { m, line, ln in
                let keyword = capture(m, group: 1, in: line)
                let name = capture(m, group: 2, in: line)
                let kind: SymbolKind
                switch keyword {
                case "class":   kind = .classDecl
                case "struct":  kind = .structDecl
                case "enum":    kind = .enumDecl
                default:        kind = .classDecl
                }
                return SymbolEntry(kind: kind, name: name, lineNumber: ln)
            }),
            (Self.funcRule, { m, line, ln in
                let name = capture(m, group: 1, in: line)
                // Filter out obvious false positives: `if`, `for`, ...
                let reserved: Set<String> = [
                    "if", "for", "while", "switch", "return", "sizeof",
                    "typeof", "static_assert"
                ]
                guard !reserved.contains(name) else { return nil }
                return SymbolEntry(kind: .function, name: name, lineNumber: ln)
            }),
        ], tracksBraces: true)
    }
}
