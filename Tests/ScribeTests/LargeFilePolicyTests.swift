//
//  LargeFilePolicyTests.swift
//  Phase 34a — locks down the threshold + bitmask decisions so the
//  Workspace dispatcher and the LargeFileLoader stay in agreement
//  about what "large" means.
//

import XCTest
@testable import Scribe

final class LargeFilePolicyTests: XCTestCase {

    // MARK: - Threshold

    func test_smallFileTakesStringPath() {
        XCTAssertFalse(LargeFilePolicy.shouldUseChunkedLoad(forSize: 1_024))
        XCTAssertFalse(LargeFilePolicy.shouldUseChunkedLoad(forSize: 1_000_000))
        XCTAssertFalse(LargeFilePolicy.shouldUseChunkedLoad(
            forSize: LargeFilePolicy.thresholdBytes - 1))
    }

    func test_atOrOverThresholdTakesChunkedPath() {
        XCTAssertTrue(LargeFilePolicy.shouldUseChunkedLoad(
            forSize: LargeFilePolicy.thresholdBytes))
        XCTAssertTrue(LargeFilePolicy.shouldUseChunkedLoad(
            forSize: LargeFilePolicy.thresholdBytes + 1))
    }

    // MARK: - Loader options bitmask

    func test_optionsAlwaysIncludeStylesNone() {
        // Even a borderline-large file disables the lexer pass —
        // it dominates load time at this scale and the user almost
        // always wants "show the text now, colourise later".
        let opts = LargeFilePolicy.loaderOptions(
            forSize: LargeFilePolicy.thresholdBytes)
        XCTAssertEqual(opts & SC.DOCUMENTOPTION_STYLES_NONE,
                       SC.DOCUMENTOPTION_STYLES_NONE)
    }

    func test_subGigabyteFileSkipsTextLarge() {
        // 32-bit positions cap at ~2 GiB; we don't flip the
        // expensive 64-bit machinery on for a 100 MB file.
        let opts = LargeFilePolicy.loaderOptions(forSize: 100 * 1024 * 1024)
        XCTAssertEqual(opts & SC.DOCUMENTOPTION_TEXT_LARGE, 0)
    }

    func test_multiGigabyteFileFlipsTextLarge() {
        // Ensure the threshold for TEXT_LARGE is *strictly* below
        // the 32-bit position limit so a streaming log can grow
        // during the load without overflow.
        let opts = LargeFilePolicy.loaderOptions(forSize: 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(opts & SC.DOCUMENTOPTION_TEXT_LARGE,
                       SC.DOCUMENTOPTION_TEXT_LARGE)
        XCTAssertEqual(opts & SC.DOCUMENTOPTION_STYLES_NONE,
                       SC.DOCUMENTOPTION_STYLES_NONE)
    }

    func test_textLargeThresholdIsBelow32BitCap() {
        // Defensive: somebody bumping the threshold past 2 GiB would
        // silently re-enable the truncation hazard.
        XCTAssertLessThan(LargeFilePolicy.textLargePositionsThreshold,
                          2 * 1024 * 1024 * 1024)
    }
}
