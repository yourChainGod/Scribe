# Scribe TODO

> Updated: 2026-04-29

## Phase 36e Follow-Up Checks

- [x] Command Palette no longer uses floating window level.
- [x] Command Palette has compact metrics and a visible close affordance.
- [x] Command Palette close affordance is localized in English and Simplified Chinese.
- [x] External disk-change confirmation is modeled in Workspace state instead of `NSAlert.runModal()`.
- [x] External disk-change confirmation can reload decoded disk content.
- [x] External disk-change confirmation can keep the dirty local buffer unchanged.
- [x] Sidebar visibility sync no longer wraps `NavigationSplitView` mutations in an extra explicit animation.
- [x] Save glyph uses document-save semantics instead of download tray semantics.
- [x] Inline Blame calltip is cancelled when the app deactivates or the editor window resigns key.
- [x] Inline Blame calltip is suppressed while Text Tools is presented, including screenshot-hook openings.
- [x] Inline Blame details no longer use Scintilla native calltips; details render as an in-editor child view and cannot float over other apps.
- [x] Main toolbar actions now live in the editor detail chrome so they follow sidebar expand/collapse instead of floating in the titlebar.
- [x] Sidebar mode switcher uses a single quiet active state instead of stacked indicators.
- [x] App icon SVG is visually inset and can render every iconset size.
- [ ] Smoke-test the release `.app` visually after it is safe to rebuild `build/Scribe.app`.
- [ ] In Chinese locale, open Command Palette and Quick Open and confirm no English category/status text leaks.
- [ ] Trigger an external dirty-file change in the real app and confirm the sheet attaches to the window.
- [x] Hover Inline Blame no longer creates a native floating Scintilla calltip window.
- [x] Toggle the sidebar repeatedly in `/tmp/ScribeSmoke.app` and confirm the command bar follows the editor pane.

## Phase 37 Text Operations Workbench

- [x] Add a pure `TextTableSplitter` model for delimiter, regex, TSV/CSV, and fixed-width splitting.
- [x] Add unit tests for quoted CSV cells, escaped quotes, empty trailing columns, CRLF input, and mixed-width rows.
- [x] Add a `ColumnPlan` model with selected columns, output order, display titles, and join delimiter.
- [x] Add drag-reorder support for columns in the plan model before building the UI.
- [x] Add preview sampling for large text so the UI can show the first N rows without materializing huge previews.
- [x] Add output modes: replace selection, replace whole document, create new tab, and copy to clipboard.
- [x] Build a Text Tools sheet with segmented modes: Split, Merge, Shuffle, Transform.
- [x] Split mode: current selection/full document/imported file source picker.
- [x] Split mode: delimiter presets for comma, tab, whitespace, pipe, custom string, regex, fixed width.
- [x] Split mode: table preview with row numbers, column headers, checkboxes, and drag handles.
- [x] Merge mode: add prefix, suffix, and configurable missing-cell placeholder.
- [x] Merge mode: selected-column join with custom delimiter.
- [x] Merge mode: import a second text source and align by row index with row-count mismatch badge.
- [x] Merge mode: support importing multiple text files as row-aligned sources.
- [x] Merge mode: add key-column join after the simpler row-index merge is stable.
- [x] Shuffle mode: selected lines or full document.
- [x] Shuffle mode: optional deterministic seed for reproducible randomization.
- [x] Shuffle mode: options to preserve first line, preserve blank-line positions, and trim final newline safely.
- [x] Transform mode: selected text to base 2/8/10/16 conversion.
- [x] Transform mode: URL encode/decode.
- [x] Transform mode: Base64 encode/decode.
- [x] Transform mode: HTML escape/unescape.
- [x] Transform mode: JSON string escape/unescape.
- [x] Transform mode: AES-GCM encrypt/decrypt with CryptoKit and a password sheet.
- [x] Transform mode: never persist passwords, salts, or derived keys.
- [x] Transform mode: on failure, show a non-destructive error and leave the buffer untouched.
- [x] Add right-click `Transform` submenu with the safest immediate transforms.
- [x] Add Command Palette entries for the Text Tools workbench and common one-shot transforms.
- [x] Localize every Text Tools label, tooltip, empty state, and error.
- [x] Add accessibility labels for column checkboxes and column movement controls.
- [x] Add focused model tests before UI implementation.
- [x] Add command registration tests for discoverability and English mnemonic search under Chinese UI.
- [x] Add screenshot/smoke hooks for opening the current Text Tools Columns and Shuffle modes.
- [x] Extend screenshot/smoke hooks to the Transform workbench mode.
- [x] Run full gates after each phase: `swift test`, Swift 6 build, release build, localization check, `git diff --check`.

## Scintilla bridge stability

- [x] **[crash, fixed in Phase 47]** `-[ScintillaView applicationDidBecomeActive:]` dereferenced a freed delegate when `NSApplication` re-activated while an `NSOpenPanel` modal loop was winding down. Root cause: `Vendor/scintilla/cocoa/ScintillaView.h` declares `delegate` as `unsafe_unretained` (raw pointer that does not nil out on deallocation). Fix: `ScintillaCodeEditor.dismantleNSView(_:coordinator:)` and `DiffEditorPane.dismantleNSView(_:coordinator:)` now set `view.delegate = nil` so SwiftUI's dismantle path unhooks the pointer before the Coordinator is released. Vendor untouched.

## Visual QA Queue

- [ ] Rebuild `.app` only when no old `build/Scribe.app` session has unsaved state.
- [ ] Launch release `.app` in Chinese locale.
- [ ] Capture main window, Command Palette, Quick Open, external-change sheet, Source Control sidebar, and Markdown preview.
- [ ] Check text clipping at narrow sidebar width and default window size.
- [ ] Check toolbar icon scale against macOS system controls.
- [ ] Check sidebars under light and dark appearance.
- [ ] Check Dock icon at 16, 32, 128, and 512 px.
