//
//  ClipboardHistoryStoreTests.swift
//  Phase 57 — pure-data tests for ClipboardHistoryStore. The polling
//  Timer path is exercised by driving `pollOnce()` directly against a
//  fake `ClipboardSource`, so we don't have to rely on a real
//  NSPasteboard (which races with whatever the dev or CI machine has
//  on its clipboard during the run).
//

import XCTest
import AppKit
@testable import Scribe

@MainActor
final class ClipboardHistoryStoreTests: XCTestCase {

    /// Test double for `ClipboardSource`. Tests bump `changeCount`
    /// before changing `value` to mimic what the system pasteboard
    /// does on a real copy. `pollOnce()` reads change count first and
    /// only pulls the string when it differs from the last seen.
    final class FakePasteboard: ClipboardSource {
        var changeCount: Int = 0
        var value: String?
        func string(forType type: NSPasteboard.PasteboardType) -> String? {
            value
        }

        /// Convenience to mimic a real copy: bumps changeCount AND
        /// overwrites the stored value so `pollOnce()` records.
        func write(_ s: String) {
            changeCount += 1
            value = s
        }
    }

    // MARK: - record() basics

    func test_record_prependsNewEntries() {
        let store = ClipboardHistoryStore()
        store.record(text: "alpha")
        store.record(text: "beta")
        store.record(text: "gamma")
        XCTAssertEqual(store.entries.map(\.text),
                       ["gamma", "beta", "alpha"],
                       "most recent must land at index 0")
    }

    func test_record_dedupesByMovingExistingToTop() {
        let store = ClipboardHistoryStore()
        store.record(text: "alpha")
        store.record(text: "beta")
        store.record(text: "alpha")   // re-copy of existing entry
        XCTAssertEqual(store.entries.map(\.text), ["alpha", "beta"],
                       "duplicates collapse and the re-copied value moves to the top")
        XCTAssertEqual(store.entries.count, 2)
    }

    func test_record_rejectsEmptyString() {
        // The system pasteboard returns "" briefly during a clear.
        // The store must drop it so the picker doesn't accumulate
        // empty rows from screenshots / app switches.
        let store = ClipboardHistoryStore()
        store.record(text: "")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_record_capsAtCapacityDroppingOldest() {
        let store = ClipboardHistoryStore()
        // Drive past the cap so the oldest must roll off.
        let total = ClipboardHistoryStore.capacity + 5
        for i in 0..<total {
            store.record(text: "item-\(i)")
        }
        XCTAssertEqual(store.entries.count, ClipboardHistoryStore.capacity)
        XCTAssertEqual(store.entries.first?.text, "item-\(total - 1)",
                       "head is most recent")
        // Tail is the oldest item that survived the trim — items 0..4
        // should have rolled off.
        XCTAssertEqual(store.entries.last?.text, "item-5",
                       "items below capacity must drop")
    }

    // MARK: - pollOnce()

    func test_pollOnce_recordsFirstChangeAfterInit() {
        let pb = FakePasteboard()
        // Init reads the initial changeCount so the fake's "no
        // pasteboard activity yet" doesn't immediately record.
        let store = ClipboardHistoryStore(pasteboard: pb)
        XCTAssertTrue(store.entries.isEmpty,
                      "init must skip whatever's on the pasteboard at launch")

        pb.write("hello")
        store.pollOnce()

        XCTAssertEqual(store.entries.map(\.text), ["hello"])
    }

    func test_pollOnce_skipsWhenChangeCountUnchanged() {
        // Critical contract: ClipboardHistoryStore captures the
        // pasteboard's `changeCount` at init time, so anything the
        // user had on the clipboard before launch is *not* recorded.
        // Only a fresh copy (which bumps the count past the snapshot)
        // makes it into the FIFO. We therefore have to write *after*
        // init, not before.
        let pb = FakePasteboard()
        let store = ClipboardHistoryStore(pasteboard: pb)
        pb.write("first")
        store.pollOnce()
        XCTAssertEqual(store.entries.map(\.text), ["first"])

        // No further pasteboard activity — pollOnce must no-op.
        store.pollOnce()
        store.pollOnce()
        XCTAssertEqual(store.entries.count, 1,
                       "subsequent polls without a changeCount bump must skip")
    }

    func test_pollOnce_recordsConsecutiveDistinctValues() {
        let pb = FakePasteboard()
        let store = ClipboardHistoryStore(pasteboard: pb)
        pb.write("alpha"); store.pollOnce()
        pb.write("beta");  store.pollOnce()
        pb.write("gamma"); store.pollOnce()
        XCTAssertEqual(store.entries.map(\.text), ["gamma", "beta", "alpha"])
    }

    func test_pollOnce_dedupesAcrossPolls() {
        let pb = FakePasteboard()
        let store = ClipboardHistoryStore(pasteboard: pb)
        pb.write("foo"); store.pollOnce()
        pb.write("bar"); store.pollOnce()
        pb.write("foo"); store.pollOnce()   // user re-copies foo
        XCTAssertEqual(store.entries.map(\.text), ["foo", "bar"],
                       "re-copy must move foo to the top, not duplicate it")
    }

    // MARK: - clear()

    func test_clear_emptiesEntriesButPreservesChangeCountWatermark() {
        let pb = FakePasteboard()
        let store = ClipboardHistoryStore(pasteboard: pb)
        pb.write("a"); store.pollOnce()
        pb.write("b"); store.pollOnce()
        XCTAssertEqual(store.entries.count, 2)

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)

        // After clear, polling without a fresh copy must still no-op
        // — the changeCount watermark survived clear() so the user's
        // existing clipboard value doesn't slip back into the list.
        store.pollOnce()
        XCTAssertTrue(store.entries.isEmpty,
                      "clear must not reset the changeCount watermark")

        // A genuine new copy still records.
        pb.write("c"); store.pollOnce()
        XCTAssertEqual(store.entries.map(\.text), ["c"])
    }
}
