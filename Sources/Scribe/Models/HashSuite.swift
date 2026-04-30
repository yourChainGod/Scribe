//
//  HashSuite.swift
//  Phase 41a — pure-function hash digests for selection / document
//  transforms (Tools ▶ Hash submenu, right-click ▸ Hash, palette).
//
//  All hashes operate on the UTF-8 byte representation of the
//  input string and return lowercase hex digests; that's the
//  single most common form developers paste into ticket
//  trackers, so we don't expose an "uppercase" toggle. CRC32
//  uses the IEEE polynomial (0xEDB88320 reflected), matching
//  zlib / crc32 / Python's `binascii.crc32` output so users can
//  cross-check against any tool they already trust.
//
//  CryptoKit ships SHA-1/SHA-256/SHA-512 and MD5 (the latter
//  via the `Insecure` namespace, which mirrors how we treat
//  it: still useful for ETag-style checksums, never for crypto).
//

import Foundation
import CryptoKit

enum HashSuite {

    // MARK: - SHA family + MD5

    static func md5(_ text: String) -> String {
        hex(of: Insecure.MD5.hash(data: Data(text.utf8)))
    }

    static func sha1(_ text: String) -> String {
        hex(of: Insecure.SHA1.hash(data: Data(text.utf8)))
    }

    static func sha256(_ text: String) -> String {
        hex(of: SHA256.hash(data: Data(text.utf8)))
    }

    static func sha512(_ text: String) -> String {
        hex(of: SHA512.hash(data: Data(text.utf8)))
    }

    // MARK: - CRC32 (IEEE)

    /// IEEE-polynomial CRC32, reflected, init 0xFFFFFFFF, xor-out
    /// 0xFFFFFFFF — same parameters as zlib's `crc32`, gzip,
    /// PNG IDAT, and `binascii.crc32`. Output is lowercase hex,
    /// 8 chars wide (zero-padded).
    static func crc32(_ text: String) -> String {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in text.utf8 {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ Self.crc32Table[idx]
        }
        crc ^= 0xFFFFFFFF
        return String(format: "%08x", crc)
    }

    // MARK: - Private helpers

    private static func hex<D: ContiguousBytes>(of digest: D) -> String {
        digest.withUnsafeBytes { buf in
            buf.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Pre-computed lookup table for the IEEE CRC32 polynomial.
    /// Built once at first use, then cached for the process
    /// lifetime — small (1 KiB) and hot enough that the
    /// init cost would otherwise show up in benchmarks.
    private static let crc32Table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()
}
