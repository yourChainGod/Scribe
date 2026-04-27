// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [
        .macOS(.v14)   // bumped from v13 in Phase 3 for SwiftUI onKeyPress + onChange(of:_:_)
    ],
    products: [
        .executable(name: "Scribe", targets: ["Scribe"])
    ],
    targets: [
        // Scintilla 5.6.1 vendored under Vendor/scintilla.
        //
        // We ship two added files (not part of upstream):
        //   include/module.modulemap            (defines Swift module 'Scintilla')
        //   include/ScribeScintillaUmbrella.h   (umbrella header)
        //
        // The original framework-style modulemap at cocoa/Scintilla/module.modulemap
        // is left untouched; SwiftPM is told to use ours via publicHeadersPath.
        //
        // Why this layout: ScintillaView.h imports "Scintilla.h" with a
        // same-directory lookup, so the umbrella header has to live where
        // Scintilla.h does — namely include/.
        .target(
            name: "Scintilla",
            path: "Vendor/scintilla",
            exclude: [
                // Top-level non-source content
                "bin", "doc", "gtk", "qt", "test", "win32", "scripts",
                "call",                       // ScintillaCall.cxx — C++ only API
                "delbin.bat", "tgzsrc", "zipsrc.bat",
                "License.txt", "README", "CONTRIBUTING",
                "cppcheck.suppress", "version.txt",
                // Files inside cocoa/ that aren't part of the library proper
                "cocoa/checkbuildosx.sh",
                "cocoa/ScintillaTest",        // demo app
                "cocoa/res",                  // images for demo
                "cocoa/Scintilla",            // upstream framework modulemap; unused by SwiftPM
                // Stray non-source files inside src/
                "src/SciTE.properties",
                "src/PositionCache.cxx.orig",
                // Scintilla.iface is an IDL description, not a header
                "include/Scintilla.iface"
            ],
            sources: ["src", "cocoa"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("cocoa")
            ],
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("cocoa")
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("QuartzCore")
            ]
        ),
        // Lexilla 5.4.4 vendored under Vendor/lexilla. Provides 100+ syntax
        // lexers; we compile all of them so CreateLexer("…") finds whatever
        // we ask for at runtime. Lexilla depends on Scintilla's ILexer.h
        // header but does not link against the Scintilla target — it just
        // implements the interface, the lexer pointer is passed back into
        // ScintillaView via SCI_SETILEXER.
        .target(
            name: "Lexilla",
            path: "Vendor/lexilla",
            exclude: [
                "bin", "doc", "test", "examples", "scripts",
                "access",                       // dynamic-loader, we link statically
                "CONTRIBUTING", "License.txt", "README", "version.txt",
                "delbin.bat", "tgzsrc", "zipsrc.bat",
                "cppcheck.suppress",
                "include/LexicalStyles.iface",
                // Build infra files inside src/
                "src/DepGen.py",
                "src/Lexilla",                  // src/Lexilla/Lexilla.xcodeproj + Info.plist
                "src/Lexilla.def",
                "src/Lexilla.pro",
                "src/Lexilla.vcxproj",
                "src/Lexilla.ruleset",
                "src/LexillaVersion.rc",
                "src/lexilla.mak",
                "src/deps.mak",
                "src/nmdeps.mak",
                "src/makefile"
            ],
            sources: ["src", "lexlib", "lexers", "swiftpm-bridge"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("lexlib"),
                .headerSearchPath("../scintilla/include")
            ]
        ),
        .executableTarget(
            name: "Scribe",
            dependencies: ["Scintilla", "Lexilla"],
            path: "Sources/Scribe"
        ),
        .testTarget(
            name: "ScribeTests",
            dependencies: ["Scribe"],
            path: "Tests/ScribeTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
