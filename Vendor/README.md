# Vendored dependencies

## Lexilla 5.4.4

**Source**: https://www.scintilla.org/lexilla544.tgz (1.0 MB, 2025-04-01)
**License**: HPND, GPL-compatible
**Why vendored**: Phase 1.8 syntax highlighting. Companion to Scintilla
5.x — Scintilla 5 stripped all lexers out into Lexilla, so we have to
ship both.

### What we changed

Three files **added** by Scribe (do not exist upstream):

| File | Purpose |
|------|---------|
| `lexilla/include/module.modulemap` | Defines the Swift module `Lexilla`. |
| `lexilla/include/ScribeLexillaUmbrella.h` | Umbrella header that *only* surfaces the Swift-friendly ObjC façade — Lexilla's own headers use C++ namespaces and `Scintilla::ILexer5`, which Swift can't import. |
| `lexilla/include/LexillaBridge.h` | ObjC declarations (`LexillaBridgeCreateLexer`, `LexillaBridgeLexerCount`, `LexillaBridgeLexerNames`) wrapped in `extern "C"` so name-mangling doesn't break the Swift link. |
| `lexilla/swiftpm-bridge/LexillaBridge.mm` | ObjC++ implementation. Calls Lexilla's `CreateLexer/GetLexerCount/GetLexerName` and casts `ILexer5*` to `void*` for transit through Swift. |

### How to upgrade

1. Download the new tarball and replace the directory:
   ```bash
   curl -L https://www.scintilla.org/lexilla<NEW>.tgz -o /tmp/lex.tgz
   rm -rf Vendor/lexilla
   tar -xzf /tmp/lex.tgz -C Vendor/
   ```
2. Restore the four Scribe-owned files:
   ```bash
   git checkout HEAD -- \
       Vendor/lexilla/include/module.modulemap \
       Vendor/lexilla/include/ScribeLexillaUmbrella.h \
       Vendor/lexilla/include/LexillaBridge.h \
       Vendor/lexilla/swiftpm-bridge/LexillaBridge.mm
   ```
3. `swift build` and verify `swift test` is still 17/17.
4. Update the version line above.

### What's NOT vendored

`.gitignore` strips `doc/`, `test/`, `examples/`, `scripts/`, `access/`
(dynamic-loader, irrelevant to a static link). Re-extracting the tarball
brings them back on disk; SwiftPM ignores them via the target's
`exclude:` list anyway.

---

## Scintilla 5.6.1

**Source**: https://www.scintilla.org/scintilla561.tgz (1.7 MB, 2025-03-25)
**License**: HPND (https://opensource.org/licenses/HPND), GPL-compatible
**Why vendored**: Phase 1 editor kernel. See ROADMAP ADR-003.

### What we changed

Two files **added** by Scribe (do not exist upstream):

| File | Purpose |
|------|---------|
| `scintilla/include/module.modulemap` | Defines the Swift module `Scintilla`. SwiftPM exposes Scintilla as a static-library target, not a framework, so the upstream `framework module` declaration in `cocoa/Scintilla/module.modulemap` does not apply. |
| `scintilla/include/ScribeScintillaUmbrella.h` | Umbrella header that pulls in `cocoa/ScintillaView.h` + `cocoa/InfoBar.h`. Lives in `include/` so that ScintillaView.h's same-directory `#import "Scintilla.h"` resolves automatically without us needing to inject extra header search paths into the clang module-build phase. |

The upstream `cocoa/Scintilla/module.modulemap` is **untouched**; SwiftPM
ignores it via `exclude` in `Package.swift`.

### How to upgrade

1. Download the new tarball:
   ```bash
   curl -L https://www.scintilla.org/scintilla<NEW>.tgz -o /tmp/sci.tgz
   ```
2. Replace the directory wholesale:
   ```bash
   rm -rf Vendor/scintilla
   tar -xzf /tmp/sci.tgz -C Vendor/
   ```
3. Re-add the two Scribe-owned files:
   ```bash
   git checkout HEAD -- Vendor/scintilla/include/module.modulemap
   git checkout HEAD -- Vendor/scintilla/include/ScribeScintillaUmbrella.h
   ```
4. `swift build` and verify both Scribe and ScribeTests still pass.
5. Update the version line at the top of this file.

### What's NOT vendored

The following Scintilla subdirectories are excluded from git via
`.gitignore` (irrelevant to a macOS-only target):

- `doc/`, `test/`, `win32/`, `gtk/`, `qt/`, `scripts/`

If you re-extract the tarball you'll get them back on disk; SwiftPM
ignores them via the target's `exclude:` list anyway.
