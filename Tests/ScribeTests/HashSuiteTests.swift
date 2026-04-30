//
//  HashSuiteTests.swift
//  Phase 41a — locks the digest output against well-known vectors
//  so an upstream CryptoKit / Swift change can't silently drift the
//  bytes we emit. CRC32 uses zlib's IEEE table; vectors taken from
//  RFC 1952 §8 ("123456789" → 0xCBF43926) and OpenSSL's
//  `echo -n … | md5/sha1sum` baseline.
//

import XCTest
@testable import Scribe

final class HashSuiteTests: XCTestCase {

    // MARK: - Empty input

    func test_md5_emptyString() {
        XCTAssertEqual(HashSuite.md5(""), "d41d8cd98f00b204e9800998ecf8427e")
    }

    func test_sha1_emptyString() {
        XCTAssertEqual(HashSuite.sha1(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    func test_sha256_emptyString() {
        XCTAssertEqual(HashSuite.sha256(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func test_sha512_emptyString() {
        XCTAssertEqual(HashSuite.sha512(""),
            "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
    }

    func test_crc32_emptyString() {
        XCTAssertEqual(HashSuite.crc32(""), "00000000")
    }

    // MARK: - "abc" — short canonical vector

    func test_md5_abc() {
        XCTAssertEqual(HashSuite.md5("abc"), "900150983cd24fb0d6963f7d28e17f72")
    }

    func test_sha1_abc() {
        XCTAssertEqual(HashSuite.sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    func test_sha256_abc() {
        XCTAssertEqual(HashSuite.sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func test_sha512_abc() {
        XCTAssertEqual(HashSuite.sha512("abc"),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    }

    // MARK: - CRC32 zlib reference vectors

    func test_crc32_oneToNine() {
        // RFC 1952 §8, well-known zlib test vector.
        XCTAssertEqual(HashSuite.crc32("123456789"), "cbf43926")
    }

    func test_crc32_helloWorld() {
        // OpenSSL: `python3 -c "import zlib; print('%08x' % zlib.crc32(b'hello world'))"`
        XCTAssertEqual(HashSuite.crc32("hello world"), "0d4a1185")
    }

    // MARK: - UTF-8 multibyte input

    func test_md5_utf8() {
        // `echo -n '你好' | md5` (macOS): bytes E4 BD A0 E5 A5 BD
        XCTAssertEqual(HashSuite.md5("你好"), "7eca689f0d3389d9dea66ae112e5cfd7")
    }

    func test_sha256_utf8() {
        XCTAssertEqual(HashSuite.sha256("你好"),
            "670d9743542cae3ea7ebe36af56bd53648b0a1126162e78d81a32934a711302e")
    }

    // MARK: - Determinism — same input twice, same output

    func test_allHashes_areDeterministic() {
        let s = "the quick brown fox jumps over the lazy dog"
        XCTAssertEqual(HashSuite.md5(s),    HashSuite.md5(s))
        XCTAssertEqual(HashSuite.sha1(s),   HashSuite.sha1(s))
        XCTAssertEqual(HashSuite.sha256(s), HashSuite.sha256(s))
        XCTAssertEqual(HashSuite.sha512(s), HashSuite.sha512(s))
        XCTAssertEqual(HashSuite.crc32(s),  HashSuite.crc32(s))
    }

    // MARK: - Output shape

    func test_md5_outputIs32HexChars() {
        XCTAssertEqual(HashSuite.md5("anything").count, 32)
    }

    func test_sha1_outputIs40HexChars() {
        XCTAssertEqual(HashSuite.sha1("anything").count, 40)
    }

    func test_sha256_outputIs64HexChars() {
        XCTAssertEqual(HashSuite.sha256("anything").count, 64)
    }

    func test_sha512_outputIs128HexChars() {
        XCTAssertEqual(HashSuite.sha512("anything").count, 128)
    }

    func test_crc32_outputIs8HexChars() {
        XCTAssertEqual(HashSuite.crc32("anything").count, 8)
    }
}
