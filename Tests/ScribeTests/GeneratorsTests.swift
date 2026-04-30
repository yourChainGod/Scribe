//
//  GeneratorsTests.swift
//  Phase 41b — UUID / Lorem / Password / Timestamp / QR generator
//  coverage. Each generator gets at least:
//    • a happy-path shape assertion
//    • boundary input (zero-length, empty payload)
//    • a property the output must always satisfy (length, charset,
//      determinism for Lorem, parsability for Timestamp)
//

import XCTest
@testable import Scribe

final class GeneratorsTests: XCTestCase {

    // MARK: - UUID

    func test_uuid_shape() {
        let s = Generators.uuidV4()
        // 8-4-4-4-12 hex
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        XCTAssertNotNil(s.range(of: pattern, options: .regularExpression))
    }

    func test_uuid_uppercaseFlag() {
        let upper = Generators.uuidV4(uppercase: true)
        XCTAssertEqual(upper, upper.uppercased())
    }

    func test_uuid_distinctRunsDiffer() {
        // Vanishingly small chance of false negative — UUID v4 has
        // 122 random bits.
        let a = Generators.uuidV4()
        let b = Generators.uuidV4()
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Lorem

    func test_lorem_zeroIsEmpty() {
        XCTAssertEqual(Generators.lorem(wordCount: 0), "")
    }

    func test_lorem_threeWords_startsWithIncipit() {
        let s = Generators.lorem(wordCount: 3)
        XCTAssertEqual(s, "Lorem ipsum dolor.")
    }

    func test_lorem_endsWithPeriod() {
        XCTAssertTrue(Generators.lorem(wordCount: 10).hasSuffix("."))
        XCTAssertTrue(Generators.lorem(wordCount: 50).hasSuffix("."))
    }

    func test_lorem_fiftyWords_count() {
        let s = Generators.lorem(wordCount: 50)
        // Strip the trailing period before splitting.
        let body = s.hasSuffix(".") ? String(s.dropLast()) : s
        let words = body.split(separator: " ")
        XCTAssertEqual(words.count, 50)
    }

    func test_lorem_isDeterministic() {
        // Same input → same output. Important for screenshot-driven
        // verification and avoids "Lorem block churns the diff".
        XCTAssertEqual(Generators.lorem(wordCount: 25),
                       Generators.lorem(wordCount: 25))
    }

    // MARK: - Password

    func test_password_lengthHonoured() throws {
        var opts = Generators.PasswordOptions()
        opts.length = 24
        XCTAssertEqual(try Generators.password(options: opts).count, 24)
    }

    func test_password_alphabetRespectsFlags_digitsOnly() throws {
        var opts = Generators.PasswordOptions()
        opts.length = 32
        opts.includeLowercase = false
        opts.includeUppercase = false
        opts.includeDigits = true
        opts.includeSymbols = false
        let s = try Generators.password(options: opts)
        XCTAssertTrue(s.allSatisfy { "0123456789".contains($0) })
    }

    func test_password_throwsOnEmptyAlphabet() {
        var opts = Generators.PasswordOptions()
        opts.includeLowercase = false
        opts.includeUppercase = false
        opts.includeDigits = false
        opts.includeSymbols = false
        XCTAssertThrowsError(try Generators.password(options: opts))
    }

    func test_password_runsDiffer() throws {
        var opts = Generators.PasswordOptions()
        opts.length = 32
        let a = try Generators.password(options: opts)
        let b = try Generators.password(options: opts)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Timestamp

    /// A fixed reference instant: 2026-04-30T12:34:56Z.
    /// Defining inline so test failures don't cascade if the test
    /// helper itself drifts.
    private func referenceDate() -> Date {
        let comps = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "UTC"),
            year: 2026, month: 4, day: 30,
            hour: 12, minute: 34, second: 56)
        return comps.date!
    }

    func test_timestamp_unixSeconds() {
        // Reference instant: 2026-04-30T12:34:56Z. Match against the
        // round-trip via the same Date so the test stays trustworthy
        // even if a future swap to a different formatter shifts
        // hardcoded epoch values.
        let expected = Int64(referenceDate().timeIntervalSince1970)
        let s = Generators.timestamp(format: .unixSeconds,
                                     now: referenceDate(),
                                     timezone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(Int64(s), expected)
    }

    func test_timestamp_unixMillis() {
        let expected = Int64(referenceDate().timeIntervalSince1970 * 1000)
        let s = Generators.timestamp(format: .unixMillis,
                                     now: referenceDate(),
                                     timezone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(Int64(s), expected)
    }

    func test_timestamp_iso8601Compact() {
        let s = Generators.timestamp(format: .iso8601Compact,
                                     now: referenceDate(),
                                     timezone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(s, "2026-04-30T12:34:56Z")
    }

    func test_timestamp_yyyymmdd() {
        let s = Generators.timestamp(format: .yyyymmdd,
                                     now: referenceDate(),
                                     timezone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(s, "2026-04-30")
    }

    func test_timestamp_yyyymmddHHMMSS() {
        let s = Generators.timestamp(format: .yyyymmddHHMMSS,
                                     now: referenceDate(),
                                     timezone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(s, "2026-04-30 12:34:56")
    }

    func test_timestamp_rfc2822() {
        let s = Generators.timestamp(format: .rfc2822,
                                     now: referenceDate(),
                                     timezone: TimeZone(identifier: "UTC")!)
        // "Thu, 30 Apr 2026 12:34:56 +0000"
        XCTAssertTrue(s.hasPrefix("Thu, 30 Apr 2026"))
        XCTAssertTrue(s.hasSuffix("+0000"))
    }

    // MARK: - QR

    func test_qr_basicRendering() throws {
        let ascii = try Generators.qrASCII(payload: "https://scribe.example/")
        // Result is a multi-line block built from the half-block
        // glyphs (▀ / ▄ / █) plus spaces. Smallest QR is 21×21
        // modules + 2-module quiet zone = 23 characters wide,
        // 12 character rows tall (23 / 2 rounded up).
        XCTAssertGreaterThan(ascii.split(separator: "\n").count, 5)
        XCTAssertTrue(ascii.contains("█") || ascii.contains("▀") || ascii.contains("▄"))
    }

    func test_qr_throwsOnEmptyPayload() {
        XCTAssertThrowsError(try Generators.qrASCII(payload: ""))
    }

    func test_qr_widthIsRectangular() throws {
        let ascii = try Generators.qrASCII(payload: "test")
        let lines = ascii.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else {
            XCTFail("empty output"); return
        }
        // Every line should have the same character count (the
        // rectangle invariant). Use Character count, not utf8, so
        // we count user-perceived columns.
        let width = first.count
        for line in lines {
            XCTAssertEqual(line.count, width, "ragged QR output")
        }
    }
}
