// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [
        .macOS(.v13)
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
        .executableTarget(
            name: "Scribe",
            dependencies: ["Scintilla"],
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
