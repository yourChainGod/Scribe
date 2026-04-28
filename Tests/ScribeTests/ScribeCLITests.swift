//
//  ScribeCLITests.swift
//  Phase 35a — exercise the `Scripts/scribe` wrapper's argument-
//  parser surface without actually invoking `open`. Every test
//  below either takes the early-exit path (--help / --version) or
//  trips the parser's validation (bad --line / missing --diff
//  paths / unknown option) before the script reaches the dispatch
//  block.
//
//  Why test the shell script from xctest:
//    The wrapper is the contract surface most users touch first;
//    a regression in flag parsing surfaces as a confusing "scribe
//    silently did nothing" report. By gating it through CI we
//    catch typos and quoting-rule changes immediately.
//
//  Out of scope:
//    - The `open -W -n` dispatch path (would require a running
//      Scribe.app; CI is headless).
//    - Path resolution against $PWD (covered by the `-l` flag's
//      env propagation; verifying actual file open would again
//      need a running app).
//

import XCTest

final class ScribeCLITests: XCTestCase {

    /// Resolves the wrapper relative to the test bundle's working
    /// directory. SwiftPM runs `swift test` with cwd at the package
    /// root, so a literal `Scripts/scribe` path is reachable.
    /// We assert the script exists rather than failing late inside
    /// `Process.run()` for a clearer diagnostic.
    private static var wrapperURL: URL {
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent("Scripts/scribe")
    }

    override func setUp() {
        super.setUp()
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: Self.wrapperURL.path),
            "Scripts/scribe must be executable — run `chmod +x Scripts/scribe`."
        )
    }

    // MARK: - Early-exit paths (no `open` invoked)

    func test_version_printsBundleVersionAndExitsZero() throws {
        let result = try runWrapper(args: ["--version"])
        XCTAssertEqual(result.exitCode, 0)
        // We don't pin the exact version string — phase 35b might
        // bump it. The "scribe " prefix is the contract.
        XCTAssertTrue(
            result.stdout.hasPrefix("scribe "),
            "Expected 'scribe <version>', got: \(result.stdout)"
        )
    }

    func test_help_includesUsageAndCoreFlags() throws {
        let result = try runWrapper(args: ["--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("USAGE"))
        // Each documented flag should be present so a missing flag
        // can't ship without its help line going with it.
        for flag in ["-h", "-v", "-w", "-n", "-l", "-d", "--wait",
                     "--new", "--line", "--diff", "--help", "--version"] {
            XCTAssertTrue(
                result.stdout.contains(flag),
                "--help missing documentation for \(flag)"
            )
        }
    }

    func test_shortHelpAlias_h_alsoShowsUsage() throws {
        let result = try runWrapper(args: ["-h"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("USAGE"))
    }

    // MARK: - Validation failures

    func test_lineFlag_requiresArgument() throws {
        let result = try runWrapper(args: ["--line"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("--line"))
    }

    func test_lineFlag_rejectsNonNumeric() throws {
        let result = try runWrapper(args: ["--line", "abc", "README.md"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("positive integer"))
    }

    func test_lineFlag_rejectsZero() throws {
        // Phase 35a contract: line numbers are 1-based; 0 is a
        // common off-by-one and rejecting it surfaces the bug
        // immediately instead of silently failing inside Scribe.
        let result = try runWrapper(args: ["-l", "0", "README.md"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func test_lineFlag_rejectsNegative() throws {
        let result = try runWrapper(args: ["-l", "-5", "README.md"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func test_diffFlag_requiresTwoArguments() throws {
        let result = try runWrapper(args: ["--diff", "only-one.txt"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("--diff"))
    }

    func test_unknownFlag_failsWithHint() throws {
        let result = try runWrapper(args: ["--no-such-flag"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("unknown option"))
        XCTAssertTrue(result.stderr.contains("--help"))
    }

    // MARK: - Helpers

    private struct WrapperResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Run the wrapper and capture stdout / stderr. We deliberately
    /// don't pipe a TTY — the wrapper doesn't depend on one for
    /// any of the early-exit paths under test.
    private func runWrapper(args: [String]) throws -> WrapperResult {
        let process = Process()
        process.executableURL = Self.wrapperURL
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return WrapperResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
