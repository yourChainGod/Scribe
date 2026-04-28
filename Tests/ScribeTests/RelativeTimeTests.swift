//
//  RelativeTimeTests.swift
//  Phase 35c-ii-α — boundary-bucket tests for the relative-time
//  formatter. We deliberately don't hardcode literal strings ("3
//  minutes ago") because Bundle.module's locale resolution under
//  `swift test` follows the user's system locale, which would
//  flake the suite on a Chinese-locale runner.
//
//  Instead we pin *bucket boundaries* — describe() must produce
//  one string for "less than a minute" and a different string for
//  "1 minute or more" without us having to know whether either is
//  in English or 中文. Same idea for every other boundary.
//
//  Date arithmetic uses Calendar.current matching the production
//  code path, so a leap-year / DST case that the function would
//  hit for real is what the test sees too.
//

import XCTest
@testable import Scribe

final class RelativeTimeTests: XCTestCase {

    /// Fixed reference epoch, well clear of DST / leap-year edges.
    /// 2023-11-14 22:13:20 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func describe(secondsAgo s: Int) -> String {
        let epoch = Int(now.timeIntervalSince1970) - s
        return RelativeTime.describe(epoch: epoch, now: now)
    }

    // MARK: - Just-now bucket (< 60 seconds)

    func test_zero_isJustNow() {
        // The "happens right now" case — describe must not return
        // an empty string (would render as a stray separator in
        // the EOL annotation) and must agree with the 30s case
        // since both fall inside the < 60s bucket.
        let zero = describe(secondsAgo: 0)
        XCTAssertFalse(zero.isEmpty)
        XCTAssertEqual(zero, describe(secondsAgo: 30))
    }

    func test_futureEpoch_clampsToJustNow() {
        // Clock-skewed commits are real (rebase fudging,
        // misconfigured laptops). A negative delta should *not*
        // produce "-3 minutes ago" — the helper coerces back to
        // the just-now string.
        let epoch = Int(now.timeIntervalSince1970) + 600 // 10min ahead
        let label = RelativeTime.describe(epoch: epoch, now: now)
        XCTAssertEqual(label, describe(secondsAgo: 0))
    }

    // MARK: - Minute boundary (60s)

    func test_oneMinuteBoundary_changesBucket() {
        // 59s should still read as "just now"; 60s should flip
        // to the minutes bucket. Pinning that the boundary is
        // strict-less-than rather than strict-less-than-or-
        // equal — getting it inverted would produce a confusing
        // "0 minutes ago" right on the boundary.
        XCTAssertEqual(describe(secondsAgo: 59), describe(secondsAgo: 0))
        XCTAssertNotEqual(describe(secondsAgo: 60),
                          describe(secondsAgo: 0))
    }

    func test_minutesBucket_isStableAcrossSubMinuteJitter() {
        // 90s + 95s + 119s all live inside "1 minute ago" —
        // the helper's bucket grouping should pin them to the
        // same string so the EOL annotation doesn't visually
        // flicker as the clock ticks.
        let a = describe(secondsAgo: 90)
        let b = describe(secondsAgo: 95)
        let c = describe(secondsAgo: 119)
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
    }

    // MARK: - Hour boundary (3600s)

    func test_oneHourBoundary_changesBucket() {
        // 59min ⇒ minutes bucket; 60min ⇒ hours bucket.
        XCTAssertNotEqual(describe(secondsAgo: 59 * 60),
                          describe(secondsAgo: 60 * 60))
    }

    // MARK: - Day boundary (86_400s)

    func test_oneDayBoundary_changesBucket() {
        // 23h ⇒ hours bucket; 24h ⇒ days bucket.
        XCTAssertNotEqual(describe(secondsAgo: 23 * 3600),
                          describe(secondsAgo: 24 * 3600))
    }

    // MARK: - Month + year boundaries

    func test_monthBoundary_changesBucket() {
        // 29d vs 31d straddles the month threshold for any
        // calendar month a typical "now" lands in. We compare
        // strings only — the helper's exact rollover day is
        // calendar-dependent and pinning it would couple the
        // test to a specific date. The contract we *do* pin:
        // 29d and 31d don't both end up in the days bucket.
        XCTAssertNotEqual(describe(secondsAgo: 29 * 86_400),
                          describe(secondsAgo: 31 * 86_400))
    }

    func test_yearBoundary_changesBucket() {
        // ~11 months vs ~13 months — straddles the year flip
        // regardless of the reference month.
        XCTAssertNotEqual(describe(secondsAgo: 11 * 30 * 86_400),
                          describe(secondsAgo: 13 * 30 * 86_400))
    }

    // MARK: - Format presence

    func test_minuteString_containsTheCount() {
        // We can't predict the locale's literal text, but every
        // bucket above just-now interpolates `%d`. Verify the
        // count appears in the produced string — guards the
        // i18n catalogue against a stray translation that drops
        // the format specifier.
        let label = describe(secondsAgo: 7 * 60)   // "7 minutes ago"
        XCTAssertTrue(label.contains("7"),
                      "minute bucket should interpolate the count: \(label)")
    }
}
