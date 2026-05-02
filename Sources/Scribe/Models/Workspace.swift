//
//  Workspace.swift
//  Top-level state: documents, tabs, current selection.
//

import Foundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Which mode the side panel is in. Mirrors the VSCode primary side
/// bar tabs: project tree, search results, symbol outline, source
/// control.
enum SidebarMode: String {
    case files
    case search
    case outline
    /// Phase 35b-1 — Source Control panel listing every changed
    /// file in the workspace's git repo. Read-only in v1; stage /
    /// unstage / commit affordances land in 35b-2.
    case sourceControl
}

struct ExternalChangePrompt: Identifiable {
    var id: UUID { documentID }
    let documentID: UUID
    let title: String
    let decoded: DetectedTextFormat
}

@MainActor
final class Workspace: ObservableObject {
    @Published var documents: [Document] = []
    @Published var selectedID: UUID?
    @Published var sidebarVisible: Bool = true
    @Published var sidebarMode: SidebarMode = .files
    @Published var folderRoot: FileNode?
    @Published var externalChangePrompt: ExternalChangePrompt?

    /// Non-nil ⇒ MainWindow renders the Compare-Files screen instead of
    /// the editor. ScribeApp keeps a single DiffSession for the app
    /// lifetime; toggling here just shows / hides the screen.
    @Published var compareSession: DiffSession?

    /// Phase 35b-4-b — `true` ⇒ EditorAreaView renders the Project
    /// Diff multibuffer overlay instead of the per-document editor.
    /// Per-window state (not per-Document) because the multibuffer
    /// is a workspace-wide view, not a tab; toggled from the Source
    /// Control sidebar header. We deliberately don't model it as a
    /// new tab kind — Documents carry too much file-specific state
    /// (encoding, lineEnding, isDirty, gitGutter…) for a virtual
    /// "Project Diff" entry to slot in cleanly. An overlay keeps the
    /// tab strip and sidebar live behind it so the user can still
    /// see status updates as they stage/unstage from inside the
    /// multibuffer.
    @Published var projectDiffVisible: Bool = false

    /// Phase 37 → Phase 40 — visible while the column-merger
    /// workbench sheet is attached to the main editor window. The
    /// Phase 38 multi-mode picker (columns / shuffle / transform)
    /// was retired in Phase 40; line shuffle and base/encoding
    /// transforms now live exclusively in the editor's right-click
    /// ▸ Transform submenu (see TextTransformCommandButtons).
    @Published var isTextToolsPresented: Bool = false

    /// Phase 41a — non-nil ⇒ the JWT decoder sheet is presented,
    /// pre-filled with the carried text. Bound through MainWindow
    /// via `.sheet(item:)`. Cleared by the sheet's Close action.
    @Published var jwtSheet: JWTSheetRequest?
    /// Phase 41b — Password / QR generator sheets. Both follow the
    /// same `Identifiable` payload pattern as `jwtSheet` so SwiftUI
    /// `.sheet(item:)` can swap presentations cleanly.
    @Published var passwordSheet: PasswordSheetRequest?
    @Published var qrSheet: QRSheetRequest?
    /// Phase 41e — Regex Playground sheet. Carries the active
    /// selection as the prefill subject so the user can poke at
    /// whatever they had highlighted without an extra paste.
    @Published var regexSheet: RegexSheetRequest?
    /// Phase 44 — Hex viewer sheet. Captures the document content
    /// at open time so mid-frame edits can't tear the dump.
    @Published var hexViewerSheet: HexViewerRequest?

    /// Phase 35b-4-d — repo-relative path the multibuffer should
    /// scroll into view on its next render. Used by the sidebar's
    /// "Open in Project Diff" affordance: clicking on a file row
    /// opens the multibuffer *and* anchors it to that file so the
    /// user lands on the right hunks instead of the top of the
    /// list. ProjectDiffView watches this via `.onChange` and
    /// resets to `nil` after the scroll completes so a later
    /// re-trigger of the same path still fires.
    @Published var projectDiffFocusPath: String? = nil

    /// Phase 46c — FIFO stack of URLs that were just closed. The
    /// top of the stack (`.last`) is what `reopenLastClosed()`
    /// reopens next, matching Chrome/VSCode's ⌘⇧T behavior: each
    /// press pops one tab in reverse-close order. Untitled docs
    /// never enter the stack (no URL means nothing meaningful to
    /// restore). Capped at `recentlyClosedCap` so a marathon session
    /// closing hundreds of files doesn't grow the array unbounded.
    /// In-memory only — a crash / relaunch wipes the history; the
    /// Open Recent menu is the cross-session recovery path.
    @Published private(set) var recentlyClosedURLs: [URL] = []

    /// Phase 46c — cap for `recentlyClosedURLs`. Ten matches Chrome's
    /// per-window undo limit; anything more than that and the user
    /// should reach for Open Recent (which persists and has a
    /// bigger catalog).
    static let recentlyClosedCap: Int = 10

    /// Phase 48c — index of the last pinned tab in `documents`, or
    /// `nil` if nothing is pinned (or the document list is empty).
    /// `TabBarView` reads this to know where to drop its pin/unpin
    /// hairline separator; pulling the computation into the model
    /// keeps the boundary rule in one place and makes it testable
    /// without spinning up a headless NSView harness.
    ///
    /// Precondition: `resortByPin()` is the gatekeeper that keeps
    /// pinned docs clustered at the head of the array, so
    /// "last pinned" is equivalent to "boundary between pinned and
    /// unpinned". If that invariant is ever violated the separator
    /// still renders correctly next to the trailing pinned tab; it
    /// just won't capture every pinned row.
    var pinBoundaryIndex: Int? {
        documents.lastIndex(where: { $0.isPinned })
    }

    /// Phase 35b-4-d — open the Project Diff multibuffer, optionally
    /// anchored to a specific repo-relative path. Centralised so
    /// future entry points (command palette, menu bar, keyboard
    /// shortcut…) all go through the same code path and can't
    /// drift on the visibility / focus order.
    func openProjectDiff(focusPath: String? = nil) {
        projectDiffFocusPath = focusPath
        projectDiffVisible = true
    }

    /// Phase 18 — last-known selection text from the focused editor.
    /// Non-published on purpose: SCN_UPDATEUI fires on every cursor
    /// move, so a @Published bind would thrash every observer
    /// (sidebar, status bar, command palette host…) at typing speed.
    /// "Find in Files" reads this on demand at command-invoke time.
    /// Empty string ⇒ caret only (no actual text selection).
    var activeSelection: String = ""

    /// Phase 37 — full active selection text for Text Tools. Unlike
    /// `activeSelection`, this intentionally preserves newlines so a
    /// selected block can be split, merged, shuffled, and replaced as a
    /// real text payload instead of a single-line find query.
    var activeTextSelection: String = ""

    let prefs: EditorPreferences

    /// One file-system watcher per open document with a URL. Removed when
    /// the document closes or its URL changes. Keyed by Document.id so we
    /// can prune by identity even if the underlying URL is reassigned.
    private var watchers: [UUID: FileWatcher] = [:]

    /// Phase 31 — single shared engine that runs `git diff` for the
    /// currently-active document and writes the per-line status into
    /// `doc.gitGutter`. We keep one instance per workspace so a save
    /// burst doesn't pile up parallel `git diff` invocations across
    /// every open tab; only the visible doc has its gutter live, the
    /// rest catch up on next bind / save.
    let gitGutterEngine = GitGutterEngine()

    /// Phase 35b-1 — single shared engine that runs `git status` for
    /// the workspace's bound folder root. Drives the Source Control
    /// sidebar; refreshed on save / external file change / folder
    /// open + close, never on a timer (file system events already
    /// cover every mutation we care about).
    let gitStatusEngine = GitStatusEngine()

    /// Phase 35c-ii-β — single shared engine that runs `git blame
    /// --porcelain` for the active document, keyed by absolute
    /// URL. Inline-blame UI reads from this on every caret tick;
    /// the engine itself only re-fetches on open / save / external
    /// change so a moving caret on an unchanged file is free.
    let gitBlameEngine = GitBlameEngine()

    /// Phase 43-T — non-blocking notification queue. Replaces every
    /// `NSAlert(error:).runModal()` callsite that surfaced a pure
    /// notice (file load failed, save failed, regex compile failed,
    /// git engine failed). True user-choice prompts (close-with-
    /// unsaved, reopen-with-encoding, revert-hunk, discard-changes)
    /// stay on NSAlert/NSSheet — those need a button click, not a
    /// banner that auto-dismisses.
    let toastCenter = ToastCenter()

    /// Sink for `selectedID` changes — re-binds the gutter engine to
    /// the newly-selected doc whenever the user switches tabs. Held
    /// internally so the engine + sink share Workspace's lifetime.
    private var selectionSink: AnyCancellable?

    init(prefs: EditorPreferences, openInitialUntitled: Bool = true) {
        self.prefs = prefs
        // Open one empty doc by default so the editor isn't blank on first run.
        // Caller can suppress when it intends to seed `documents` itself
        // (e.g. command-line file arguments).
        if openInitialUntitled {
            newDocument()
        }
        // Keep the gutter engine pointed at whatever's selected. Both
        // the initial newDocument() above and any later tab switch
        // funnel through `selectedID`, so this single sink covers
        // every code path that changes the active doc.
        selectionSink = $selectedID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.gitGutterEngine.bind(to: self.current)
            }
        // Phase 43-T — route GitStatusEngine write-action errors
        // (stage/unstage/commit/pull/push/…) through the toast
        // queue instead of an NSAlert so the rest of the UI stays
        // interactive while the user reads the message.
        gitStatusEngine.onWriteFailure = { [weak self] titleKey, message in
            self?.toastCenter.error(L10n.t(titleKey), message: message)
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(at: url)
        }
    }

    /// Programmatic counterpart used by the Recent Folders menu.
    func openFolder(at url: URL) {
        let normalized = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        // Phase 35b-1 — bind the Source Control engine to whatever
        // `.git` ancestor this folder sits inside (or itself, if the
        // folder *is* a repo root). `findRepoRoot` returns nil for
        // a non-repo folder; the engine handles that as `.notInRepo`
        // and shows the empty state.
        gitStatusEngine.bind(repo: GitClient.findRepoRoot(for: normalized))
        // Phase 35c-ii-β — a folder switch invalidates every
        // cached blame entry. The new folder may reopen the same
        // path as a totally different file (e.g. two checkouts of
        // the same repo); leaving stale blame would mis-annotate
        // it for one caret tick before the re-fetch lands.
        gitBlameEngine.invalidateAll()
        let root = FileNode(url: normalized)
        root.isExpanded = true
        root.loadChildren()
        self.folderRoot = root
        prefs.addRecentFolder(normalized)
    }

    func closeFolder() {
        folderRoot = nil
        // Phase 35b-1 — clear the Source Control sidebar in lockstep
        // so it doesn't keep showing rows from the old repo.
        gitStatusEngine.bind(repo: nil)
        // Phase 35c-ii-β — same reasoning for inline blame.
        gitBlameEngine.invalidateAll()
    }

    var current: Document? {
        documents.first { $0.id == selectedID }
    }

    var canToggleMarkdownPreview: Bool {
        current?.isMarkdown == true
    }

    func toggleMarkdownPreview() {
        guard let doc = current, doc.isMarkdown else { return }
        objectWillChange.send()
        doc.isMarkdownPreviewVisible.toggle()
    }

    /// Phase 46b — flip a document's pin state and keep the on-disk
    /// pin roster (`prefs.pinnedFilePaths`) in sync. Pinned tabs
    /// float to the front of the strip; unpinning re-inserts after
    /// the last pinned entry so the user's manual ordering of
    /// unpinned tabs is preserved.
    ///
    /// Persistence contract: only documents with a URL make it into
    /// `prefs.pinnedFilePaths`. Untitled documents can still carry
    /// the flag for the session — useful if a user pins a scratch
    /// buffer mid-work — but the flag vanishes on close / restart.
    func togglePin(_ doc: Document) {
        objectWillChange.send()
        doc.isPinned.toggle()
        if let path = doc.url?.standardizedFileURL.path {
            if doc.isPinned {
                prefs.pinnedFilePaths.insert(path)
            } else {
                prefs.pinnedFilePaths.remove(path)
            }
        }
        resortByPin()
    }

    /// Phase 46b — group pinned documents at the head of the strip
    /// while preserving each group's internal ordering. Not a
    /// general-purpose sort: every other mutation (drag reorder,
    /// open / close) is expected to maintain the invariant on its
    /// own, and this helper is the recovery point whenever the
    /// invariant may have been broken (togglePin, openFile pin
    /// restoration). Stable by construction — same-group relative
    /// order comes straight from the input array.
    func resortByPin() {
        let pinned = documents.filter { $0.isPinned }
        let unpinned = documents.filter { !$0.isPinned }
        let merged = pinned + unpinned
        // Guard against spurious `@Published` ticks when the
        // pinned/unpinned split already matches `documents` order.
        let unchanged = merged.count == documents.count
            && zip(merged, documents).allSatisfy { $0 === $1 }
        if unchanged { return }
        documents = merged
    }

    /// Phase 46a — reorder tabs by moving a document to a new slot.
    /// Uses Foundation's `move(fromOffsets:toOffset:)` semantics where
    /// `destination` is the target position **in the pre-move array**,
    /// interpreted as "insert before this index". So for
    /// `[A, B, C, D]`, moving from 0 to 2 yields `[B, A, C, D]` and
    /// moving from 0 to 4 yields `[B, C, D, A]` (tail insertion uses
    /// `documents.count`, not `documents.count - 1`).
    ///
    /// `selectedID` stays stable (the active Document.id doesn't
    /// change) so a user mid-edit keeps focus even when another drop
    /// reshuffles the strip. Out-of-range source indices return early;
    /// destination is clamped to `[0, documents.count]` so drop
    /// handlers can pass tail + 1 or negative values without
    /// precondition fuss. A no-op move (destination translates to the
    /// same slot) skips the mutation entirely so `@Published`
    /// observers don't fire spuriously.
    func moveDocument(fromIndex source: Int, toIndex destination: Int) {
        guard documents.indices.contains(source) else { return }
        let clampedDest = max(0, min(destination, documents.count))
        // Move semantics: destination == source or source + 1 both mean
        // "same slot" (inserting-before-self or inserting-just-after-
        // self is a no-op after removal). Skip early so observers
        // don't tick on a phantom drag.
        if clampedDest == source || clampedDest == source + 1 { return }
        documents.move(fromOffsets: IndexSet(integer: source),
                       toOffset: clampedDest)
    }

    func newDocument() {
        let untitledIndex = documents.filter { $0.url == nil }.count
        // Localised "Untitled" / "Untitled 2" — keys match
        // tab.untitled / tab.untitled.numbered in Localizable.strings.
        let title = untitledIndex == 0
            ? L10n.t("tab.untitled")
            : L10n.t("tab.untitled.numbered", untitledIndex)
        let doc = Document(title: title)
        documents.append(doc)
        selectedID = doc.id
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let txtType = UTType("public.plain-text") {
            panel.allowedContentTypes = [txtType]
        }
        panel.allowsOtherFileTypes = true
        panel.runModal()
        for url in panel.urls {
            openFile(at: url)
        }
    }

    func openFile(at url: URL, line: Int? = nil) {
        let normalized = url.standardizedFileURL
        // Reuse if already open.
        if let existing = documents.first(where: { $0.url?.standardizedFileURL == normalized }) {
            selectedID = existing.id
            if let line { existing.pendingScrollLine = line }
            prefs.addRecent(normalized)
            return
        }

        // Phase 28b — read + decode happen on a background queue so the
        // main thread never stalls on a multi-megabyte `Data(contentsOf:)`.
        // We register a placeholder document immediately (text empty,
        // isLoading = true) so the tab + sidebar update without waiting
        // for I/O. The Scintilla coordinator sees the placeholder, paints
        // an empty buffer, and re-applies once the async load resolves.
        let doc = Document(title: normalized.lastPathComponent,
                           text: "",
                           url: normalized)
        doc.isLoading = true
        if let line { doc.pendingScrollLine = line }
        // Phase 46b — re-apply the user's pin for this URL so the
        // tab opens already pinned + gets slotted into the pinned
        // section. Cheap — Set membership check + bool flip. The
        // append + resortByPin() below finish the positioning.
        if prefs.pinnedFilePaths.contains(normalized.path) {
            doc.isPinned = true
        }

        // Phase 34b — fast file-size probe to decide which load path
        // owns this document. Cheap (one stat() in URL.resourceValues);
        // doing it before the async hop keeps the placeholder doc
        // tagged correctly from the moment the Coordinator first sees
        // it, so we never mis-apply a String-path to a multi-GB file
        // and OOM. `fileSize == 0` either means "tiny / empty file"
        // (safe — String path handles it fine) or "couldn't stat"
        // (also safe — Data(contentsOf:) will surface the error from
        // its own retry on the background queue).
        let fileSize = ChunkedFileReader(url: normalized).fileSize()
        if LargeFilePolicy.shouldUseChunkedLoad(forSize: fileSize) {
            doc.isLargeFile = true
            doc.loadProgress = 0
        }

        documents.append(doc)
        // Phase 46b — if this doc was pinned, slide it into the
        // pinned block so the tab strip reflects the invariant
        // (pinned first) from the moment the tab appears.
        if doc.isPinned {
            resortByPin()
        }
        selectedID = doc.id
        prefs.addRecent(normalized)

        // Large-file path: skip loadAndDecode entirely. The editor
        // Coordinator owns the chunked pipeline (it has the live
        // ScintillaView; we don't). It looks at doc.isLargeFile in
        // attach() and kicks off the LargeFileLoader.
        if doc.isLargeFile {
            // isLoading stays true; the Coordinator clears it once
            // SCI_SETDOCPOINTER lands and the document is on screen.
            return
        }

        // Two-stage Task: the outer body lives on the main actor and
        // is the only place we ever touch `self` — the inner
        // `Task.detached` is a leaf that captures only Sendable
        // values (URL + the static fn pointer) and returns a
        // Sendable result. This shape is what Swift 6's region-
        // based isolation model accepts without complaining about
        // sending `self` across actor boundaries.
        let docID = doc.id
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Workspace.loadAndDecode(at: normalized)
            }.value
            guard let self else { return }
            guard let target = self.documents.first(where: { $0.id == docID }) else {
                // Document was closed while loading — silently
                // discard the result. No harm, no surfaced error.
                return
            }
            self.applyLoadResult(result, to: target)
        }
    }

    /// Off-main-thread file read + format detection. Returns either
    /// the decoded payload or the underlying Cocoa error so the
    /// main-thread callback can surface a single NSAlert.
    /// `nonisolated` because Workspace itself is `@MainActor` but
    /// this routine has no shared state and runs purely on the
    /// background queue the Task.detached call hops onto.
    nonisolated private static func loadAndDecode(at url: URL) -> Result<DecodedDocument, Error> {
        do {
            // .mappedIfSafe lets the kernel page the file in lazily for
            // very large reads; for small files it falls back to a
            // regular read with no behavioural difference.
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let format = TextFormatDetector.decode(data: data)
            return .success(DecodedDocument(text: format.text,
                                            encoding: format.encoding,
                                            lineEnding: format.lineEnding))
        } catch {
            return .failure(error)
        }
    }

    /// Decoded payload from the background loader. Sendable so it can
    /// hop the actor boundary back to the main thread.
    private struct DecodedDocument: Sendable {
        let text: String
        let encoding: TextEncoding
        let lineEnding: LineEnding
    }

    /// Main-thread side of the async open. Either fills in the
    /// placeholder document with the decoded payload (success) or
    /// removes it and surfaces an alert (failure). Either way the
    /// `isLoading` flag is cleared so the editor wrapper drops the
    /// placeholder UI.
    private func applyLoadResult(_ result: Result<DecodedDocument, Error>, to doc: Document) {
        switch result {
        case .success(let payload):
            doc.text = payload.text
            doc.encoding = payload.encoding
            doc.lineEnding = payload.lineEnding
            doc.isLoading = false
            startWatching(doc)
            // Phase 35c-ii-β — kick off the blame fetch alongside
            // the watcher install. The cache-hit short-circuit
            // means a re-open of the same path is free; the first
            // open hops to a detached task so the editor draws
            // before git blame returns.
            gitBlameEngine.request(for: doc.url)
        case .failure(let error):
            doc.isLoading = false
            // Drop the placeholder — it represents a doc the user
            // can't actually edit, and leaving it would clutter the
            // tab bar with a broken entry.
            documents.removeAll { $0.id == doc.id }
            if selectedID == doc.id {
                selectedID = documents.last?.id
            }
            // Phase 43-T — non-blocking toast replaces NSAlert.
            // The user has nothing to *decide* here, so the modal
            // bouncing the dock icon was over-emphasized.
            toastCenter.error(L10n.t("toast.fileLoad.failed"),
                              message: (error as NSError).localizedDescription)
        }
    }

    // MARK: - File-system watching

    /// (Re)attach a watcher to this document's URL. Safe to call multiple
    /// times — earlier watchers are torn down first.
    private func startWatching(_ doc: Document) {
        watchers[doc.id] = nil
        guard let url = doc.url else { return }
        watchers[doc.id] = FileWatcher(url: url) { [weak self, weak doc] in
            guard let self, let doc else { return }
            self.handleExternalChange(of: doc)
        }
    }

    private func stopWatching(_ doc: Document) {
        watchers[doc.id] = nil
    }

    /// Called when the OS reports our document's file changed on disk.
    /// Re-reads the bytes and either silently refreshes the editor (clean
    /// document) or asks the user how to proceed (dirty document).
    private func handleExternalChange(of doc: Document) {
        guard let url = doc.url else { return }
        // Phase 34c — large-file path can't load the full bytes into
        // memory just to compare against `doc.text` (which is empty
        // for large docs anyway). For now, FSEvents on a large doc
        // is treated as a no-op: we trust Scintilla's buffer is the
        // truth of record. v2 will diff via mtime + on-disk size to
        // catch external mutations, then offer a chunked reload.
        if doc.isLargeFile { return }
        // The file may have been deleted or renamed; if we can't read it,
        // surface the situation but leave doc.text alone so the user can
        // re-save.
        guard let data = try? Data(contentsOf: url) else {
            doc.isDirty = true   // mark as needing user action
            return
        }
        let decoded = TextFormatDetector.decode(data: data)
        // Phase 28c — flush throttled edits before the echo check.
        // The watcher's most common trigger is our own atomic write
        // landing; if a stale doc.text caused a false mismatch we'd
        // pop the "reload?" dialog after every save.
        doc.flushPendingEdit?()
        // Echo from our own write — bytes match what we already have.
        if decoded.text == doc.text { return }

        if doc.isDirty {
            externalChangePrompt = ExternalChangePrompt(documentID: doc.id,
                                                        title: doc.title,
                                                        decoded: decoded)
            return
        }
        // Silent refresh for clean documents (and confirmed-reload dirty ones).
        applyDecodedExternalChange(decoded, to: doc)
    }

    func resolveExternalChange(_ prompt: ExternalChangePrompt, reloadFromDisk: Bool) {
        if externalChangePrompt?.documentID == prompt.documentID {
            externalChangePrompt = nil
        }
        guard reloadFromDisk,
              let doc = documents.first(where: { $0.id == prompt.documentID }) else {
            return
        }
        applyDecodedExternalChange(prompt.decoded, to: doc)
    }

    private func applyDecodedExternalChange(_ decoded: DetectedTextFormat, to doc: Document) {
        doc.text = decoded.text
        doc.encoding = decoded.encoding
        doc.lineEnding = decoded.lineEnding
        doc.isDirty = false
        // Phase 31 — file on disk just changed; re-run git diff so the
        // gutter catches up. Cheap relative to re-decoding the whole
        // file we just did.
        if doc.id == selectedID { gitGutterEngine.refresh() }
        // Phase 35b-1 — same trigger drives the Source Control
        // sidebar; an external editor saving a file we have open
        // changes its git status (added → modified, etc).
        gitStatusEngine.refresh()
        // Phase 35c-ii-β — external write moved the file's
        // bytes; blame for new lines now reads as uncommitted
        // (the all-zeros sentinel) and existing lines may have
        // shifted line numbers. Force re-fetch so the inline
        // annotation tracks reality.
        gitBlameEngine.refresh(for: doc.url)
    }

    /// Silent re-read of `doc` from disk using its current encoding.
    /// No confirmation prompt — callers (Find-in-Files Replace All,
    /// FS-watcher reload, …) are responsible for surfacing whatever
    /// confirmation UX is appropriate before invoking this.
    /// Returns false if the file is gone or can't be decoded.
    @discardableResult
    func reloadFromDisk(doc: Document) -> Bool {
        guard let url = doc.url else { return false }
        guard let data = try? Data(contentsOf: url) else { return false }
        let payload = TextFormatDetector.stripBOM(data, for: doc.encoding)
        guard let raw = String(data: payload,
                               encoding: doc.encoding.stringEncoding) else {
            return false
        }
        doc.text = TextFormatDetector.normalize(raw)
        doc.lineEnding = TextFormatDetector.detectLineEnding(in: raw)
        doc.isDirty = false
        return true
    }

    /// Re-decode the document's source bytes using a different encoding.
    /// Discards unsaved changes after a confirmation prompt.
    func reopen(doc: Document, as encoding: TextEncoding) {
        guard let url = doc.url else { return }
        if doc.isDirty {
            let alert = NSAlert()
            alert.messageText = L10n.t("alert.reopenEncoding.title",
                                       doc.title as NSString,
                                       encoding.displayName as NSString)
            alert.informativeText = L10n.t("alert.reopenEncoding.body")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.t("alert.button.reopen"))
            alert.addButton(withTitle: L10n.t("alert.button.cancel"))
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        do {
            let data = try Data(contentsOf: url)
            let payload = TextFormatDetector.stripBOM(data, for: encoding)
            guard let raw = String(data: payload, encoding: encoding.stringEncoding) else {
                // Phase 43-T — toast replaces NSAlert.
                toastCenter.error(L10n.t("toast.encoding.cannotDecode"),
                                  message: L10n.t("error.cannotDecode", encoding.displayName as NSString))
                return
            }
            doc.text = TextFormatDetector.normalize(raw)
            doc.encoding = encoding
            doc.lineEnding = TextFormatDetector.detectLineEnding(in: raw)
            doc.isDirty = false
        } catch {
            // Phase 43-T — toast replaces NSAlert.
            toastCenter.error(error)
        }
    }

    /// Change the encoding tag on the document. The next save will use it.
    func setEncoding(of doc: Document, to encoding: TextEncoding) {
        guard doc.encoding != encoding else { return }
        doc.encoding = encoding
        doc.isDirty = true
    }

    /// Change the line-ending tag on the document. Saved bytes will use it.
    func setLineEnding(of doc: Document, to ending: LineEnding) {
        guard doc.lineEnding != ending else { return }
        doc.lineEnding = ending
        doc.isDirty = true
    }

    func saveCurrent() {
        guard let doc = current else { return }
        if let url = doc.url {
            write(doc: doc, to: url)
        } else {
            saveAs(doc: doc)
        }
    }

    @discardableResult
    private func saveAs(doc: Document) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.title
        if panel.runModal() == .OK, let url = panel.url {
            let normalized = url.standardizedFileURL
            return write(doc: doc,
                         to: normalized,
                         commitURLOnSuccess: normalized)
        }
        return false
    }

    private func commitSaveURLIfNeeded(_ url: URL?, for doc: Document) {
        guard let url else { return }
        doc.url = url
        doc.title = url.lastPathComponent
        prefs.addRecent(url)
        startWatching(doc)   // URL just changed — rewatch the new location
    }

    @discardableResult
    private func write(doc: Document,
                       to url: URL,
                       commitURLOnSuccess: URL? = nil) -> Bool {
        // Phase 34c — large-file path skips the String-based encode +
        // atomic write entirely. The buffer lives on the C++ side
        // and `doc.text` stays empty for the document's lifetime;
        // the editor's Coordinator installs `largeFileSaveHook` on
        // attach which streams `SCI_GETTEXTRANGEFULL` chunks to a
        // sibling temp file and atomically renames it on top of
        // `url`. We hop through a Task because the hook is async
        // (`await Task.yield()` between chunks keeps the run loop
        // responsive on multi-GB saves); doc.saveProgress drives the
        // status bar banner the same way doc.loadProgress does for
        // chunked open.
        if doc.isLargeFile {
            // Re-entrancy guard: ⌘S during an in-flight save is a
            // no-op rather than queuing a second pipeline that would
            // race the first for the same temp-file slot.
            guard doc.saveProgress < 0 else { return false }
            guard let hook = doc.largeFileSaveHook else {
                // No editor attached — should be impossible for a
                // doc the user can ⌘S, but bail with a toast
                // instead of crashing on the implicit unwrap.
                // Phase 43-T — toast replaces NSAlert.
                toastCenter.error(L10n.t("toast.fileSave.failed"),
                                  message: L10n.t("error.largeFileSaveNoEditor"))
                return false
            }
            doc.saveProgress = 0
            let docRef = doc
            Task { @MainActor [weak self] in
                do {
                    try await hook(url) { p in
                        docRef.saveProgress = p
                    }
                    self?.commitSaveURLIfNeeded(commitURLOnSuccess, for: docRef)
                    docRef.saveProgress = -1
                    docRef.isDirty = false
                    // Mirror small-file save's gutter refresh; the
                    // FSEvents watcher will also fire but
                    // handleExternalChange short-circuits when the
                    // disk + buffer agree, so only this call
                    // actually drives the gutter recompute.
                    if let self, docRef.id == self.selectedID {
                        self.gitGutterEngine.refresh()
                    }
                    // Phase 35b-1 — refresh Source Control rows;
                    // chunked save just rewrote the on-disk bytes
                    // git compares against.
                    self?.gitStatusEngine.refresh()
                    // Phase 35c-ii-β — same trigger drives
                    // inline blame: the just-written file
                    // commits no new history (yet) but its
                    // line numbers may have shifted, so the
                    // cached blame is stale.
                    self?.gitBlameEngine.refresh(for: docRef.url)
                } catch {
                    docRef.saveProgress = -1
                    // Phase 43-T — toast replaces NSAlert.
                    self?.toastCenter.error(L10n.t("toast.fileSave.failed"),
                                            message: (error as NSError).localizedDescription)
                }
            }
            return true
        }

        // Phase 28c — drain any throttled keystrokes before reading
        // doc.text. Without this, ⌘S right after a fast typing burst
        // could write the up-to-50-ms-stale snapshot the editor had
        // last synced.
        doc.flushPendingEdit?()
        do {
            guard let payload = TextFormatDetector.encode(
                doc.text,
                encoding: doc.encoding,
                lineEnding: doc.lineEnding
            ) else {
                // Phase 43-T — toast replaces NSAlert.
                toastCenter.error(L10n.t("toast.encoding.cannotEncode"),
                                  message: L10n.t("error.cannotEncode", doc.encoding.displayName as NSString))
                return false
            }
            try payload.write(to: url, options: .atomic)
            commitSaveURLIfNeeded(commitURLOnSuccess, for: doc)
            doc.isDirty = false
            // Phase 31 — the just-written bytes are what `git diff`
            // sees; refresh the gutter so the saved-then-unmodified
            // lines disappear from the strip immediately. The watcher
            // will fire shortly with the same path but `decoded.text
            // == doc.text` already so handleExternalChange short-
            // circuits, and only this call actually drives the gutter.
            if doc.id == selectedID { gitGutterEngine.refresh() }
            // Phase 35b-1 — Source Control sidebar same trigger.
            gitStatusEngine.refresh()
            // Phase 35c-ii-β — inline blame catches up to the
            // just-written bytes so newly-uncommitted lines pick
            // up the all-zeros sentinel SHA on the next caret tick.
            gitBlameEngine.refresh(for: doc.url)
        } catch {
            // Phase 43-T — toast replaces NSAlert.
            toastCenter.error(L10n.t("toast.fileSave.failed"),
                              message: (error as NSError).localizedDescription)
            return false
        }
        return true
    }

    func close(documentID: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == documentID }) else { return }
        let doc = documents[idx]

        if doc.isDirty {
            let alert = NSAlert()
            alert.messageText = L10n.t("alert.unsaved.title", doc.title as NSString)
            alert.informativeText = L10n.t("alert.unsaved.body")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.t("alert.button.save"))      // returns .alertFirstButtonReturn
            alert.addButton(withTitle: L10n.t("alert.button.dontSave"))  // returns .alertSecondButtonReturn
            alert.addButton(withTitle: L10n.t("alert.button.cancel"))    // returns .alertThirdButtonReturn

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let didStartSave: Bool
                if doc.url != nil {
                    didStartSave = write(doc: doc, to: doc.url!)
                } else {
                    didStartSave = saveAs(doc: doc)
                }
                if !didStartSave || doc.isDirty { return } // user cancelled, save failed, or async save is still running
            case .alertSecondButtonReturn:
                break // discard
            default:
                return // cancel close
            }
        }

        stopWatching(doc)
        // Phase 46c — push the closed URL onto the reopen stack so
        // ⌘⇧T can restore it. Only URLs (tracked files) enter; the
        // Untitled scratch path has nothing to re-read from disk.
        // Dedupe the entry if it's already in the stack so repeated
        // open→close cycles don't blow past the cap with duplicates.
        if let url = doc.url?.standardizedFileURL {
            rememberClosed(url: url)
        }
        documents.remove(at: idx)
        if selectedID == documentID {
            selectedID = documents.last?.id
        }
        if documents.isEmpty {
            newDocument()
        }
    }

    /// Phase 46c — push `url` onto the recently-closed stack, moving
    /// it to the top if it was already present and enforcing the
    /// size cap. Extracted from `close(documentID:)` so
    /// `reopenLastClosed` and any future mass-close path (close all,
    /// close folder) have a single-entry helper to call.
    private func rememberClosed(url: URL) {
        // Move-to-top semantics: if the user closes the same file
        // twice in a row we only want one slot on the stack.
        if let existing = recentlyClosedURLs.firstIndex(where: { $0 == url }) {
            recentlyClosedURLs.remove(at: existing)
        }
        recentlyClosedURLs.append(url)
        // Trim from the front (oldest) when the cap is exceeded so
        // the freshest entries always survive.
        while recentlyClosedURLs.count > Self.recentlyClosedCap {
            recentlyClosedURLs.removeFirst()
        }
    }

    /// Phase 46c — pop the most-recently-closed URL and open it as
    /// a new tab. No-op if the stack is empty or if the file has
    /// since been deleted off disk (Finder can race us). Returns
    /// the reopened URL on success so the caller can surface
    /// feedback (e.g. `⌘⇧T` toast) if it chooses to.
    @discardableResult
    func reopenLastClosed() -> URL? {
        while let url = recentlyClosedURLs.popLast() {
            // File-existence check: don't rehydrate a phantom tab if
            // the user closed the file and then deleted it from
            // Finder. Walk the stack until we find a valid entry or
            // exhaust it.
            if FileManager.default.fileExists(atPath: url.path) {
                openFile(at: url)
                return url
            }
        }
        return nil
    }
}
