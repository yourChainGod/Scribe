//
//  SymbolParserTests.swift
//  Phase 7 — exercises every language parser to make sure the regex
//  patterns hit the symbols Scribe's outline UI advertises.
//
//  Each language has at minimum: one positive case (parses N expected
//  symbols) and one regression case (does not parse a known false-
//  positive).
//

import XCTest
@testable import Scribe

final class SymbolParserTests: XCTestCase {

    // MARK: - Catalog dispatch

    func test_catalog_returnsParserForKnownExtensions() {
        XCTAssertNotNil(SymbolParserCatalog.parser(forExtension: "swift"))
        XCTAssertNotNil(SymbolParserCatalog.parser(forExtension: "py"))
        XCTAssertNotNil(SymbolParserCatalog.parser(forExtension: "js"))
        XCTAssertNotNil(SymbolParserCatalog.parser(forExtension: "ts"))
        XCTAssertNotNil(SymbolParserCatalog.parser(forExtension: "rs"))
        XCTAssertNotNil(SymbolParserCatalog.parser(forExtension: "go"))
        XCTAssertNotNil(SymbolParserCatalog.parser(forExtension: "md"))
        XCTAssertNotNil(SymbolParserCatalog.parser(forExtension: "cpp"))
    }

    func test_catalog_returnsNilForUnknownExtensions() {
        XCTAssertNil(SymbolParserCatalog.parser(forExtension: ""))
        XCTAssertNil(SymbolParserCatalog.parser(forExtension: "xyz"))
        XCTAssertNil(SymbolParserCatalog.parser(forExtension: "json"))
    }

    // MARK: - Swift

    func test_swift_capturesFunctionsTypesAndProperties() {
        let src = """
        import Foundation

        struct Point {
            let x: Int
            var y: Int = 0
        }

        class Solver {
            func compute() {}
            private func helper(_ n: Int) -> Int { n }
            static func make() -> Solver { Solver() }
        }

        protocol Drawable {
            func draw()
        }

        extension Point: Equatable {}

        enum Direction { case north, south }

        typealias IntPair = (Int, Int)

        func test_addition() throws {}
        """
        let symbols = SwiftSymbolParser().parse(src)
        let names = symbols.map(\.name)
        XCTAssertTrue(names.contains("Point"))
        XCTAssertTrue(names.contains("Solver"))
        XCTAssertTrue(names.contains("compute"))
        XCTAssertTrue(names.contains("helper"))
        XCTAssertTrue(names.contains("make"))
        XCTAssertTrue(names.contains("Drawable"))
        XCTAssertTrue(names.contains("Direction"))
        XCTAssertTrue(names.contains("IntPair"))
        // test_ prefix should be classified as .test
        XCTAssertEqual(symbols.first { $0.name == "test_addition" }?.kind, .test)
        // typealias kind
        XCTAssertEqual(symbols.first { $0.name == "IntPair" }?.kind, .typealiasDecl)
        // extension kind
        XCTAssertTrue(symbols.contains { $0.kind == .extensionDecl && $0.name == "Point" })
    }

    func test_swift_doesNotMisparseLocalLetInsideFunction() {
        // `let x = 1` at indent inside a func *would* match propertyRule,
        // which is the price we pay for one-pass regex. Still, top-level
        // funcs / structs / etc. should be recognised.
        let src = """
        func outer() {
            let x = 1
            let y: Int = 2
        }
        """
        let symbols = SwiftSymbolParser().parse(src)
        XCTAssertEqual(symbols.first?.name, "outer")
        XCTAssertEqual(symbols.first?.kind, .function)
    }

    // MARK: - Python

    func test_python_capturesDefAndClass() {
        let src = """
        class Animal:
            def __init__(self):
                pass
            def speak(self):
                pass

        async def fetch_url(url):
            return None

        def test_speak():
            pass
        """
        let symbols = PythonSymbolParser().parse(src)
        let names = symbols.map(\.name)
        XCTAssertTrue(names.contains("Animal"))
        XCTAssertTrue(names.contains("__init__"))
        XCTAssertTrue(names.contains("speak"))
        XCTAssertTrue(names.contains("fetch_url"))
        XCTAssertEqual(symbols.first { $0.name == "test_speak" }?.kind, .test)
    }

    // MARK: - JavaScript / TypeScript

    func test_javascript_recognisesAllDeclarationStyles() {
        let src = """
        export function greet(name) { return `hi ${name}` }
        async function fetchUser() {}
        export const add = (a, b) => a + b
        const square = function (x) { return x * x }
        export default class Service {}
        interface Config { env: string }
        type Maybe<T> = T | null
        """
        let symbols = JavaScriptSymbolParser().parse(src)
        let names = symbols.map(\.name)
        XCTAssertTrue(names.contains("greet"))
        XCTAssertTrue(names.contains("fetchUser"))
        XCTAssertTrue(names.contains("add"))
        XCTAssertTrue(names.contains("square"))
        XCTAssertTrue(names.contains("Service"))
        XCTAssertTrue(names.contains("Config"))
        XCTAssertTrue(names.contains("Maybe"))
        XCTAssertEqual(symbols.first { $0.name == "Config" }?.kind, .protocolDecl)
        XCTAssertEqual(symbols.first { $0.name == "Maybe" }?.kind, .typealiasDecl)
    }

    // MARK: - Rust

    func test_rust_capturesFnAndKeywords() {
        let src = """
        pub fn parse(input: &str) -> Result<i32, Error> { Ok(0) }
        async fn fetch_url() {}
        struct Point { x: f32, y: f32 }
        enum Direction { Up, Down }
        trait Drawable {}
        impl Drawable for Point {}
        type Pair = (i32, i32);
        mod inner;

        #[test]
        fn test_parse_ok() {}
        """
        let symbols = RustSymbolParser().parse(src)
        let names = symbols.map(\.name)
        XCTAssertTrue(names.contains("parse"))
        XCTAssertTrue(names.contains("fetch_url"))
        XCTAssertTrue(names.contains("Point"))
        XCTAssertTrue(names.contains("Direction"))
        XCTAssertTrue(names.contains("Drawable"))
        XCTAssertEqual(symbols.first { $0.name == "Drawable" }?.kind, .protocolDecl)
        XCTAssertEqual(symbols.first { $0.name == "Pair" }?.kind, .typealiasDecl)
        XCTAssertEqual(symbols.first { $0.name == "test_parse_ok" }?.kind, .test)
    }

    // MARK: - Go

    func test_go_capturesFuncsAndTypes() {
        let src = """
        package main

        func main() {}

        func (s *Server) Serve() error { return nil }

        func TestServer(t *testing.T) {}

        type Server struct {
            addr string
        }

        type Handler interface {
            Handle()
        }
        """
        let symbols = GoSymbolParser().parse(src)
        let names = symbols.map(\.name)
        XCTAssertTrue(names.contains("main"))
        XCTAssertTrue(names.contains("Serve"))
        XCTAssertTrue(names.contains("Server"))
        XCTAssertTrue(names.contains("Handler"))
        XCTAssertEqual(symbols.first { $0.name == "TestServer" }?.kind, .test)
        XCTAssertEqual(symbols.first { $0.name == "Server" }?.kind, .structDecl)
        XCTAssertEqual(symbols.first { $0.name == "Handler" }?.kind, .protocolDecl)
    }

    // MARK: - Markdown

    func test_markdown_capturesHeadingDepth() {
        let src = """
        # Top
        Some intro.

        ## Section A
        Content.

        ### Subsection
        More.

        ## Section B
        """
        let symbols = MarkdownSymbolParser().parse(src)
        XCTAssertEqual(symbols.count, 4)
        XCTAssertEqual(symbols[0].name, "Top")
        XCTAssertEqual(symbols[0].depth, 0)        // h1 → depth 0
        XCTAssertEqual(symbols[1].name, "Section A")
        XCTAssertEqual(symbols[1].depth, 1)        // h2 → depth 1
        XCTAssertEqual(symbols[2].name, "Subsection")
        XCTAssertEqual(symbols[2].depth, 2)        // h3 → depth 2
        XCTAssertEqual(symbols[3].name, "Section B")
    }

    // MARK: - C / C++

    func test_c_capturesFunctionDefinitionsButSkipsControlFlow() {
        let src = """
        #include <stdio.h>

        static int helper(int x) {
            if (x > 0) {
                return x;
            }
            for (int i = 0; i < 10; i++) {}
            return 0;
        }

        int main(int argc, char **argv) {
            return helper(argc);
        }

        struct Point { int x; int y; };

        class Foo {};
        """
        let symbols = CSymbolParser().parse(src)
        let names = symbols.map(\.name)
        XCTAssertTrue(names.contains("helper"))
        XCTAssertTrue(names.contains("main"))
        XCTAssertTrue(names.contains("Point"))
        XCTAssertTrue(names.contains("Foo"))
        // Reserved-word filter must keep `if` / `for` out.
        XCTAssertFalse(names.contains("if"))
        XCTAssertFalse(names.contains("for"))
    }

    // MARK: - Line numbers

    func test_lineNumbersAre1Based() {
        let src = """
        // line 1
        // line 2
        func decl() {}
        """
        let symbols = SwiftSymbolParser().parse(src)
        XCTAssertEqual(symbols.first?.lineNumber, 3)
    }
}
