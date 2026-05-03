//
//  ClipboardHistoryRetentionTests.swift
//  Phase 67 — covers the persistence + retention surface added on
//  top of the Phase 57 in-memory store. Uses an injected clock and
//  a tmp-dir storage URL so:
//    * TTL assertions don't depend on real wall time.
//    * On-disk JSON never lands in the developer's actual
//      Application Support during a test run.
//

import XCTest
import AppKit
@testable import Scribe

@MainActor
final class ClipboardHistoryRetentionTests: XCTestCase {

    // Shared fake pasteboard from the Phase 57 suite. Inlined to
    // keep the test file independent of file-load order.
    final class FakePasteboard: ClipboardSource {
        var changeCount: Int = 0
        var value: String?
        func string(forType type: NSPasteboard.PasteboardType) -> String? {
            value
        }
        func write(_ s: String) {
            changeCount += 1
            value = s
        }
    }

    /// Mutable clock used in TTL tests. Tests advance `now` between
    /// `record()` calls, then push a new policy or invoke the
    /// retention sweep.
    final class ClockBox: @unchecked Sendable {
        // FakePasteboard / ClockBox are referenced from `@Sendable`
        // closures we hand to ClipboardHistoryStore. The store
        // itself is @MainActor, so the closure only ever runs on
        // the main actor; the @unchecked annotation captures that
        // contract without forcing an Actor wrapper.
        var now: Date

        init(_ d: Date) { self.now = d }
    }

    /// Per-test scratch directory the store writes its JSON into.
    /// Created in `setUp`, cleared in `tearDown` to keep CI hosts
    /// from accumulating leftover files across runs.
    private var tmpDir: URL!
    private var storageURL: URL { tmpDir.appendingPathComponent("clipboard.json") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-clipboard-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tmpDir.path) {
            try FileManager.default.removeItem(at: tmpDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Policy clamping

    func test_policy_clampsMaxItemsBelowFloor() {
        let p = ClipboardHistoryPolicy(persistEnabled: true,
                                       maxItems: 1,
                                       retentionDays: 5)
        XCTAssertEqual(p.maxItems, ClipboardHistoryPolicy.maxItemsMin,
                       "maxItems below floor must clamp up")
    }

    func test_policy_clampsMaxItemsAboveCeiling() {
        let p = ClipboardHistoryPolicy(persistEnabled: true,
                                       maxItems: 10_000,
                                       retentionDays: 5)
        XCTAssertEqual(p.maxItems, ClipboardHistoryPolicy.maxItemsMax,
                       "maxItems above ceiling must clamp down")
    }

    func test_policy_clampsRetentionToNonNegative() {
        let p = ClipboardHistoryPolicy(persistEnabled: false,
                                       maxItems: 50,
                                       retentionDays: -3)
        XCTAssertEqual(p.retentionDays, ClipboardHistoryPolicy.retentionDaysMin)
    }

    func test_policy_clampsRetentionAboveCeiling() {
        let p = ClipboardHistoryPolicy(persistEnabled: false,
                                       maxItems: 50,
                                       retentionDays: 9_999)
        XCTAssertEqual(p.retentionDays, ClipboardHistoryPolicy.retentionDaysMax)
    }

    // MARK: - record() honours policy.maxItems

    func test_record_capsAtPolicyMaxItems() {
        let policy = ClipboardHistoryPolicy(persistEnabled: false,
                                            maxItems: 12,
                                            retentionDays: 0)
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: policy,
                                          storageURL: nil)
        for i in 0..<25 {
            store.record(text: "item-\(i)")
        }
        XCTAssertEqual(store.entries.count, 12,
                       "FIFO must obey policy.maxItems, not Self.capacity")
        XCTAssertEqual(store.entries.first?.text, "item-24",
                       "newest entry stays at the head after the trim")
    }

    // MARK: - record() applies TTL

    func test_record_dropsExpiredEntriesViaTTL() {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let policy = ClipboardHistoryPolicy(persistEnabled: false,
                                            maxItems: 50,
                                            retentionDays: 1)
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: policy,
                                          storageURL: nil,
                                          now: { clock.now })
        store.record(text: "old")
        // Advance 2 days past the cutoff.
        clock.now = clock.now.addingTimeInterval(2 * 86_400)
        store.record(text: "fresh")

        XCTAssertEqual(store.entries.map(\.text), ["fresh"],
                       "expired entries must be dropped on the next record")
    }

    func test_record_keepsEntriesWhenRetentionIsZero() {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let policy = ClipboardHistoryPolicy(persistEnabled: false,
                                            maxItems: 50,
                                            retentionDays: 0)   // forever
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: policy,
                                          storageURL: nil,
                                          now: { clock.now })
        store.record(text: "ancient")
        clock.now = clock.now.addingTimeInterval(365 * 86_400)
        store.record(text: "now")

        XCTAssertEqual(store.entries.map(\.text), ["now", "ancient"],
                       "retentionDays == 0 means keep forever")
    }

    // MARK: - Persistence on disk

    func test_record_writesJSONWhenPersistEnabled() {
        let policy = ClipboardHistoryPolicy(persistEnabled: true,
                                            maxItems: 50,
                                            retentionDays: 0)
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: policy,
                                          storageURL: storageURL)
        store.record(text: "secret")

        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path),
                      "persistEnabled ⇒ record() must produce the JSON file")
        let decoded = ClipboardHistoryStore.loadPersisted(from: storageURL)
        XCTAssertEqual(decoded.map(\.text), ["secret"])
    }

    func test_record_doesNotWriteWhenPersistDisabled() {
        let policy = ClipboardHistoryPolicy(persistEnabled: false,
                                            maxItems: 50,
                                            retentionDays: 0)
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: policy,
                                          storageURL: storageURL)
        store.record(text: "memory only")

        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path),
                       "persistEnabled OFF ⇒ no file should land on disk")
    }

    func test_init_loadsPersistedEntriesWhenPersistEnabled() {
        // Stage 1: write three entries to disk through one store.
        let initial = ClipboardHistoryPolicy(persistEnabled: true,
                                             maxItems: 50,
                                             retentionDays: 0)
        do {
            let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                              policy: initial,
                                              storageURL: storageURL)
            store.record(text: "alpha")
            store.record(text: "beta")
            store.record(text: "gamma")
        }
        // Stage 2: a fresh store with the same URL must see them.
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: initial,
                                          storageURL: storageURL)
        XCTAssertEqual(store.entries.map(\.text), ["gamma", "beta", "alpha"],
                       "init must hydrate from the persisted JSON")
    }

    func test_init_appliesRetentionImmediately() {
        // Persist an old entry at t = 0.
        let policy = ClipboardHistoryPolicy(persistEnabled: true,
                                            maxItems: 50,
                                            retentionDays: 1)
        let oldClock = ClockBox(Date(timeIntervalSince1970: 0))
        do {
            let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                              policy: policy,
                                              storageURL: storageURL,
                                              now: { oldClock.now })
            store.record(text: "old")
        }
        // Now reload with a clock 2 days later. The init-time TTL
        // sweep must drop it before the picker even renders.
        let laterClock = ClockBox(Date(timeIntervalSince1970: 2 * 86_400))
        let reloaded = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                             policy: policy,
                                             storageURL: storageURL,
                                             now: { laterClock.now })
        XCTAssertTrue(reloaded.entries.isEmpty,
                      "expired persisted entries must be dropped on hydrate")
    }

    func test_init_ignoresDiskWhenPersistDisabled() {
        // Pre-seed the disk file under persist-enabled config.
        let onPolicy = ClipboardHistoryPolicy(persistEnabled: true,
                                              maxItems: 50,
                                              retentionDays: 0)
        do {
            let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                              policy: onPolicy,
                                              storageURL: storageURL)
            store.record(text: "leftover")
        }
        // Now construct one with persist disabled — entries must
        // NOT be hydrated, even though the file is still there.
        let offPolicy = ClipboardHistoryPolicy(persistEnabled: false,
                                               maxItems: 50,
                                               retentionDays: 0)
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: offPolicy,
                                          storageURL: storageURL)
        XCTAssertTrue(store.entries.isEmpty,
                      "persistEnabled OFF ⇒ ignore on-disk state")
    }

    func test_init_ignoresCorruptJSON() {
        try? "not json".write(to: storageURL, atomically: true, encoding: .utf8)
        let policy = ClipboardHistoryPolicy(persistEnabled: true,
                                            maxItems: 50,
                                            retentionDays: 0)
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: policy,
                                          storageURL: storageURL)
        XCTAssertTrue(store.entries.isEmpty,
                      "corrupt JSON must fall back to an empty FIFO, not crash")
    }

    // MARK: - updatePolicy() transitions

    func test_updatePolicy_offToOn_writesCurrentEntries() {
        let off = ClipboardHistoryPolicy(persistEnabled: false,
                                         maxItems: 50,
                                         retentionDays: 0)
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: off,
                                          storageURL: storageURL)
        store.record(text: "captured before opt-in")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))

        let on = ClipboardHistoryPolicy(persistEnabled: true,
                                        maxItems: 50,
                                        retentionDays: 0)
        store.updatePolicy(on)

        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
        let persisted = ClipboardHistoryStore.loadPersisted(from: storageURL)
        XCTAssertEqual(persisted.map(\.text), ["captured before opt-in"],
                       "OFF → ON must snapshot the current FIFO immediately")
    }

    func test_updatePolicy_onToOff_wipesDisk() {
        let on = ClipboardHistoryPolicy(persistEnabled: true,
                                        maxItems: 50,
                                        retentionDays: 0)
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: on,
                                          storageURL: storageURL)
        store.record(text: "captured")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))

        let off = ClipboardHistoryPolicy(persistEnabled: false,
                                         maxItems: 50,
                                         retentionDays: 0)
        store.updatePolicy(off)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path),
                       "ON → OFF must delete the on-disk JSON")
        XCTAssertEqual(store.entries.map(\.text), ["captured"],
                       "in-memory list must survive the transition; user has to Clear explicitly")
    }

    func test_updatePolicy_shrinksMaxItems() {
        let policy = ClipboardHistoryPolicy(persistEnabled: false,
                                            maxItems: 50,
                                            retentionDays: 0)
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: policy,
                                          storageURL: nil)
        for i in 0..<30 {
            store.record(text: "x-\(i)")
        }
        XCTAssertEqual(store.entries.count, 30)

        store.updatePolicy(ClipboardHistoryPolicy(persistEnabled: false,
                                                  maxItems: 10,
                                                  retentionDays: 0))
        XCTAssertEqual(store.entries.count, 10,
                       "shrinking maxItems must trim the tail immediately")
        XCTAssertEqual(store.entries.first?.text, "x-29",
                       "newest entries must survive the trim")
    }

    func test_updatePolicy_appliesRetentionImmediately() {
        let clock = ClockBox(Date(timeIntervalSince1970: 0))
        let policy = ClipboardHistoryPolicy(persistEnabled: false,
                                            maxItems: 50,
                                            retentionDays: 0)
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: policy,
                                          storageURL: nil,
                                          now: { clock.now })
        store.record(text: "old")           // captured at t = 0
        clock.now = clock.now.addingTimeInterval(5 * 86_400)
        store.record(text: "newer")         // captured at t = +5d

        // Now lower the TTL to 1 day; "old" must vanish even though
        // we didn't record anything new.
        store.updatePolicy(ClipboardHistoryPolicy(persistEnabled: false,
                                                  maxItems: 50,
                                                  retentionDays: 1))
        XCTAssertEqual(store.entries.map(\.text), ["newer"])
    }

    // MARK: - clear()

    func test_clear_alsoWipesDisk() {
        let on = ClipboardHistoryPolicy(persistEnabled: true,
                                        maxItems: 50,
                                        retentionDays: 0)
        let store = ClipboardHistoryStore(pasteboard: FakePasteboard(),
                                          policy: on,
                                          storageURL: storageURL)
        store.record(text: "secret")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path),
                       "clear() must scrub the on-disk file too")
    }

    // MARK: - EditorPreferences round-trip

    func test_prefs_persistEnabledRoundTrip() {
        let suiteName = "scribe.clipboard.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs.clipboardHistoryPersistEnabled,
                       ClipboardHistoryPolicy.default.persistEnabled,
                       "fresh defaults must match the Phase 57 baseline")
        prefs.clipboardHistoryPersistEnabled = true

        // Re-instantiate to assert disk round-trip.
        let reloaded = EditorPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.clipboardHistoryPersistEnabled,
                      "persistEnabled must survive a fresh prefs init")
    }

    func test_prefs_clampsOutOfRangeMaxItemsOnLoad() {
        let suiteName = "scribe.clipboard.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Pretend the user (or a misbehaving plugin) wrote 9999 to
        // defaults directly. The next prefs init must clamp.
        defaults.set(9_999, forKey: "clipboard.history.maxItems")
        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs.clipboardHistoryMaxItems,
                       ClipboardHistoryPolicy.maxItemsMax)
    }

    func test_prefs_clampsNegativeRetentionDaysOnLoad() {
        let suiteName = "scribe.clipboard.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(-7, forKey: "clipboard.history.retentionDays")
        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertEqual(prefs.clipboardHistoryRetentionDays,
                       ClipboardHistoryPolicy.retentionDaysMin)
    }

    func test_prefs_compositePolicyMatchesIndividualFields() {
        let suiteName = "scribe.clipboard.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = EditorPreferences(defaults: defaults)
        prefs.clipboardHistoryPersistEnabled = true
        prefs.clipboardHistoryMaxItems = 100
        prefs.clipboardHistoryRetentionDays = 7

        let policy = prefs.clipboardHistoryPolicy
        XCTAssertEqual(policy.persistEnabled, true)
        XCTAssertEqual(policy.maxItems, 100)
        XCTAssertEqual(policy.retentionDays, 7)
    }
}
