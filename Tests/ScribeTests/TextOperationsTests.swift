//
//  TextOperationsTests.swift
//  Phase 37 — pure text split / merge / shuffle operations.
//

import CryptoKit
import XCTest
@testable import Scribe

final class TextOperationsTests: XCTestCase {

    func test_delimiterSplitPreservesEmptyTrailingColumns() {
        let table = TextTableSplitter.split("name,age,\nAda,36,\n",
                                            strategy: .delimiter(","))

        XCTAssertEqual(table.rows, [
            ["name", "age", ""],
            ["Ada", "36", ""]
        ])
    }

    func test_quotedCSVSplitHandlesEscapedQuotesAndTrailingColumns() {
        let table = TextTableSplitter.split(
            "name,note,\r\nAda,\"said \"\"hello\"\"\",",
            strategy: .quotedDelimiter(",")
        )

        XCTAssertEqual(table.rows, [
            ["name", "note", ""],
            ["Ada", "said \"hello\"", ""]
        ])
    }

    func test_tsvPresetPreservesEmptyCells() {
        let table = TextTableSplitter.split("a\t\tc\n1\t2\t",
                                            strategy: .delimiter("\t"))

        XCTAssertEqual(table.rows, [
            ["a", "", "c"],
            ["1", "2", ""]
        ])
    }

    func test_regularExpressionSplitUsesMatchesAsSeparators() {
        let table = TextTableSplitter.split("alpha :: beta -> gamma",
                                            strategy: .regularExpression("\\s*(::|->)\\s*"))

        XCTAssertEqual(table.rows, [["alpha", "beta", "gamma"]])
    }

    func test_fixedWidthSplitKeepsRemainderAsLastColumn() {
        let table = TextTableSplitter.split("ABCDEF\n1234567",
                                            strategy: .fixedWidths([2, 3]))

        XCTAssertEqual(table.rows, [
            ["AB", "CDE", "F"],
            ["12", "345", "67"]
        ])
    }

    func test_columnPlanReordersSelectedColumnsAndMergesRows() {
        let table = TextTable(rows: [
            ["first", "last", "city"],
            ["Ada", "Lovelace", "London"],
            ["Alan", "Turing", "Manchester"]
        ])
        let plan = ColumnPlan(selectedIndexes: [1, 0],
                              joinDelimiter: ", ")

        XCTAssertEqual(plan.render(table: table),
                       "last, first\nLovelace, Ada\nTuring, Alan")
    }

    func test_columnPlanMissingCellsRenderAsEmptyStrings() {
        let table = TextTable(rows: [
            ["a", "b"],
            ["only-a"]
        ])
        let plan = ColumnPlan(selectedIndexes: [0, 1],
                              joinDelimiter: "|")

        XCTAssertEqual(plan.render(table: table),
                       "a|b\nonly-a|")
    }

    func test_columnRecipeRendersDraggedColumnsAndFixedText() {
        let table = TextTable(rows: [
            ["Ada", "Lovelace"],
            ["Alan", "Turing"]
        ])
        let recipe = ColumnRecipe(parts: [
            .literal("@"),
            .column(1),
            .literal(", "),
            .column(0),
            .literal("!")
        ])

        XCTAssertEqual(recipe.render(table: table),
                       "@Lovelace, Ada!\n@Turing, Alan!")
    }

    func test_columnRecipeUsesPlaceholderOnlyForMissingCells() {
        let table = TextTable(rows: [
            ["a", ""],
            ["only-a"]
        ])
        let recipe = ColumnRecipe(parts: [
            .column(0),
            .literal("|"),
            .column(1)
        ], missingCellPlaceholder: "<missing>")

        XCTAssertEqual(recipe.render(table: table),
                       "a|\nonly-a|<missing>")
    }

    func test_textTableMergesImportedSourceByRowIndex() {
        let primary = TextTable(rows: [
            ["name", "age"],
            ["Ada", "36"]
        ])
        let imported = TextTable(rows: [
            ["city"],
            ["London"],
            ["Manchester"]
        ])

        let merged = TextTable.mergeByRow(primary, imported)

        XCTAssertEqual(merged.rows, [
            ["name", "age", "city"],
            ["Ada", "36", "London"],
            ["", "", "Manchester"]
        ])
    }

    func test_textTableMergesImportedSourcesByKeyColumn() {
        let primary = TextTable(rows: [
            ["id", "name"],
            ["1", "Ada"],
            ["2", "Alan"]
        ])
        let cities = TextTable(rows: [
            ["id", "city"],
            ["2", "Manchester"],
            ["1", "London"],
            ["3", "Paris"]
        ])
        let roles = TextTable(rows: [
            ["id", "role"],
            ["1", "Math"],
            ["3", "Poet"],
            ["2", "Code"]
        ])

        let merged = TextTable.mergeByKey(primary: primary,
                                          imported: [cities, roles],
                                          keyColumn: 0)

        XCTAssertEqual(merged.rows, [
            ["id", "name", "id", "city", "id", "role"],
            ["1", "Ada", "1", "London", "1", "Math"],
            ["2", "Alan", "2", "Manchester", "2", "Code"],
            ["", "", "3", "Paris", "3", "Poet"]
        ])
    }

    func test_shuffleLinesWithSeedIsDeterministic() {
        let input = "one\ntwo\nthree\nfour"

        let first = TextLineShuffler.shuffle(input, seed: 42)
        let second = TextLineShuffler.shuffle(input, seed: 42)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, input)
        XCTAssertEqual(Set(first.components(separatedBy: "\n")),
                       Set(input.components(separatedBy: "\n")))
    }

    func test_shuffleLinesPreservesFinalNewlineOutsideShufflePool() {
        let input = "one\ntwo\nthree\n"

        let output = TextLineShuffler.shuffle(input, seed: 42)

        XCTAssertTrue(output.hasSuffix("\n"))
        XCTAssertEqual(Set(output.dropLast().components(separatedBy: "\n")),
                       Set(["one", "two", "three"]))
    }

    func test_shuffleLinesCanPreserveHeaderAndBlankLinePositions() {
        let input = "header\nalpha\n\nbeta\ngamma"

        let output = TextLineShuffler.shuffle(input,
                                              seed: 7,
                                              preserveFirstLine: true,
                                              preserveBlankLinePositions: true)
        let lines = output.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "header")
        XCTAssertEqual(lines[2], "")
        XCTAssertEqual(Set(lines.filter { !$0.isEmpty && $0 != "header" }),
                       ["alpha", "beta", "gamma"])
    }

    func test_transformConvertsIntegersBetweenBases() throws {
        XCTAssertEqual(
            try TextTransform.convertInteger("ff", fromBase: 16, toBase: 10),
            "255"
        )
        XCTAssertEqual(
            try TextTransform.convertInteger("255", fromBase: 10, toBase: 2),
            "11111111"
        )
    }

    func test_transformURLEncodingRoundTripsUnicode() throws {
        let encoded = TextTransform.urlEncode("a b 中文")

        XCTAssertEqual(encoded, "a%20b%20%E4%B8%AD%E6%96%87")
        XCTAssertEqual(try TextTransform.urlDecode(encoded), "a b 中文")
    }

    func test_transformBase64DecodeRejectsInvalidInput() throws {
        XCTAssertEqual(TextTransform.base64Encode("Scribe"), "U2NyaWJl")

        XCTAssertThrowsError(try TextTransform.base64Decode("%%%")) { error in
            XCTAssertEqual(error as? TextTransformError, .invalidBase64)
        }
    }

    func test_transformHTMLEscapeAndUnescape() {
        let escaped = TextTransform.htmlEscape("<tag attr=\"&\">")

        XCTAssertEqual(escaped, "&lt;tag attr=&quot;&amp;&quot;&gt;")
        XCTAssertEqual(TextTransform.htmlUnescape(escaped), "<tag attr=\"&\">")
    }

    func test_transformJSONStringEscapeAndUnescape() throws {
        let escaped = try TextTransform.jsonStringEscape("line\n\"quoted\"")

        XCTAssertEqual(escaped, "line\\n\\\"quoted\\\"")
        XCTAssertEqual(try TextTransform.jsonStringUnescape(escaped), "line\n\"quoted\"")
    }

    func test_transformActionAppliesMenuBackedOperations() throws {
        XCTAssertEqual(try TextTransformAction.urlEncode.apply(to: "a b"),
                       "a%20b")
        XCTAssertEqual(try TextTransformAction.base64Decode.apply(to: "U2NyaWJl"),
                       "Scribe")
        XCTAssertEqual(try TextTransformAction.convertBase(fromBase: 16, toBase: 10).apply(to: "ff"),
                       "255")
        XCTAssertEqual(try TextTransformAction.htmlEscape.apply(to: "<a&b>"),
                       "&lt;a&amp;b&gt;")
    }

    func test_transformActionShuffleUsesStableDefaultOptions() throws {
        let input = "header\nalpha\n\nbeta\ngamma"

        let output = try TextTransformAction.shuffleLines(seed: 7,
                                                          preserveFirstLine: true,
                                                          preserveBlankLinePositions: true)
            .apply(to: input)
        let lines = output.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "header")
        XCTAssertEqual(lines[2], "")
        XCTAssertEqual(Set(lines.filter { !$0.isEmpty && $0 != "header" }),
                       ["alpha", "beta", "gamma"])
    }

    func test_transformActionAESGCMEncryptsAndDecryptsWithPassword() throws {
        let encrypted = try TextTransformAction.aesGCMEncrypt(password: "correct horse")
            .apply(to: "Scribe secret")

        XCTAssertNotEqual(encrypted, "Scribe secret")
        XCTAssertTrue(encrypted.hasPrefix("scribe-aesgcm-v2$pbkdf2-sha256$100000$"))
        XCTAssertEqual(
            try TextTransformAction.aesGCMDecrypt(password: "correct horse").apply(to: encrypted),
            "Scribe secret"
        )
    }

    func test_transformActionAESGCMUsesFreshSalt() throws {
        let first = try TextTransformAction.aesGCMEncrypt(password: "same password")
            .apply(to: "Scribe secret")
        let second = try TextTransformAction.aesGCMEncrypt(password: "same password")
            .apply(to: "Scribe secret")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            try TextTransformAction.aesGCMDecrypt(password: "same password").apply(to: first),
            "Scribe secret"
        )
        XCTAssertEqual(
            try TextTransformAction.aesGCMDecrypt(password: "same password").apply(to: second),
            "Scribe secret"
        )
    }

    func test_transformActionAESGCMRejectsWrongPassword() throws {
        let encrypted = try TextTransformAction.aesGCMEncrypt(password: "one")
            .apply(to: "Scribe secret")

        XCTAssertThrowsError(
            try TextTransformAction.aesGCMDecrypt(password: "two").apply(to: encrypted)
        ) { error in
            XCTAssertEqual(error as? TextTransformError, .invalidCiphertext)
        }
    }

    func test_transformActionAESGCMDecryptsLegacyCiphertext() throws {
        let legacy = try legacyAESGCMCiphertext("Legacy secret", password: "old password")

        XCTAssertFalse(legacy.hasPrefix("scribe-aesgcm-v2$"))
        XCTAssertEqual(
            try TextTransformAction.aesGCMDecrypt(password: "old password").apply(to: legacy),
            "Legacy secret"
        )
    }

    private func legacyAESGCMCiphertext(_ text: String,
                                        password: String) throws -> String {
        let digest = SHA256.hash(data: Data(password.utf8))
        let sealed = try AES.GCM.seal(Data(text.utf8),
                                      using: SymmetricKey(data: digest))
        guard let combined = sealed.combined else {
            throw TextTransformError.invalidCiphertext
        }
        return combined.base64EncodedString()
    }
}
