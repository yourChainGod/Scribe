//
//  JWTDecoderTests.swift
//  Phase 41a — vectors taken from jwt.io's "JWT Debugger" sample
//  token plus a couple of malformed inputs to lock the error paths.
//

import XCTest
@testable import Scribe

final class JWTDecoderTests: XCTestCase {

    /// jwt.io's stock HS256 sample. Header `{alg:HS256,typ:JWT}`
    /// + payload `{sub:"1234567890",name:"John Doe",iat:1516239022}`.
    private let sampleToken = """
        eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.\
        eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.\
        SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
        """

    // MARK: - Happy path

    func test_decode_returnsThreeSections() throws {
        let decoded = try JWTDecoder.decode(sampleToken)
        XCTAssertFalse(decoded.header.isEmpty)
        XCTAssertFalse(decoded.payload.isEmpty)
        XCTAssertEqual(decoded.signature, "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c")
    }

    func test_decode_headerExposesAlgAndTyp() throws {
        let decoded = try JWTDecoder.decode(sampleToken)
        XCTAssertTrue(decoded.header.contains("\"alg\""))
        XCTAssertTrue(decoded.header.contains("\"HS256\""))
        XCTAssertTrue(decoded.header.contains("\"typ\""))
        XCTAssertTrue(decoded.header.contains("\"JWT\""))
    }

    func test_decode_payloadExposesClaims() throws {
        let decoded = try JWTDecoder.decode(sampleToken)
        XCTAssertTrue(decoded.payload.contains("\"sub\""))
        XCTAssertTrue(decoded.payload.contains("\"1234567890\""))
        XCTAssertTrue(decoded.payload.contains("\"name\""))
        XCTAssertTrue(decoded.payload.contains("\"John Doe\""))
        XCTAssertTrue(decoded.payload.contains("\"iat\""))
        XCTAssertTrue(decoded.payload.contains("1516239022"))
    }

    func test_decode_payloadIsPrettyAndSorted() throws {
        let decoded = try JWTDecoder.decode(sampleToken)
        // Pretty-printed → newlines between top-level keys; sorted
        // → "iat" appears before "name" before "sub" alphabetically.
        XCTAssertTrue(decoded.payload.contains("\n"))
        let iat  = decoded.payload.range(of: "\"iat\"")!.lowerBound
        let name = decoded.payload.range(of: "\"name\"")!.lowerBound
        let sub  = decoded.payload.range(of: "\"sub\"")!.lowerBound
        XCTAssertLessThan(iat, name)
        XCTAssertLessThan(name, sub)
    }

    func test_decode_trimsSurroundingWhitespace() throws {
        let token = "  \n\(sampleToken)\n  "
        let decoded = try JWTDecoder.decode(token)
        XCTAssertFalse(decoded.payload.isEmpty)
    }

    // MARK: - Error paths

    func test_decode_malformedTwoSections_throws() {
        XCTAssertThrowsError(try JWTDecoder.decode("a.b")) { err in
            XCTAssertEqual(err as? JWTDecodeError, .malformed)
        }
    }

    func test_decode_emptyString_throws() {
        XCTAssertThrowsError(try JWTDecoder.decode("")) { err in
            XCTAssertEqual(err as? JWTDecodeError, .malformed)
        }
    }

    func test_decode_invalidBase64InHeader_throws() {
        // Section 1 contains characters that aren't in either the
        // standard or URL-safe base64 alphabet.
        let bad = "!!!!.eyJzdWIiOiIxIn0.sig"
        XCTAssertThrowsError(try JWTDecoder.decode(bad)) { err in
            guard case .invalidBase64(let seg) = (err as? JWTDecodeError) else {
                XCTFail("expected invalidBase64, got \(err)"); return
            }
            XCTAssertEqual(seg, .header)
        }
    }

    func test_decode_acceptsPaddingFreeBase64() throws {
        // jwt.io's encoder always strips '=' padding; we must
        // re-add it transparently. The sample token's header is
        // 18 chars, which would need two '=' to be padded, so
        // this is the same case-driver as `sampleToken`.
        let decoded = try JWTDecoder.decode(sampleToken)
        XCTAssertTrue(decoded.header.contains("HS256"))
    }
}
