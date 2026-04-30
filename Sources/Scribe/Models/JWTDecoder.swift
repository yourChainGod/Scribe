//
//  JWTDecoder.swift
//  Phase 41a — read-only JWT inspection. We do NOT verify
//  signatures: validating an HS256/RS256/ES256 token against a
//  secret/public key is a server-side concern; what developers
//  reach for in a text editor is "decode the claims so I can
//  paste them into a bug report or eyeball an exp / aud field".
//
//  Both header and payload are parsed as base64url, then the
//  resulting bytes are pretty-printed as JSON (sorted keys).
//  Falls back to raw UTF-8 text if a segment isn't valid JSON
//  (rare but legal — RFC 7519 only constrains the registered
//  claims; the body just has to be base64url).
//

import Foundation

struct JWTDecoded: Equatable {
    let header: String
    let payload: String
    let signature: String
    let raw: String
}

enum JWTDecodeError: Error, Equatable {
    case malformed
    case invalidBase64(segment: Segment)
    case invalidUTF8(segment: Segment)

    enum Segment: String, Equatable {
        case header, payload
    }
}

enum JWTDecoder {

    /// Parse `token` (whitespace-trimmed) into header / payload /
    /// signature. Throws on malformed input; never throws on
    /// unrecognized JSON shapes (the segment is simply returned
    /// as raw text in that case so the user can still inspect it).
    static func decode(_ token: String) throws -> JWTDecoded {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw JWTDecodeError.malformed }
        let h = String(parts[0])
        let p = String(parts[1])
        let s = String(parts[2])
        let header = try prettyJSON(fromBase64URL: h, segment: .header)
        let payload = try prettyJSON(fromBase64URL: p, segment: .payload)
        return JWTDecoded(header: header, payload: payload,
                          signature: s, raw: trimmed)
    }

    // MARK: - Private

    private static func prettyJSON(fromBase64URL raw: String,
                                   segment: JWTDecodeError.Segment) throws -> String {
        guard let data = base64URLDecode(raw) else {
            throw JWTDecodeError.invalidBase64(segment: segment)
        }
        if let obj = try? JSONSerialization.jsonObject(with: data,
                                                       options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: pretty, encoding: .utf8) {
            return str
        }
        guard let str = String(data: data, encoding: .utf8) else {
            throw JWTDecodeError.invalidUTF8(segment: segment)
        }
        return str
    }

    /// Base64-URL → bytes. Adds RFC 4648 padding before delegating
    /// to `Data(base64Encoded:)`; converts the URL-safe alphabet
    /// (`-`, `_`) back to the standard one.
    private static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b.count % 4) % 4
        if pad > 0 { b.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: b)
    }
}
