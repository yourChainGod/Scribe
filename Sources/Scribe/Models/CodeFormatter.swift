//
//  CodeFormatter.swift
//  Phase 41c — language-aware Pretty / Minify for JSON / XML / CSS /
//  SQL. Each language is its own namespace inside `CodeFormatter` so
//  a future tweak to one (SQL keyword expansion, XML attribute
//  alignment, …) won't risk leaking into the others.
//
//  Design choices
//    • Custom tokenizers (no Foundation `JSONSerialization`) so that
//      JSON object key order is preserved — what you typed in is
//      what comes out re-flowed, not what the runtime hash table
//      decides to emit.
//    • Pretty + Minify are *paired* per language. Both go through
//      the same tokenizer so a Pretty → Minify → Pretty round trip
//      is idempotent on the canonical form.
//    • Failure is signalled with `FormatError.invalid(reason)`.
//      The reason string lands in the toast so the user can spot
//      "Unterminated string at offset N" without diving into the
//      console.
//    • These are *80% formatters* — they cover the cases an editor
//      user actually pastes (config JSON, RSS feeds, design tokens,
//      hand-written queries). They are NOT spec-complete pretty
//      printers; HTML5 lenient parsing, full SCSS, dialect-specific
//      SQL all stay out of scope.
//

import Foundation

enum CodeFormatter {

    enum FormatError: Error, Equatable {
        /// Free-form, human-readable reason. Surface verbatim in toasts.
        case invalid(String)
    }

    // MARK: - JSON

    /// Order-preserving JSON pretty / minify. Built on a custom
    /// tokenizer instead of `JSONSerialization` because the latter
    /// returns `NSDictionary`, whose iteration order is not defined.
    /// For developer tooling we want pretty(input) to keep the keys
    /// in the order the author wrote them.
    enum JSON {
        struct Token: Equatable {
            enum Kind: Equatable {
                case lbrace, rbrace
                case lbracket, rbracket
                case colon, comma
                case string
                case primitive   // number, true, false, null
            }
            let kind: Kind
            let raw: String
        }

        static func pretty(_ s: String, indent: Int = 2) throws -> String {
            let tokens = try tokenize(s)
            if tokens.isEmpty { return "" }
            return render(tokens, indent: indent)
        }

        static func minify(_ s: String) throws -> String {
            let tokens = try tokenize(s)
            return tokens.map { $0.raw }.joined()
        }

        // MARK: tokenizer

        static func tokenize(_ s: String) throws -> [Token] {
            var tokens: [Token] = []
            var i = s.startIndex
            while i < s.endIndex {
                let ch = s[i]
                if ch.isWhitespace {
                    i = s.index(after: i); continue
                }
                switch ch {
                case "{": tokens.append(.init(kind: .lbrace,   raw: "{")); i = s.index(after: i)
                case "}": tokens.append(.init(kind: .rbrace,   raw: "}")); i = s.index(after: i)
                case "[": tokens.append(.init(kind: .lbracket, raw: "[")); i = s.index(after: i)
                case "]": tokens.append(.init(kind: .rbracket, raw: "]")); i = s.index(after: i)
                case ":": tokens.append(.init(kind: .colon,    raw: ":")); i = s.index(after: i)
                case ",": tokens.append(.init(kind: .comma,    raw: ",")); i = s.index(after: i)
                case "\"":
                    let (raw, next) = try readString(s, from: i)
                    tokens.append(.init(kind: .string, raw: raw))
                    i = next
                default:
                    let (raw, next) = readPrimitive(s, from: i)
                    if raw.isEmpty {
                        throw FormatError.invalid("Unexpected character '\(ch)' in JSON")
                    }
                    tokens.append(.init(kind: .primitive, raw: raw))
                    i = next
                }
            }
            return tokens
        }

        private static func readString(_ s: String,
                                        from start: String.Index)
            throws -> (String, String.Index)
        {
            // s[start] == "\""
            var i = s.index(after: start)
            while i < s.endIndex {
                let ch = s[i]
                if ch == "\\" {
                    // Skip escape pair. We don't validate the escape
                    // body — round-tripping verbatim is fine for
                    // pretty/minify; a malformed `\u` will still
                    // round-trip the way the user wrote it.
                    i = s.index(after: i)
                    if i < s.endIndex { i = s.index(after: i) }
                    continue
                }
                if ch == "\"" {
                    let end = s.index(after: i)
                    return (String(s[start..<end]), end)
                }
                i = s.index(after: i)
            }
            throw FormatError.invalid("Unterminated string in JSON")
        }

        private static func readPrimitive(_ s: String,
                                          from start: String.Index)
            -> (String, String.Index)
        {
            let stoppers: Set<Character> = [
                "{", "}", "[", "]", ",", ":",
                " ", "\t", "\n", "\r"
            ]
            var i = start
            while i < s.endIndex, !stoppers.contains(s[i]) {
                i = s.index(after: i)
            }
            return (String(s[start..<i]), i)
        }

        // MARK: renderer

        private static func render(_ tokens: [Token], indent: Int) -> String {
            let pad = String(repeating: " ", count: max(0, indent))
            func indentString(_ d: Int) -> String {
                String(repeating: pad, count: max(0, d))
            }

            var out = ""
            var depth = 0
            var i = 0
            while i < tokens.count {
                let t = tokens[i]
                switch t.kind {
                case .lbrace, .lbracket:
                    // Empty container? Emit `{}` / `[]` flat.
                    let closer: Token.Kind = (t.kind == .lbrace) ? .rbrace : .rbracket
                    if i + 1 < tokens.count, tokens[i + 1].kind == closer {
                        out.append(t.raw)
                        out.append(tokens[i + 1].raw)
                        i += 2
                        continue
                    }
                    out.append(t.raw)
                    depth += 1
                    out.append("\n")
                    out.append(indentString(depth))
                case .rbrace, .rbracket:
                    depth = max(0, depth - 1)
                    out.append("\n")
                    out.append(indentString(depth))
                    out.append(t.raw)
                case .colon:
                    out.append(": ")
                case .comma:
                    out.append(",\n")
                    out.append(indentString(depth))
                case .string, .primitive:
                    out.append(t.raw)
                }
                i += 1
            }
            return out
        }
    }

    // MARK: - XML / HTML (lenient)

    /// XML pretty / minify. Lenient: handles tags / comments / CDATA
    /// / processing instructions / DOCTYPE. Self-closing tags and
    /// `<?xml ...?>` don't bump depth. Text runs are trimmed of
    /// surrounding whitespace at pretty time so reflowed RSS / SVG
    /// becomes readable.
    enum XML {
        enum NodeKind { case open, close, selfClose, comment, pi, doctype, cdata, text }
        struct Node { let kind: NodeKind; let raw: String }

        static func pretty(_ s: String, indent: Int = 2) throws -> String {
            let nodes = try tokenize(s)
            if nodes.isEmpty { return "" }
            let pad = String(repeating: " ", count: max(0, indent))
            var out = ""
            var depth = 0
            for node in nodes {
                switch node.kind {
                case .text:
                    let trimmed = node.raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    out.append(String(repeating: pad, count: depth))
                    out.append(trimmed)
                    out.append("\n")
                case .close:
                    depth = max(0, depth - 1)
                    out.append(String(repeating: pad, count: depth))
                    out.append(node.raw)
                    out.append("\n")
                case .open:
                    out.append(String(repeating: pad, count: depth))
                    out.append(node.raw)
                    out.append("\n")
                    depth += 1
                case .selfClose, .comment, .pi, .doctype, .cdata:
                    out.append(String(repeating: pad, count: depth))
                    out.append(node.raw)
                    out.append("\n")
                }
            }
            if out.hasSuffix("\n") { out.removeLast() }
            return out
        }

        static func minify(_ s: String) throws -> String {
            let nodes = try tokenize(s)
            var out = ""
            for node in nodes {
                if node.kind == .text {
                    let trimmed = node.raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(trimmed)
                } else {
                    out.append(node.raw)
                }
            }
            return out
        }

        static func tokenize(_ s: String) throws -> [Node] {
            var nodes: [Node] = []
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "<" {
                    if s[i...].hasPrefix("<!--") {
                        guard let end = s.range(of: "-->", range: i..<s.endIndex) else {
                            throw FormatError.invalid("Unterminated XML comment")
                        }
                        nodes.append(Node(kind: .comment,
                                          raw: String(s[i..<end.upperBound])))
                        i = end.upperBound
                        continue
                    }
                    if s[i...].hasPrefix("<![CDATA[") {
                        guard let end = s.range(of: "]]>", range: i..<s.endIndex) else {
                            throw FormatError.invalid("Unterminated CDATA section")
                        }
                        nodes.append(Node(kind: .cdata,
                                          raw: String(s[i..<end.upperBound])))
                        i = end.upperBound
                        continue
                    }
                    guard let end = s.range(of: ">", range: i..<s.endIndex) else {
                        throw FormatError.invalid("Unterminated XML tag")
                    }
                    let raw = String(s[i..<end.upperBound])
                    let bodyStart = s.index(after: i)
                    let body = s[bodyStart..<end.lowerBound]
                    let kind: NodeKind
                    if body.hasPrefix("?") {
                        kind = .pi
                    } else if body.hasPrefix("!") {
                        kind = .doctype
                    } else if body.hasPrefix("/") {
                        kind = .close
                    } else if body.hasSuffix("/") {
                        kind = .selfClose
                    } else {
                        kind = .open
                    }
                    nodes.append(Node(kind: kind, raw: raw))
                    i = end.upperBound
                } else {
                    var j = i
                    while j < s.endIndex, s[j] != "<" {
                        j = s.index(after: j)
                    }
                    nodes.append(Node(kind: .text, raw: String(s[i..<j])))
                    i = j
                }
            }
            return nodes
        }
    }

    // MARK: - CSS

    /// CSS pretty / minify. Handles `{` `}` `;` as structure, `/*…*/`
    /// as comments. Nesting (e.g. `@media`) is honoured by tracking
    /// brace depth. Selectors / declarations are trimmed but not
    /// otherwise rewritten, so `.x, .y` stays on one line.
    enum CSS {
        static func pretty(_ s: String, indent: Int = 2) throws -> String {
            let stripped = try stripComments(s)
            let pad = String(repeating: " ", count: max(0, indent))
            var out = ""
            var depth = 0
            var buffer = ""

            func flushSelector() {
                let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = ""
                if t.isEmpty { return }
                out.append(String(repeating: pad, count: depth))
                out.append(t)
                out.append(" {\n")
            }
            func flushDeclaration() {
                let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = ""
                if t.isEmpty { return }
                out.append(String(repeating: pad, count: depth))
                out.append(formatDeclaration(t))
                out.append(";\n")
            }

            var i = stripped.startIndex
            while i < stripped.endIndex {
                let ch = stripped[i]
                switch ch {
                case "{":
                    flushSelector()
                    depth += 1
                case "}":
                    // Last declaration before `}` may not have `;`.
                    let leftover = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer = ""
                    if !leftover.isEmpty {
                        out.append(String(repeating: pad, count: depth))
                        out.append(formatDeclaration(leftover))
                        out.append(";\n")
                    }
                    depth = max(0, depth - 1)
                    out.append(String(repeating: pad, count: depth))
                    out.append("}\n")
                case ";":
                    flushDeclaration()
                default:
                    buffer.append(ch)
                }
                i = stripped.index(after: i)
            }
            // Trailing leftover (no closing brace at file end).
            let leftover = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !leftover.isEmpty {
                out.append(String(repeating: pad, count: depth))
                out.append(leftover)
                out.append("\n")
            }
            if out.hasSuffix("\n") { out.removeLast() }
            return out
        }

        static func minify(_ s: String) throws -> String {
            let stripped = try stripComments(s)
            // Collapse whitespace runs (including newlines) to single
            // spaces, then drop the spaces that sit next to structural
            // punctuation. Preserve spaces *inside* selectors so the
            // descendant combinator (`a b`) survives.
            var collapsed = ""
            var lastWasSpace = false
            for ch in stripped {
                if ch.isWhitespace {
                    if !lastWasSpace, !collapsed.isEmpty {
                        collapsed.append(" ")
                        lastWasSpace = true
                    }
                } else {
                    collapsed.append(ch)
                    lastWasSpace = false
                }
            }
            let strip: Set<Character> = ["{", "}", ";", ":", ","]
            let arr = Array(collapsed)
            var out = ""
            for k in 0..<arr.count {
                let ch = arr[k]
                if ch == " " {
                    let prev = k > 0 ? arr[k - 1] : nil
                    let next = k + 1 < arr.count ? arr[k + 1] : nil
                    if let p = prev, strip.contains(p) { continue }
                    if let n = next, strip.contains(n) { continue }
                }
                out.append(ch)
            }
            // Drop the redundant `;` that sits immediately before a
            // `}` — minified CSS canonicalises `color:red;}` to
            // `color:red}` because the closing brace already implies
            // the end of the last declaration.
            var compact = ""
            let chars = Array(out)
            for k in 0..<chars.count {
                if chars[k] == ";",
                   k + 1 < chars.count,
                   chars[k + 1] == "}"
                {
                    continue
                }
                compact.append(chars[k])
            }
            return compact.trimmingCharacters(in: .whitespaces)
        }

        /// Insert a single space after the first `:` in a declaration
        /// so `font-weight:bold` becomes `font-weight: bold`. Skips
        /// declarations that don't have a `:` (rare, but @import etc.
        /// can land here when the trailing `;` was elided).
        private static func formatDeclaration(_ d: String) -> String {
            guard let colon = d.firstIndex(of: ":") else { return d }
            let key = d[..<colon].trimmingCharacters(in: .whitespaces)
            let val = d[d.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.isEmpty || val.isEmpty { return d }
            return "\(key): \(val)"
        }

        private static func stripComments(_ s: String) throws -> String {
            var out = ""
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "/",
                   s.index(after: i) < s.endIndex,
                   s[s.index(after: i)] == "*"
                {
                    guard let end = s.range(of: "*/", range: i..<s.endIndex) else {
                        throw FormatError.invalid("Unterminated CSS comment")
                    }
                    i = end.upperBound
                } else {
                    out.append(s[i])
                    i = s.index(after: i)
                }
            }
            return out
        }
    }

    // MARK: - SQL

    /// SQL pretty / minify. Pragmatic, dialect-light:
    ///  • Recognised keywords are upper-cased (outside string
    ///    literals — `'select'` data stays lowercase).
    ///  • Pretty inserts a newline before each *clause* keyword
    ///    (SELECT / FROM / WHERE / GROUP BY / ORDER BY / HAVING /
    ///    LIMIT / OFFSET / UNION / JOIN-variants / VALUES / SET /
    ///    ON / AND / OR).
    ///  • Minify collapses all whitespace runs to single spaces and
    ///    strips comments.
    enum SQL {
        /// Clauses that earn a fresh line in pretty output.
        /// Longer phrases first so "UNION ALL" wins over "UNION".
        private static let breakKeywords: [String] = [
            "UNION ALL",
            "INNER JOIN", "LEFT JOIN", "RIGHT JOIN",
            "FULL JOIN", "CROSS JOIN",
            "GROUP BY", "ORDER BY",
            "DELETE FROM", "INSERT INTO",
            "SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "OFFSET",
            "INTERSECT", "EXCEPT", "UNION",
            "JOIN", "VALUES", "SET", "ON",
            "AND", "OR"
        ]

        /// Every word we'll up-case. Includes the break keywords and
        /// other common SQL nouns so a query reads cleanly even if
        /// only a few clauses get newlines.
        private static let allKeywords: Set<String> = [
            "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "BY",
            "HAVING", "LIMIT", "OFFSET",
            "UNION", "ALL", "INTERSECT", "EXCEPT",
            "INSERT", "INTO", "VALUES",
            "UPDATE", "SET",
            "DELETE",
            "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "JOIN", "ON",
            "AND", "OR", "AS", "DISTINCT", "NOT", "IN", "IS", "NULL",
            "TRUE", "FALSE", "BETWEEN", "LIKE", "EXISTS",
            "CASE", "WHEN", "THEN", "ELSE", "END",
            "ASC", "DESC", "WITH",
            "CREATE", "TABLE", "DROP", "ALTER", "ADD", "COLUMN",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "INDEX",
            "CONSTRAINT", "UNIQUE", "DEFAULT", "CHECK"
        ]

        static func pretty(_ s: String) throws -> String {
            let normalized = normalize(s)
            let upcased = uppercaseKeywords(normalized)
            let withBreaks = insertNewlines(upcased)
            return withBreaks.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func minify(_ s: String) throws -> String {
            return normalize(s).trimmingCharacters(in: .whitespaces)
        }

        // MARK: helpers

        /// Strip comments and collapse whitespace to single spaces,
        /// outside string literals.
        private static func normalize(_ s: String) -> String {
            var out = ""
            var i = s.startIndex
            var lastWasSpace = false
            while i < s.endIndex {
                let ch = s[i]

                // String literal — copy verbatim.
                if ch == "'" || ch == "\"" {
                    let quote = ch
                    out.append(ch)
                    i = s.index(after: i)
                    while i < s.endIndex {
                        let c = s[i]
                        if c == "\\", s.index(after: i) < s.endIndex {
                            out.append(c)
                            i = s.index(after: i)
                            out.append(s[i])
                            i = s.index(after: i)
                            continue
                        }
                        out.append(c)
                        i = s.index(after: i)
                        if c == quote { break }
                    }
                    lastWasSpace = false
                    continue
                }

                // -- line comment
                if ch == "-",
                   s.index(after: i) < s.endIndex,
                   s[s.index(after: i)] == "-"
                {
                    while i < s.endIndex, s[i] != "\n" {
                        i = s.index(after: i)
                    }
                    continue
                }

                // /* block comment */
                if ch == "/",
                   s.index(after: i) < s.endIndex,
                   s[s.index(after: i)] == "*"
                {
                    if let end = s.range(of: "*/", range: i..<s.endIndex) {
                        i = end.upperBound
                    } else {
                        i = s.endIndex
                    }
                    continue
                }

                if ch.isWhitespace {
                    if !lastWasSpace, !out.isEmpty {
                        out.append(" ")
                        lastWasSpace = true
                    }
                    i = s.index(after: i)
                } else {
                    out.append(ch)
                    lastWasSpace = false
                    i = s.index(after: i)
                }
            }
            return out
        }

        /// Up-case every recognised keyword. Walks character by
        /// character so identifiers like `FROM_EMAIL` (one word)
        /// stay untouched while `from email` becomes `FROM email`.
        private static func uppercaseKeywords(_ s: String) -> String {
            var out = ""
            var i = s.startIndex
            while i < s.endIndex {
                let ch = s[i]

                if ch == "'" || ch == "\"" {
                    let quote = ch
                    out.append(ch)
                    i = s.index(after: i)
                    while i < s.endIndex {
                        out.append(s[i])
                        let c = s[i]
                        i = s.index(after: i)
                        if c == quote { break }
                    }
                    continue
                }

                if ch.isLetter || ch == "_" {
                    var j = i
                    while j < s.endIndex,
                          s[j].isLetter || s[j].isNumber || s[j] == "_"
                    {
                        j = s.index(after: j)
                    }
                    let word = String(s[i..<j])
                    let upper = word.uppercased()
                    if allKeywords.contains(upper) {
                        out.append(upper)
                    } else {
                        out.append(word)
                    }
                    i = j
                    continue
                }

                out.append(ch)
                i = s.index(after: i)
            }
            return out
        }

        /// Insert `\n` before each break keyword (already uppercased).
        /// Two-pass with placeholder markers so a longer phrase like
        /// "INNER JOIN" claims its match first and the bare "JOIN"
        /// pass that runs later can't re-cut it. Without this, the
        /// "JOIN" rewrite would split "INNER JOIN" into two lines.
        private static func insertNewlines(_ s: String) -> String {
            // Use control characters as markers — they cannot legally
            // appear in normalised SQL we just emitted, so a marker
            // collision is impossible by construction.
            let open: Character  = "\u{0001}"
            let close: Character = "\u{0002}"
            var result = s
            for (idx, kw) in breakKeywords.enumerated() {
                let needle = " " + kw + " "
                // Trailing space is restored after the marker so the
                // *next* keyword pass — which expects " KW " padding
                // — can still find a matching boundary. Without this,
                // chained breaks like " UNION ALL  SELECT " would
                // collapse and the inner SELECT would never split.
                let stand = "\(open)\(idx)\(close) "
                result = result.replacingOccurrences(of: needle, with: stand)
            }
            for (idx, kw) in breakKeywords.enumerated() {
                let marker = "\(open)\(idx)\(close)"
                let replacement = "\n" + kw
                result = result.replacingOccurrences(of: marker, with: replacement)
            }
            return result
        }
    }
}
