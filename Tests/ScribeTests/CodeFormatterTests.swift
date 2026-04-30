//
//  CodeFormatterTests.swift
//  Phase 41c — Pretty / Minify coverage for JSON / XML / CSS / SQL.
//
//  Each language gets:
//    • happy-path pretty (canonical fixture)
//    • happy-path minify (round-trips the pretty)
//    • boundaries (empty, single-token)
//    • language-specific edge cases (escapes, comments, nesting)
//    • round-trip pretty(minify(x)) == pretty(x)
//

import XCTest
@testable import Scribe

final class CodeFormatterTests: XCTestCase {

    // MARK: - JSON

    func test_json_pretty_objectAndArray() throws {
        let input = #"{"a":1,"b":[2,3]}"#
        let expected = """
        {
          "a": 1,
          "b": [
            2,
            3
          ]
        }
        """
        XCTAssertEqual(try CodeFormatter.JSON.pretty(input), expected)
    }

    func test_json_pretty_preservesKeyOrder() throws {
        let input = #"{"z":1,"a":2,"m":3}"#
        let expected = """
        {
          "z": 1,
          "a": 2,
          "m": 3
        }
        """
        XCTAssertEqual(try CodeFormatter.JSON.pretty(input), expected)
    }

    func test_json_pretty_emptyContainersStayFlat() throws {
        XCTAssertEqual(try CodeFormatter.JSON.pretty("[]"), "[]")
        XCTAssertEqual(try CodeFormatter.JSON.pretty("{}"), "{}")
        let input = #"{"empty":{},"list":[]}"#
        let expected = """
        {
          "empty": {},
          "list": []
        }
        """
        XCTAssertEqual(try CodeFormatter.JSON.pretty(input), expected)
    }

    func test_json_pretty_customIndent() throws {
        let input = #"{"a":1}"#
        let expected = """
        {
            "a": 1
        }
        """
        XCTAssertEqual(try CodeFormatter.JSON.pretty(input, indent: 4), expected)
    }

    func test_json_minify_stripsAllWhitespace() throws {
        let input = """
        {
          "a": 1,
          "b": [2, 3]
        }
        """
        XCTAssertEqual(try CodeFormatter.JSON.minify(input),
                       #"{"a":1,"b":[2,3]}"#)
    }

    func test_json_minify_preservesStringContent() throws {
        let input = #"{ "msg" : "hello world" }"#
        XCTAssertEqual(try CodeFormatter.JSON.minify(input),
                       #"{"msg":"hello world"}"#)
    }

    func test_json_minify_preservesEscapesInString() throws {
        let input = #"{ "k" : "a\"b\\c" }"#
        XCTAssertEqual(try CodeFormatter.JSON.minify(input),
                       #"{"k":"a\"b\\c"}"#)
    }

    func test_json_roundTrip_minifyThenPretty() throws {
        let pretty = """
        {
          "a": 1,
          "b": [
            2,
            3
          ]
        }
        """
        let minified = try CodeFormatter.JSON.minify(pretty)
        XCTAssertEqual(try CodeFormatter.JSON.pretty(minified), pretty)
    }

    func test_json_pretty_emptyInputIsEmpty() throws {
        XCTAssertEqual(try CodeFormatter.JSON.pretty(""), "")
        XCTAssertEqual(try CodeFormatter.JSON.minify(""), "")
    }

    func test_json_throwsOnUnterminatedString() {
        XCTAssertThrowsError(try CodeFormatter.JSON.pretty(#"{"k":"abc"#))
    }

    // MARK: - XML

    func test_xml_pretty_simpleNesting() throws {
        let input = "<a><b/></a>"
        let expected = """
        <a>
          <b/>
        </a>
        """
        XCTAssertEqual(try CodeFormatter.XML.pretty(input), expected)
    }

    func test_xml_pretty_textContent() throws {
        let input = "<a><b>hello</b></a>"
        let expected = """
        <a>
          <b>
            hello
          </b>
        </a>
        """
        XCTAssertEqual(try CodeFormatter.XML.pretty(input), expected)
    }

    func test_xml_pretty_handlesProlog() throws {
        let input = #"<?xml version="1.0"?><root><a/></root>"#
        let expected = """
        <?xml version="1.0"?>
        <root>
          <a/>
        </root>
        """
        XCTAssertEqual(try CodeFormatter.XML.pretty(input), expected)
    }

    func test_xml_pretty_handlesComment() throws {
        let input = "<a><!-- note --><b/></a>"
        let expected = """
        <a>
          <!-- note -->
          <b/>
        </a>
        """
        XCTAssertEqual(try CodeFormatter.XML.pretty(input), expected)
    }

    func test_xml_minify_dropsBetweenTagWhitespace() throws {
        let input = """
        <a>
          <b>hi</b>
        </a>
        """
        XCTAssertEqual(try CodeFormatter.XML.minify(input),
                       "<a><b>hi</b></a>")
    }

    func test_xml_minify_keepsTextContent() throws {
        let input = "<a> <b>hello world</b> </a>"
        XCTAssertEqual(try CodeFormatter.XML.minify(input),
                       "<a><b>hello world</b></a>")
    }

    func test_xml_throwsOnUnterminatedTag() {
        XCTAssertThrowsError(try CodeFormatter.XML.pretty("<a"))
    }

    func test_xml_throwsOnUnterminatedComment() {
        XCTAssertThrowsError(try CodeFormatter.XML.pretty("<a><!-- oops"))
    }

    // MARK: - CSS

    func test_css_pretty_simpleRule() throws {
        let input = ".x{color:red;font-weight:bold}"
        let expected = """
        .x {
          color: red;
          font-weight: bold;
        }
        """
        XCTAssertEqual(try CodeFormatter.CSS.pretty(input), expected)
    }

    func test_css_pretty_nestedAtRule() throws {
        let input = "@media (max-width:600px){.x{color:red}}"
        let expected = """
        @media (max-width:600px) {
          .x {
            color: red;
          }
        }
        """
        XCTAssertEqual(try CodeFormatter.CSS.pretty(input), expected)
    }

    func test_css_pretty_stripsComments() throws {
        let input = ".x { /* hi */ color: red; }"
        let expected = """
        .x {
          color: red;
        }
        """
        XCTAssertEqual(try CodeFormatter.CSS.pretty(input), expected)
    }

    func test_css_minify_basic() throws {
        let input = """
        .x {
          color: red;
          font-weight: bold;
        }
        """
        XCTAssertEqual(try CodeFormatter.CSS.minify(input),
                       ".x{color:red;font-weight:bold}")
    }

    func test_css_minify_preservesDescendantCombinator() throws {
        let input = "a b { color: red; }"
        XCTAssertEqual(try CodeFormatter.CSS.minify(input),
                       "a b{color:red}")
    }

    func test_css_minify_dropsComments() throws {
        let input = ".x { /* hi */ color: red; }"
        XCTAssertEqual(try CodeFormatter.CSS.minify(input),
                       ".x{color:red}")
    }

    func test_css_throwsOnUnterminatedComment() {
        XCTAssertThrowsError(try CodeFormatter.CSS.pretty(".x { /* nope"))
    }

    // MARK: - SQL

    func test_sql_pretty_basicSelect() throws {
        let input = "select * from t where x = 1"
        let expected = """
        SELECT *
        FROM t
        WHERE x = 1
        """
        XCTAssertEqual(try CodeFormatter.SQL.pretty(input), expected)
    }

    func test_sql_pretty_joinAndOrder() throws {
        let input = "select a.id from a inner join b on a.id = b.id order by a.id"
        let expected = """
        SELECT a.id
        FROM a
        INNER JOIN b
        ON a.id = b.id
        ORDER BY a.id
        """
        XCTAssertEqual(try CodeFormatter.SQL.pretty(input), expected)
    }

    func test_sql_pretty_unionAllStaysIntact() throws {
        let input = "select 1 union all select 2"
        let expected = """
        SELECT 1
        UNION ALL
        SELECT 2
        """
        XCTAssertEqual(try CodeFormatter.SQL.pretty(input), expected)
    }

    func test_sql_pretty_keywordsInsideStringsUntouched() throws {
        let input = "select 'select me' from t"
        let expected = """
        SELECT 'select me'
        FROM t
        """
        XCTAssertEqual(try CodeFormatter.SQL.pretty(input), expected)
    }

    func test_sql_pretty_dropsLineComment() throws {
        let input = "select * from t -- comment\nwhere x=1"
        let expected = """
        SELECT *
        FROM t
        WHERE x=1
        """
        XCTAssertEqual(try CodeFormatter.SQL.pretty(input), expected)
    }

    func test_sql_minify_collapsesWhitespace() throws {
        let input = """
        SELECT *
        FROM t
        WHERE x = 1
        """
        XCTAssertEqual(try CodeFormatter.SQL.minify(input),
                       "SELECT * FROM t WHERE x = 1")
    }

    func test_sql_minify_dropsBlockComment() throws {
        let input = "select /* note */ * from t"
        XCTAssertEqual(try CodeFormatter.SQL.minify(input),
                       "select * from t")
    }
}
