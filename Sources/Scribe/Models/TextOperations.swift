//
//  TextOperations.swift
//  Phase 37 — pure text split / merge / shuffle operations.
//

import CryptoKit
import Foundation

struct TextTable: Equatable {
    var rows: [[String]]

    var rowCount: Int {
        rows.count
    }

    var columnCount: Int {
        rows.map(\.count).max() ?? 0
    }

    static func mergeByRow(_ tables: TextTable...) -> TextTable {
        mergeByRow(tables)
    }

    static func mergeByRow(_ tables: [TextTable]) -> TextTable {
        let maxRows = tables.map(\.rowCount).max() ?? 0
        guard maxRows > 0 else { return TextTable(rows: []) }

        let widths = tables.map(\.columnCount)
        let rows = (0..<maxRows).map { rowIndex in
            tables.enumerated().flatMap { tableIndex, table in
                if table.rows.indices.contains(rowIndex) {
                    let row = table.rows[rowIndex]
                    let padding = max(0, widths[tableIndex] - row.count)
                    return row + Array(repeating: "", count: padding)
                }
                return Array(repeating: "", count: widths[tableIndex])
            }
        }
        return TextTable(rows: rows)
    }

    static func mergeByKey(primary: TextTable,
                           imported: [TextTable],
                           keyColumn: Int) -> TextTable {
        guard keyColumn >= 0 else {
            return mergeByRow([primary] + imported)
        }

        let primaryWidth = primary.columnCount
        let importedWidths = imported.map(\.columnCount)
        let importedIndexes = imported.map { firstRowsByKey(in: $0, keyColumn: keyColumn) }
        var emittedKeys = Set<String>()

        var rows = primary.rows.map { row in
            let key = keyValue(in: row, keyColumn: keyColumn)
            if let key {
                emittedKeys.insert(key)
            }

            return padded(row, width: primaryWidth)
                + imported.enumerated().flatMap { tableIndex, _ in
                    guard let key,
                          let importedRow = importedIndexes[tableIndex][key] else {
                        return Array(repeating: "", count: importedWidths[tableIndex])
                    }
                    return padded(importedRow, width: importedWidths[tableIndex])
                }
        }

        for table in imported {
            for row in table.rows {
                guard let key = keyValue(in: row, keyColumn: keyColumn),
                      !emittedKeys.contains(key) else {
                    continue
                }
                emittedKeys.insert(key)
                rows.append(
                    Array(repeating: "", count: primaryWidth)
                    + imported.enumerated().flatMap { tableIndex, _ in
                        guard let importedRow = importedIndexes[tableIndex][key] else {
                            return Array(repeating: "", count: importedWidths[tableIndex])
                        }
                        return padded(importedRow, width: importedWidths[tableIndex])
                    }
                )
            }
        }

        return TextTable(rows: rows)
    }

    private static func firstRowsByKey(in table: TextTable,
                                       keyColumn: Int) -> [String: [String]] {
        var rowsByKey: [String: [String]] = [:]
        for row in table.rows {
            guard let key = keyValue(in: row, keyColumn: keyColumn),
                  rowsByKey[key] == nil else {
                continue
            }
            rowsByKey[key] = row
        }
        return rowsByKey
    }

    private static func keyValue(in row: [String], keyColumn: Int) -> String? {
        guard row.indices.contains(keyColumn) else { return nil }
        let key = row[keyColumn]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private static func padded(_ row: [String], width: Int) -> [String] {
        row + Array(repeating: "", count: max(0, width - row.count))
    }
}

enum TextSplitStrategy: Equatable {
    case delimiter(String)
    case quotedDelimiter(Character)
    case whitespace
    case regularExpression(String)
    case fixedWidths([Int])
}

enum TextTableSplitter {
    static func split(_ text: String, strategy: TextSplitStrategy) -> TextTable {
        let lines = logicalLines(in: text)
        let rows = lines.map { line in
            switch strategy {
            case .delimiter(let delimiter):
                guard !delimiter.isEmpty else { return [line] }
                return line.components(separatedBy: delimiter)
            case .quotedDelimiter(let delimiter):
                return splitQuotedDelimiter(line, delimiter: delimiter)
            case .whitespace:
                return line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            case .regularExpression(let pattern):
                return splitRegularExpression(line, pattern: pattern)
            case .fixedWidths(let widths):
                return splitFixedWidth(line, widths: widths)
            }
        }
        return TextTable(rows: rows)
    }

    private static func logicalLines(in text: String) -> [String] {
        let normalized = TextFormatDetector.normalize(text)
        var lines = normalized.components(separatedBy: "\n")
        if normalized.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines
    }

    private static func splitQuotedDelimiter(_ line: String,
                                             delimiter: Character) -> [String] {
        var cells: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex

        while index < line.endIndex {
            let char = line[index]
            let next = line.index(after: index)

            if char == "\"" {
                if inQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = line.index(after: next)
                } else {
                    inQuotes.toggle()
                    index = next
                }
                continue
            }

            if char == delimiter, !inQuotes {
                cells.append(current)
                current = ""
                index = next
                continue
            }

            current.append(char)
            index = next
        }

        cells.append(current)
        return cells
    }

    private static func splitRegularExpression(_ line: String,
                                               pattern: String) -> [String] {
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern) else {
            return [line]
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, range: range)
        guard !matches.isEmpty else { return [line] }

        var cells: [String] = []
        var cursor = line.startIndex
        for match in matches {
            guard match.range.length > 0,
                  let separatorRange = Range(match.range, in: line) else {
                continue
            }
            cells.append(String(line[cursor..<separatorRange.lowerBound]))
            cursor = separatorRange.upperBound
        }
        cells.append(String(line[cursor..<line.endIndex]))
        return cells
    }

    private static func splitFixedWidth(_ line: String, widths: [Int]) -> [String] {
        guard !widths.isEmpty else { return [line] }
        var cells: [String] = []
        var cursor = line.startIndex
        for rawWidth in widths {
            let width = max(0, rawWidth)
            let end = line.index(cursor, offsetBy: width, limitedBy: line.endIndex) ?? line.endIndex
            cells.append(String(line[cursor..<end]))
            cursor = end
        }
        cells.append(String(line[cursor..<line.endIndex]))
        return cells
    }
}

struct ColumnPlan: Equatable {
    var selectedIndexes: [Int]
    var joinDelimiter: String

    func render(table: TextTable) -> String {
        table.rows
            .map { row in
                selectedIndexes
                    .map { index in row.indices.contains(index) ? row[index] : "" }
                    .joined(separator: joinDelimiter)
            }
            .joined(separator: "\n")
    }
}

enum ColumnRecipePart: Equatable {
    case column(Int)
    case literal(String)
}

struct ColumnRecipe: Equatable {
    var parts: [ColumnRecipePart]
    var missingCellPlaceholder: String = ""

    func render(table: TextTable) -> String {
        table.rows
            .map(render(row:))
            .joined(separator: "\n")
    }

    private func render(row: [String]) -> String {
        parts.map { part in
            switch part {
            case .literal(let text):
                return text
            case .column(let index):
                guard row.indices.contains(index) else {
                    return missingCellPlaceholder
                }
                return row[index]
            }
        }
        .joined()
    }
}

enum TextLineShuffler {
    static func shuffle(_ text: String,
                        seed: UInt64,
                        preserveFirstLine: Bool = false,
                        preserveBlankLinePositions: Bool = false) -> String {
        let normalized = TextFormatDetector.normalize(text)
        let hasFinalNewline = normalized.hasSuffix("\n")
        var lines = normalized.components(separatedBy: "\n")
        if hasFinalNewline {
            lines.removeLast()
        }
        guard lines.count > 1 else { return text }

        var locked = Set<Int>()
        if preserveFirstLine {
            locked.insert(0)
        }
        if preserveBlankLinePositions {
            for (idx, line) in lines.enumerated() where line.isEmpty {
                locked.insert(idx)
            }
        }

        var movable = lines.enumerated()
            .filter { !locked.contains($0.offset) }
            .map(\.element)
        seededShuffle(&movable, seed: seed)

        var output = lines
        var next = 0
        for idx in output.indices where !locked.contains(idx) {
            output[idx] = movable[next]
            next += 1
        }
        let shuffled = output.joined(separator: "\n")
        return hasFinalNewline ? shuffled + "\n" : shuffled
    }

    private static func seededShuffle(_ values: inout [String], seed: UInt64) {
        guard values.count > 1 else { return }
        var rng = SplitMix64(seed: seed)
        for i in stride(from: values.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            values.swapAt(i, j)
        }
    }
}

enum TextTransformError: Error, Equatable {
    case invalidBase
    case invalidInteger
    case invalidURLPercentEncoding
    case invalidBase64
    case invalidUTF8
    case invalidJSONString
    case invalidCiphertext

    var messageKey: String {
        switch self {
        case .invalidBase:
            return "transform.error.invalidBase"
        case .invalidInteger:
            return "transform.error.invalidInteger"
        case .invalidURLPercentEncoding:
            return "transform.error.invalidURLPercentEncoding"
        case .invalidBase64:
            return "transform.error.invalidBase64"
        case .invalidUTF8:
            return "transform.error.invalidUTF8"
        case .invalidJSONString:
            return "transform.error.invalidJSONString"
        case .invalidCiphertext:
            return "transform.error.invalidCiphertext"
        }
    }
}

enum TextTransform {
    static func convertInteger(_ text: String,
                               fromBase: Int,
                               toBase: Int) throws -> String {
        guard (2...36).contains(fromBase),
              (2...36).contains(toBase) else {
            throw TextTransformError.invalidBase
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int64(trimmed, radix: fromBase) else {
            throw TextTransformError.invalidInteger
        }
        return String(value, radix: toBase, uppercase: false)
    }

    static func urlEncode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func urlDecode(_ text: String) throws -> String {
        guard let decoded = text.removingPercentEncoding else {
            throw TextTransformError.invalidURLPercentEncoding
        }
        return decoded
    }

    static func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    static func base64Decode(_ text: String) throws -> String {
        guard let data = Data(base64Encoded: text) else {
            throw TextTransformError.invalidBase64
        }
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw TextTransformError.invalidUTF8
        }
        return decoded
    }

    static func htmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func htmlUnescape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func jsonStringEscape(_ text: String) throws -> String {
        let data = try JSONEncoder().encode(text)
        guard let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else {
            throw TextTransformError.invalidJSONString
        }
        return String(encoded.dropFirst().dropLast())
    }

    static func jsonStringUnescape(_ text: String) throws -> String {
        let wrapped = "\"\(text)\""
        guard let data = wrapped.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            throw TextTransformError.invalidJSONString
        }
        return decoded
    }

    static func aesGCMEncrypt(_ text: String, password: String) throws -> String {
        let salt = randomSalt()
        let sealed = try AES.GCM.seal(
            Data(text.utf8),
            using: try symmetricKey(for: password,
                                    salt: salt,
                                    iterations: aesGCMPBKDF2Iterations)
        )
        guard let combined = sealed.combined else {
            throw TextTransformError.invalidCiphertext
        }
        return [
            aesGCMEnvelopeVersion,
            aesGCMKDFName,
            String(aesGCMPBKDF2Iterations),
            salt.base64EncodedString(),
            combined.base64EncodedString()
        ].joined(separator: aesGCMEnvelopeSeparator)
    }

    static func aesGCMDecrypt(_ text: String, password: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(aesGCMEnvelopeVersion + aesGCMEnvelopeSeparator) {
            return try decryptVersionedAESGCMEnvelope(trimmed, password: password)
        }
        return try decryptLegacyAESGCMBase64(trimmed, password: password)
    }

    private static let aesGCMEnvelopeVersion = "scribe-aesgcm-v2"
    private static let aesGCMKDFName = "pbkdf2-sha256"
    private static let aesGCMEnvelopeSeparator = "$"
    private static let aesGCMPBKDF2Iterations = 100_000
    private static let aesGCMPBKDF2MaxIterations = 1_000_000
    private static let aesGCMSaltByteCount = 16
    private static let aesGCMKeyByteCount = 32

    private static func decryptVersionedAESGCMEnvelope(_ text: String,
                                                       password: String) throws -> String {
        let parts = text.components(separatedBy: aesGCMEnvelopeSeparator)
        guard parts.count == 5,
              parts[0] == aesGCMEnvelopeVersion,
              parts[1] == aesGCMKDFName,
              let iterations = Int(parts[2]),
              (1...aesGCMPBKDF2MaxIterations).contains(iterations),
              let salt = Data(base64Encoded: parts[3]),
              let data = Data(base64Encoded: parts[4]) else {
            throw TextTransformError.invalidCiphertext
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: data)
            let opened = try AES.GCM.open(
                sealed,
                using: try symmetricKey(for: password,
                                        salt: salt,
                                        iterations: iterations)
            )
            guard let decoded = String(data: opened, encoding: .utf8) else {
                throw TextTransformError.invalidUTF8
            }
            return decoded
        } catch TextTransformError.invalidUTF8 {
            throw TextTransformError.invalidUTF8
        } catch {
            throw TextTransformError.invalidCiphertext
        }
    }

    private static func decryptLegacyAESGCMBase64(_ text: String,
                                                  password: String) throws -> String {
        guard let data = Data(base64Encoded: text) else {
            throw TextTransformError.invalidCiphertext
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: data)
            let opened = try AES.GCM.open(sealed, using: legacySymmetricKey(for: password))
            guard let decoded = String(data: opened, encoding: .utf8) else {
                throw TextTransformError.invalidUTF8
            }
            return decoded
        } catch TextTransformError.invalidUTF8 {
            throw TextTransformError.invalidUTF8
        } catch {
            throw TextTransformError.invalidCiphertext
        }
    }

    private static func randomSalt() -> Data {
        Data((0..<aesGCMSaltByteCount).map { _ in UInt8.random(in: 0...255) })
    }

    private static func symmetricKey(for password: String,
                                     salt: Data,
                                     iterations: Int) throws -> SymmetricKey {
        guard iterations > 0 else { throw TextTransformError.invalidCiphertext }
        let bytes = try pbkdf2SHA256(password: Data(password.utf8),
                                     salt: salt,
                                     iterations: iterations,
                                     keyByteCount: aesGCMKeyByteCount)
        return SymmetricKey(data: bytes)
    }

    private static func legacySymmetricKey(for password: String) -> SymmetricKey {
        let digest = SHA256.hash(data: Data(password.utf8))
        return SymmetricKey(data: digest)
    }

    private static func pbkdf2SHA256(password: Data,
                                     salt: Data,
                                     iterations: Int,
                                     keyByteCount: Int) throws -> Data {
        guard iterations > 0, keyByteCount > 0 else {
            throw TextTransformError.invalidCiphertext
        }
        let key = SymmetricKey(data: password)
        var derived = Data()
        var blockIndex: UInt32 = 1

        while derived.count < keyByteCount {
            var blockInput = salt
            blockInput.append(UInt8((blockIndex >> 24) & 0xff))
            blockInput.append(UInt8((blockIndex >> 16) & 0xff))
            blockInput.append(UInt8((blockIndex >> 8) & 0xff))
            blockInput.append(UInt8(blockIndex & 0xff))

            var u = Array(HMAC<SHA256>.authenticationCode(for: blockInput, using: key))
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Array(HMAC<SHA256>.authenticationCode(for: Data(u), using: key))
                    for index in t.indices {
                        t[index] ^= u[index]
                    }
                }
            }
            derived.append(contentsOf: t)
            blockIndex &+= 1
        }

        return Data(derived.prefix(keyByteCount))
    }
}

enum TextTransformAction: Equatable {
    case urlEncode
    case urlDecode
    case base64Encode
    case base64Decode
    case htmlEscape
    case htmlUnescape
    case jsonStringEscape
    case jsonStringUnescape
    case aesGCMEncrypt(password: String)
    case aesGCMDecrypt(password: String)
    case convertBase(fromBase: Int, toBase: Int)
    case shuffleLines(seed: UInt64,
                      preserveFirstLine: Bool = false,
                      preserveBlankLinePositions: Bool = false)
    /// Phase 41a — hash digests. Output replaces the selection
    /// with the lowercase hex digest of the UTF-8 bytes. MD5 /
    /// SHA-1 are still useful as ETag-style checksums even though
    /// they're cryptographically broken; SHA-256 / SHA-512 are
    /// the safe defaults; CRC32 matches zlib so users can cross-
    /// check against `python -c "zlib.crc32(...)"` etc.
    case md5
    case sha1
    case sha256
    case sha512
    case crc32

    // Phase 41d — line operations. All read the input as a series
    // of newline-separated rows (LF / CRLF / CR auto-detected) and
    // re-emit the same line ending so a Windows file stays Windows.
    case dedupeLines
    case dropBlankLines
    case reverseLines
    case trimTrailing
    case tabsToSpaces(width: Int)
    case spacesToTabs(width: Int)
    case sortLines(mode: LineOps.SortMode, descending: Bool)
    case caseTransform(mode: LineOps.CaseMode)

    // Phase 41c — language-aware Pretty / Minify. Each pair routes
    // to `CodeFormatter.<Lang>.{pretty,minify}`. Errors propagate up
    // and land in the toast surface (Phase 43-T).
    case formatJSON
    case minifyJSON
    case formatXML
    case minifyXML
    case formatCSS
    case minifyCSS
    case formatSQL
    case minifySQL

    func apply(to text: String) throws -> String {
        switch self {
        case .urlEncode:
            return TextTransform.urlEncode(text)
        case .urlDecode:
            return try TextTransform.urlDecode(text)
        case .base64Encode:
            return TextTransform.base64Encode(text)
        case .base64Decode:
            return try TextTransform.base64Decode(text)
        case .htmlEscape:
            return TextTransform.htmlEscape(text)
        case .htmlUnescape:
            return TextTransform.htmlUnescape(text)
        case .jsonStringEscape:
            return try TextTransform.jsonStringEscape(text)
        case .jsonStringUnescape:
            return try TextTransform.jsonStringUnescape(text)
        case .aesGCMEncrypt(let password):
            return try TextTransform.aesGCMEncrypt(text, password: password)
        case .aesGCMDecrypt(let password):
            return try TextTransform.aesGCMDecrypt(text, password: password)
        case let .convertBase(fromBase, toBase):
            return try TextTransform.convertInteger(text,
                                                    fromBase: fromBase,
                                                    toBase: toBase)
        case let .shuffleLines(seed, preserveFirstLine, preserveBlankLinePositions):
            return TextLineShuffler.shuffle(text,
                                            seed: seed,
                                            preserveFirstLine: preserveFirstLine,
                                            preserveBlankLinePositions: preserveBlankLinePositions)
        case .md5:    return HashSuite.md5(text)
        case .sha1:   return HashSuite.sha1(text)
        case .sha256: return HashSuite.sha256(text)
        case .sha512: return HashSuite.sha512(text)
        case .crc32:  return HashSuite.crc32(text)
        case .dedupeLines:      return LineOps.deduplicate(text)
        case .dropBlankLines:   return LineOps.dropBlankLines(text)
        case .reverseLines:     return LineOps.reverse(text)
        case .trimTrailing:     return LineOps.trimTrailingWhitespace(text)
        case .tabsToSpaces(let w): return LineOps.tabsToSpaces(text, tabWidth: w)
        case .spacesToTabs(let w): return LineOps.spacesToTabs(text, tabWidth: w)
        case let .sortLines(mode, descending):
            return LineOps.sort(text, mode: mode, descending: descending)
        case .caseTransform(let mode):
            return LineOps.transformCase(text, mode: mode)
        case .formatJSON:  return try CodeFormatter.JSON.pretty(text)
        case .minifyJSON:  return try CodeFormatter.JSON.minify(text)
        case .formatXML:   return try CodeFormatter.XML.pretty(text)
        case .minifyXML:   return try CodeFormatter.XML.minify(text)
        case .formatCSS:   return try CodeFormatter.CSS.pretty(text)
        case .minifyCSS:   return try CodeFormatter.CSS.minify(text)
        case .formatSQL:   return try CodeFormatter.SQL.pretty(text)
        case .minifySQL:   return try CodeFormatter.SQL.minify(text)
        }
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
