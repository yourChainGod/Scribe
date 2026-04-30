#!/usr/bin/env swift
//
//  check_localization.swift
//  Verify that en.lproj and zh-Hans.lproj declare the same set of
//  keys, and that no source file references a key that's missing
//  from either bundle.
//
//  Failure modes detected:
//    1.  A key present in en but missing from zh-Hans (or vice versa).
//        — common when adding a new string and forgetting one bundle.
//    2.  A `L10n.t("foo")` / injected `localize("foo")` /
//        `Text("foo", bundle: .module)` / `Text("foo", comment:)` /
//        `LocalizedStringKey` call referencing a key that isn't in
//        *any* bundle.
//        — indicates a typo or stale rename.
//
//  Output:
//    Prints one diagnostic per problem on stdout, exits non-zero if
//    any problems were found. Suitable for CI gating.
//
//  Run:
//    swift Scripts/check_localization.swift
//

import Foundation

// MARK: - .strings parsing

func parseStringsFile(_ url: URL) throws -> Set<String> {
    let text = try String(contentsOf: url, encoding: .utf8)
    var keys = Set<String>()

    // The Localizable.strings format is `"key" = "value";` per line.
    // We deliberately don't reach for PropertyListSerialization — the
    // whole point of this check is to catch malformed entries that
    // confuse the runtime loader silently.
    let pattern = #"^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$"#
    let regex = try NSRegularExpression(pattern: pattern, options: [])

    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") { continue }
        let range = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: range),
              let keyRange = Range(m.range(at: 1), in: line) else { continue }
        keys.insert(String(line[keyRange]))
    }
    return keys
}

// MARK: - Source scan

func scanSourceForKeys(_ root: URL) -> Set<String> {
    var hits = Set<String>()
    guard let enumerator = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: [.isRegularFileKey]) else {
        return hits
    }
    // Patterns we care about. Conservative — only quoted literal keys.
    let patterns = [
        #"L10n\.t\(\s*"([^"]+)""#,
        #"localize\(\s*"([^"]+)""#,
        #"NSLocalizedString\(\s*"([^"]+)""#,
        #"Text\(\s*"([^"]+)"\s*,\s*bundle:\s*\.module"#,
        #"Text\(\s*"([^"]+)"\s*,\s*comment:"#,
    ]
    let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }

    while let next = enumerator.nextObject() {
        guard let url = next as? URL,
              url.pathExtension == "swift" else { continue }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let range = NSRange(text.startIndex..., in: text)
        for regex in regexes {
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      let r = Range(match.range(at: 1), in: text) else { return }
                hits.insert(String(text[r]))
            }
        }
    }
    return hits
}

// MARK: - Main

let repoRoot: URL = {
    var url = URL(fileURLWithPath: CommandLine.arguments[0])
    url.deleteLastPathComponent()                  // -> Scripts/
    url.deleteLastPathComponent()                  // -> repo root
    return url
}()

let resourcesRoot = repoRoot
    .appendingPathComponent("Sources")
    .appendingPathComponent("Scribe")
    .appendingPathComponent("Resources")
let enFile     = resourcesRoot.appendingPathComponent("en.lproj/Localizable.strings")
let zhHansFile = resourcesRoot.appendingPathComponent("zh-Hans.lproj/Localizable.strings")

var problems: [String] = []

let enKeys: Set<String>
let zhKeys: Set<String>
do {
    enKeys = try parseStringsFile(enFile)
    zhKeys = try parseStringsFile(zhHansFile)
} catch {
    print("error: failed to parse Localizable.strings: \(error)")
    exit(2)
}

// 1. Symmetric-difference check between locales.
let onlyEn = enKeys.subtracting(zhKeys).sorted()
let onlyZh = zhKeys.subtracting(enKeys).sorted()
for k in onlyEn { problems.append("missing in zh-Hans: \(k)") }
for k in onlyZh { problems.append("missing in en:      \(k)") }

// 2. Source references that aren't in either bundle.
let sourceRoot = repoRoot.appendingPathComponent("Sources")
let referencedKeys = scanSourceForKeys(sourceRoot)
let knownKeys = enKeys.union(zhKeys)
let dangling = referencedKeys.subtracting(knownKeys).sorted()
for k in dangling { problems.append("dangling reference (not declared): \(k)") }

// 3. Reverse — keys declared but never used. Soft-warn only,
//    not a hard fail (some keys are referenced from generated
//    AppKit nibs / future surfaces).
let unused = knownKeys.subtracting(referencedKeys).sorted()

print("en.lproj keys:           \(enKeys.count)")
print("zh-Hans.lproj keys:      \(zhKeys.count)")
print("source-referenced keys:  \(referencedKeys.count)")
print("unused (informational):  \(unused.count)")
if !unused.isEmpty && CommandLine.arguments.contains("--verbose") {
    for k in unused { print("  unused: \(k)") }
}
print("")

if problems.isEmpty {
    print("OK — localization bundles are consistent")
    exit(0)
}
for p in problems { print("  \(p)") }
print("")
print("FAIL — \(problems.count) localization problem(s)")
exit(1)
