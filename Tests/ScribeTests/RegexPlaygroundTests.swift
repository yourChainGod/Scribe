//
//  RegexPlaygroundTests.swift
//  Phase 41e — coverage for the regex playground model. Asserts:
//    • simple match cases
//    • capture-group structure
//    • each option flag changes behaviour
//    • invalid pattern surfaces as `.invalidPattern`
//    • replace honours $1 / $& backreferences
//

import XCTest
@testable import Scribe

final class RegexPlaygroundTests: XCTestCase {

    // MARK: - matches

    func test_matches_simple() throws {
        let hits = try RegexPlayground.matches(
            in: "abc abc abc",
            pattern: "abc")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.map { $0.value }, ["abc", "abc", "abc"])
    }

    func test_matches_caseInsensitive() throws {
        var opts = RegexPlayground.Options()
        opts.caseInsensitive = true
        let hits = try RegexPlayground.matches(
            in: "Hello HELLO hello",
            pattern: "hello",
            options: opts)
        XCTAssertEqual(hits.count, 3)
    }

    func test_matches_caseSensitiveByDefault() throws {
        let hits = try RegexPlayground.matches(
            in: "Hello HELLO hello",
            pattern: "hello")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.value, "hello")
    }

    func test_matches_captureGroups() throws {
        let hits = try RegexPlayground.matches(
            in: "id=42, id=7",
            pattern: #"id=(\d+)"#)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].groups[0], "id=42")
        XCTAssertEqual(hits[0].groups[1], "42")
        XCTAssertEqual(hits[1].groups[1], "7")
    }

    func test_matches_optionalGroup_isNilWhenMissing() throws {
        // The first alternation branch (digit) doesn't capture group 2;
        // the second branch (letter) doesn't capture group 1. Each
        // match must report the missing group as nil.
        let hits = try RegexPlayground.matches(
            in: "a 1 b 2",
            pattern: #"(\d)|([a-z])"#)
        XCTAssertEqual(hits.count, 4)
        // First hit ("a") — letter branch, group 1 should be nil.
        XCTAssertNil(hits[0].groups[1])
        XCTAssertEqual(hits[0].groups[2], "a")
        // Second hit ("1") — digit branch, group 2 should be nil.
        XCTAssertEqual(hits[1].groups[1], "1")
        XCTAssertNil(hits[1].groups[2])
    }

    func test_matches_multiline_flag() throws {
        var opts = RegexPlayground.Options()
        opts.multiline = true
        // `^` should match every line start when multiline is on.
        let hits = try RegexPlayground.matches(
            in: "a\nb\nc",
            pattern: "^.",
            options: opts)
        XCTAssertEqual(hits.count, 3)
    }

    func test_matches_dotAll_flag() throws {
        var opts = RegexPlayground.Options()
        opts.dotAll = true
        // `.` should swallow `\n` when dotAll is on.
        let hits = try RegexPlayground.matches(
            in: "a\nb",
            pattern: ".+",
            options: opts)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.value, "a\nb")
    }

    func test_matches_dotAll_offByDefault() throws {
        let hits = try RegexPlayground.matches(
            in: "a\nb",
            pattern: ".+")
        XCTAssertEqual(hits.count, 2)
    }

    func test_matches_emptyPatternReturnsEmpty() throws {
        XCTAssertEqual(try RegexPlayground.matches(in: "abc", pattern: "").count, 0)
    }

    func test_matches_nothingMatched() throws {
        XCTAssertEqual(try RegexPlayground.matches(in: "abc",
                                                   pattern: "xyz").count, 0)
    }

    // MARK: - errors

    func test_invalidPattern_throws() {
        XCTAssertThrowsError(try RegexPlayground.matches(in: "abc",
                                                         pattern: "[")) { error in
            switch error {
            case RegexPlayground.RegexError.invalidPattern(let reason):
                XCTAssertFalse(reason.isEmpty)
            default:
                XCTFail("expected invalidPattern, got \(error)")
            }
        }
    }

    // MARK: - replace

    func test_replace_simple() throws {
        let result = try RegexPlayground.replace(
            in: "abc abc",
            pattern: "abc",
            template: "X")
        XCTAssertEqual(result, "X X")
    }

    func test_replace_withGroupBackref() throws {
        let result = try RegexPlayground.replace(
            in: "id=42, id=7",
            pattern: #"id=(\d+)"#,
            template: "[$1]")
        XCTAssertEqual(result, "[42], [7]")
    }

    func test_replace_withFullMatchRef() throws {
        let result = try RegexPlayground.replace(
            in: "abc",
            pattern: "[a-z]",
            template: "<$0>")
        XCTAssertEqual(result, "<a><b><c>")
    }

    func test_replace_emptyPattern_returnsSubject() throws {
        let result = try RegexPlayground.replace(
            in: "abc",
            pattern: "",
            template: "X")
        XCTAssertEqual(result, "abc")
    }

    func test_replace_invalidPattern_throws() {
        XCTAssertThrowsError(try RegexPlayground.replace(
            in: "abc",
            pattern: "[",
            template: "X"))
    }
}
