//
//  RelativeTime.swift
//  Phase 35c-ii-α — short, locale-aware "N units ago" formatter.
//  Scoped narrowly to the inline-blame caret label and any other
//  spot we eventually want a human-friendly age (commit log,
//  status bar's "modified at"). Format buckets:
//
//    < 60 seconds   → "just now"
//    < 60 minutes   → "5 minutes ago"
//    <  24 hours    → "3 hours ago"
//    <  30 days     → "2 days ago"
//    <  12 months   → "3 months ago"
//    else           → "2 years ago"
//
//  The boundary math goes through Foundation's Calendar /
//  DateComponents instead of bare arithmetic so leap years and
//  month-length variability ("how many days is `1 month ago`?")
//  resolve via the user's locale. Strings are funnelled through
//  L10n.t so the en / zh-Hans bundles can each pick its own
//  pluralisation rules — we don't ship .stringsdict yet, so the
//  English form deliberately uses the plural-friendly "%d minutes
//  ago" wording even at N=1; spelled "1 minute ago" would mean
//  parallel singular/plural keys per bucket.
//
//  Tested in pure isolation against an injectable `now` so we
//  don't have to wait real time pass to assert each bucket. All
//  callers in production pass `Date()` (default).
//

import Foundation

enum RelativeTime {

    /// Produce a localised "N units ago" string for a Unix-epoch
    /// timestamp.
    ///
    /// - Parameters:
    ///   - epoch: seconds since 1970-01-01 UTC. Past epochs only —
    ///     a future epoch would yield negative components and is
    ///     coerced to "just now".
    ///   - now:   reference point. Defaults to `Date()`; tests
    ///     inject a fixed instant to pin each bucket without
    ///     wall-clock waits.
    ///
    /// - Returns: a short, single-line string ready to drop into
    ///   the EOL annotation. Locale-driven via `L10n.t(_, _)`.
    static func describe(epoch: Int, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        // Negative or zero delta → "just now". Future-dated
        // commits exist (clock skew, rebase fudging) and a "-3
        // minutes ago" string would just be confusing.
        guard date <= now else {
            return L10n.t("relativeTime.justNow")
        }
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date, to: now)
        // Walk biggest → smallest. First non-zero component wins;
        // we intentionally don't compose ("1 hour 5 minutes ago")
        // to keep the inline-blame label one chip-sized token.
        if let y = comps.year, y >= 1 {
            return L10n.t("relativeTime.years", y)
        }
        if let mo = comps.month, mo >= 1 {
            return L10n.t("relativeTime.months", mo)
        }
        if let d = comps.day, d >= 1 {
            return L10n.t("relativeTime.days", d)
        }
        if let h = comps.hour, h >= 1 {
            return L10n.t("relativeTime.hours", h)
        }
        if let m = comps.minute, m >= 1 {
            return L10n.t("relativeTime.minutes", m)
        }
        return L10n.t("relativeTime.justNow")
    }
}
