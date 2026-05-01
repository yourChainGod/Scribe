//
//  FindStateDebounceTests.swift
//  Phase 45-D — verify FindState collapses query keystroke bursts into
//  a single `debouncedQuery` settle (150ms, RunLoop.main). This is the
//  "P1 #1" win from docs/perf_audit.md § 3 / § 4: the heavy paths
//  (highlight overlay re-scan, live-search caret jump) read
//  `debouncedQuery`, so a 5-character burst should fire one full-text
//  scan instead of five.
//
//  The tests are pure FindState + Combine — no Scintilla NSView, no
//  Coordinator. Burst behavior is observed by sinking on the
//  @Published `debouncedQuery` and counting *non-initial* emissions.
//

import Combine
import XCTest
@testable import Scribe

@MainActor
final class FindStateDebounceTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// Each test gets its own UserDefaults so MRU history loads from a
    /// clean slate and persistence between cases doesn't bleed.
    private func makeState() -> FindState {
        let suite = "FindStateDebounceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return FindState(defaults: defaults)
    }

    // MARK: - Initial state

    func test_debouncedQuery_initialEmpty() {
        let state = makeState()
        XCTAssertEqual(state.debouncedQuery, "")
        XCTAssertEqual(state.query, "")
    }

    // MARK: - Burst collapse

    /// 5 keystrokes inside 150ms should produce *one* settled
    /// `debouncedQuery` value equal to the final string. The initial
    /// empty publish is filtered by counting only the post-typing tail.
    func test_debouncedQuery_collapsesBurst() {
        let state = makeState()

        var observed: [String] = []
        state.$debouncedQuery
            .dropFirst()                    // skip the @Published seed
            .sink { observed.append($0) }
            .store(in: &cancellables)

        // Simulate "abcde" typed in a tight burst.
        let bursts = ["a", "ab", "abc", "abcd", "abcde"]
        for s in bursts {
            state.query = s
        }

        let exp = expectation(description: "debounce settles")
        // 150ms debounce + RunLoop slack — 350ms is plenty.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(observed.count, 1,
                       "expected one settled emission, got \(observed)")
        XCTAssertEqual(observed.last, "abcde")
        XCTAssertEqual(state.debouncedQuery, "abcde")
        XCTAssertEqual(state.query, "abcde",
                       "query itself is not debounced — TextField stays live")
    }

    /// Two bursts separated by > 150ms must each surface their own
    /// settled value. This guards against the debounce pipeline being
    /// installed once-only or accidentally collapsed across windows.
    func test_debouncedQuery_emitsForEachSettledBurst() {
        let state = makeState()

        var observed: [String] = []
        state.$debouncedQuery
            .dropFirst()
            .sink { observed.append($0) }
            .store(in: &cancellables)

        // Burst 1
        state.query = "f"
        state.query = "fo"
        state.query = "foo"

        let firstSettle = expectation(description: "first settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            firstSettle.fulfill()
        }
        wait(for: [firstSettle], timeout: 1.0)

        // Burst 2 — different value, fully after the first one drained.
        state.query = "bar"

        let secondSettle = expectation(description: "second settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            secondSettle.fulfill()
        }
        wait(for: [secondSettle], timeout: 1.0)

        XCTAssertEqual(observed, ["foo", "bar"])
    }

    /// Clearing the query is *also* a debounced settle — the heavy
    /// "highlight clear" path lives off `query.isEmpty` directly, but
    /// the `debouncedQuery` mirror should still reflect the empty
    /// state once it settles, so any consumer that subscribes to it
    /// (e.g. FindBar's onChange) sees the transition.
    func test_debouncedQuery_settlesToEmptyAfterClear() {
        let state = makeState()

        // Prime: type "abc" and let it settle.
        state.query = "abc"
        let prime = expectation(description: "prime settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { prime.fulfill() }
        wait(for: [prime], timeout: 1.0)
        XCTAssertEqual(state.debouncedQuery, "abc")

        var observed: [String] = []
        state.$debouncedQuery
            .dropFirst()
            .sink { observed.append($0) }
            .store(in: &cancellables)

        // Clear — instant on `query`, debounced on `debouncedQuery`.
        state.query = ""
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.debouncedQuery, "abc",
                       "clear is not yet settled")

        let clearSettle = expectation(description: "clear settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { clearSettle.fulfill() }
        wait(for: [clearSettle], timeout: 1.0)

        XCTAssertEqual(observed, [""])
        XCTAssertEqual(state.debouncedQuery, "")
    }
}
