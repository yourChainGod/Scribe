//
//  EditorPreferences.swift
//  Persisted user preferences for the editor (font, tab width, recent files).
//  Stored via UserDefaults; observable so SwiftUI views and AppKit bridge stay
//  in sync.
//

import Foundation
import SwiftUI
import AppKit

enum InlineBlameMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case currentLine
    case allLines

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .off:         return "settings.inlineBlame.mode.off"
        case .currentLine: return "settings.inlineBlame.mode.currentLine"
        case .allLines:    return "settings.inlineBlame.mode.allLines"
        }
    }
}

@MainActor
final class EditorPreferences: ObservableObject {
    static let recentFilesMax = 10
    static let fontSizeMin: CGFloat = 9
    static let fontSizeMax: CGFloat = 36
    static let fontSizeDefault: CGFloat = 13
    static let tabWidthMin = 1
    static let tabWidthMax = 16
    static let tabWidthDefault = 4

    private enum Key {
        static let fontSize = "editor.fontSize"
        static let fontName = "editor.fontName"
        static let tabWidth = "editor.tabWidth"
        static let softTabs = "editor.softTabs"
        static let recentFiles = "editor.recentFiles"
        static let recentFolders = "editor.recentFolders"
        // Phase 36 — superseded by appearance.uiThemeID; kept as
        // migration source so users upgrading from <Phase 36 keep
        // their previously-picked palette.
        static let legacyThemeID = "editor.themeID"
        static let uiThemeID = "appearance.uiThemeID"
        static let editorThemeID = "appearance.editorThemeID"
        static let editorFollowsUITheme = "appearance.editorFollowsUITheme"
        // Phase 39b — JSON blob storing per-theme slot overrides.
        // Outer dict keyed by ThemeID.rawValue (String for forward
        // compat — see ThemeOverrides.swift header comment).
        static let themeOverrides = "appearance.themeOverrides"
        static let inlineBlameMode = "editor.inlineBlameMode"
        // Phase 41f — toggle for the inline color-swatch overlay.
        // ON by default: the feature is universally useful for any
        // file containing CSS-style hex / rgb / hsl literals, and
        // costs nothing on documents without colors.
        static let inlineColorSwatchesEnabled = "editor.inlineColorSwatchesEnabled"
        // Phase 46b — pinned tab paths. Persisted as a sorted string
        // array under one key so `defaults read` shows a single list
        // rather than scattered entries. Standardized-file-URL path
        // is the stable identity; Untitled docs never make it in.
        static let pinnedFilePaths = "editor.pinnedFilePaths"
    }

    /// Phase 39a — translates raw values from the pre-39 theme
    /// catalog (Solarized / Dracula / Monokai / GitHub plus the
    /// Scribe Light/Dark renames) into the closest new preset. Run
    /// against ALL three theme keys (legacy `editor.themeID` plus
    /// the Phase 36 `appearance.uiThemeID` / `appearance.editorThemeID`)
    /// before the `ThemeID(rawValue:)` lookup, otherwise enums whose
    /// case has been removed silently fall back to `.system` and the
    /// user loses their selection.
    static let legacyThemeAlias: [String: ThemeID] = [
        "lightDefault":   .daylight,
        "darkDefault":    .inkwell,
        "solarizedLight": .sand,
        "solarizedDark":  .midnight,
        "dracula":        .midnight,
        "monokai":        .inkwell,
        "githubLight":    .daylight
    ]

    /// Resolve a stored raw value through the new catalog, falling
    /// back to the Phase 39a alias map for renamed/dropped IDs.
    /// Returns nil only when the raw value is genuinely unknown
    /// (typo in defaults, never-shipped beta value); callers chain
    /// `?? legacyID ?? .system` to land somewhere safe.
    private static func resolveStoredThemeID(_ raw: String?) -> ThemeID? {
        guard let raw, !raw.isEmpty else { return nil }
        return ThemeID(rawValue: raw) ?? legacyThemeAlias[raw]
    }

    private let defaults: UserDefaults

    @Published var fontSize: CGFloat {
        didSet { defaults.set(Double(fontSize), forKey: Key.fontSize) }
    }

    /// Empty string ⇒ use the system monospaced font.
    @Published var fontName: String {
        didSet { defaults.set(fontName, forKey: Key.fontName) }
    }

    @Published var tabWidth: Int {
        didSet { defaults.set(tabWidth, forKey: Key.tabWidth) }
    }

    /// If true, pressing Tab inserts `tabWidth` spaces instead of a literal `\t`.
    @Published var softTabs: Bool {
        didSet { defaults.set(softTabs, forKey: Key.softTabs) }
    }

    @Published var recentFiles: [URL] {
        didSet { defaults.set(recentFiles.map(\.path), forKey: Key.recentFiles) }
    }

    @Published var recentFolders: [URL] {
        didSet { defaults.set(recentFolders.map(\.path), forKey: Key.recentFolders) }
    }

    /// Phase 36 — global UI theme. Drives chrome surfaces (sidebar,
    /// status bar, accent, etc.) via `\.appTheme`. `.system` keeps
    /// the pre-Phase-15 behaviour (follow NSAppearance).
    @Published var uiThemeID: ThemeID {
        didSet { defaults.set(uiThemeID.rawValue, forKey: Key.uiThemeID) }
    }

    /// Phase 36 — editor theme used when `editorFollowsUITheme` is
    /// false. When true (default), the editor reads `uiThemeID`
    /// instead via `effectiveEditorThemeID`.
    @Published var editorThemeID: ThemeID {
        didSet { defaults.set(editorThemeID.rawValue, forKey: Key.editorThemeID) }
    }

    /// Phase 36 — when true (default), the Scintilla editor uses
    /// `uiThemeID` instead of `editorThemeID`. Lets users pick one
    /// theme for the whole app or decouple the editor from chrome.
    @Published var editorFollowsUITheme: Bool {
        didSet { defaults.set(editorFollowsUITheme, forKey: Key.editorFollowsUITheme) }
    }

    /// Phase 36 — the theme Scintilla should actually paint with.
    /// Convenience for `editorFollowsUITheme ? uiThemeID : editorThemeID`.
    /// Read by `Coordinator+Theme.applyTheme(to:)`.
    var effectiveEditorThemeID: ThemeID {
        editorFollowsUITheme ? uiThemeID : editorThemeID
    }

    /// Phase 35c-iii — user-facing visibility for Scintilla EOL
    /// inline-blame annotations. Default preserves the pre-settings
    /// behaviour: only the active caret line carries a chip.
    @Published var inlineBlameMode: InlineBlameMode {
        didSet { defaults.set(inlineBlameMode.rawValue, forKey: Key.inlineBlameMode) }
    }

    /// Phase 41f — paint a translucent rectangle behind every
    /// recognised color literal (#hex / rgb() / hsl()). Active in
    /// every file type, not just CSS — devs sprinkle hex codes
    /// through Markdown, JSON config, code comments, etc.
    @Published var inlineColorSwatchesEnabled: Bool {
        didSet { defaults.set(inlineColorSwatchesEnabled,
                              forKey: Key.inlineColorSwatchesEnabled) }
    }

    /// Phase 46b — set of standardized file-URL paths the user has
    /// pinned across sessions. Workspace consults this on
    /// `openFile(at:)` to re-apply the pin flag to freshly opened
    /// documents, and mutates it whenever `togglePin` changes the
    /// state. A `Set` so membership checks are O(1); persisted as a
    /// sorted array so `defaults read` output stays stable (handy
    /// for diff-based support dumps).
    @Published var pinnedFilePaths: Set<String> {
        didSet {
            defaults.set(Array(pinnedFilePaths).sorted(),
                         forKey: Key.pinnedFilePaths)
        }
    }

    /// Phase 39b — per-theme custom slot overrides. Sparse map: a
    /// missing `ThemeID` key means "no overrides for that preset",
    /// and an empty `ThemeOverrides.slots` should be cleaned up by
    /// the helpers below so the persisted JSON stays small.
    ///
    /// Mutation note: SwiftUI's `@Published` fires `didSet` on any
    /// outright assignment to this property. Swift's optional-chain
    /// subscript pattern (`themeOverrides[id]?.slots[slot] = c`)
    /// expands into a get-mutate-set sequence that DOES end with
    /// an assignment to the outer property — so it triggers
    /// `didSet` and persistence too. Prefer the helpers
    /// (`setOverride/clearOverride/clearAllOverrides`) anyway —
    /// they keep the empty-entry cleanup in one place and read
    /// clearer at call sites.
    @Published var themeOverrides: [ThemeID: ThemeOverrides] {
        didSet { persistThemeOverrides() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedFont = defaults.object(forKey: Key.fontSize) as? Double
        self.fontSize = Self.clampFontSize(CGFloat(storedFont ?? Double(Self.fontSizeDefault)))

        self.fontName = defaults.string(forKey: Key.fontName) ?? ""

        let storedTab = defaults.object(forKey: Key.tabWidth) as? Int
        self.tabWidth = Self.clampTabWidth(storedTab ?? Self.tabWidthDefault)

        self.softTabs = (defaults.object(forKey: Key.softTabs) as? Bool) ?? true

        let paths = defaults.stringArray(forKey: Key.recentFiles) ?? []
        self.recentFiles = paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }

        let folderPaths = defaults.stringArray(forKey: Key.recentFolders) ?? []
        self.recentFolders = folderPaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }

        // Phase 36 — load the new dual theme keys, falling back to
        // the legacy `editor.themeID` so users who picked Dracula
        // before this refactor still see their choice as the global
        // UI theme. We keep the legacy key in UserDefaults rather
        // than deleting it so a downgrade still finds something.
        //
        // Phase 39a — every read goes through `resolveStoredThemeID`
        // so dropped enum cases (Solarized / Dracula / Monokai /
        // GitHub) get migrated to their closest macOS-native
        // counterpart instead of crashing the user back to .system.
        let legacyID = Self.resolveStoredThemeID(
            defaults.string(forKey: Key.legacyThemeID)
        )

        self.uiThemeID = Self.resolveStoredThemeID(
            defaults.string(forKey: Key.uiThemeID)
        ) ?? legacyID ?? .system

        self.editorThemeID = Self.resolveStoredThemeID(
            defaults.string(forKey: Key.editorThemeID)
        ) ?? legacyID ?? .system

        // Default: editor follows UI. We only treat an explicit
        // `false` (set by user via Settings) as a real choice — a
        // missing key on first launch keeps the two in sync.
        if defaults.object(forKey: Key.editorFollowsUITheme) != nil {
            self.editorFollowsUITheme = defaults.bool(forKey: Key.editorFollowsUITheme)
        } else {
            self.editorFollowsUITheme = true
        }

        let blameModeRaw = defaults.string(forKey: Key.inlineBlameMode) ?? ""
        self.inlineBlameMode = InlineBlameMode(rawValue: blameModeRaw) ?? .currentLine

        // Phase 41f — default ON. Only flip OFF if the user
        // explicitly stored false; missing key keeps swatches on.
        if defaults.object(forKey: Key.inlineColorSwatchesEnabled) != nil {
            self.inlineColorSwatchesEnabled = defaults.bool(forKey: Key.inlineColorSwatchesEnabled)
        } else {
            self.inlineColorSwatchesEnabled = true
        }

        // Phase 46b — load pinned URL paths. Missing key ⇒ empty set
        // (no pins yet); any non-string elements are filtered out so
        // a corrupted defaults blob can't crash the Set init.
        let pinnedArray = defaults.stringArray(forKey: Key.pinnedFilePaths) ?? []
        self.pinnedFilePaths = Set(pinnedArray)

        // Phase 39b — load per-theme override map. Silent fall-back
        // to empty map on decode failure (corrupted blob, future
        // schema evolution) mirrors `SnippetCatalog`'s strategy:
        // worst case the user re-customizes their colours; we never
        // crash on stored data.
        self.themeOverrides = Self.loadThemeOverrides(from: defaults)
    }

    // MARK: - Font

    func resolvedFont() -> NSFont {
        if !fontName.isEmpty, let f = NSFont(name: fontName, size: fontSize) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    func zoomIn() {
        fontSize = Self.clampFontSize(fontSize + 1)
    }

    func zoomOut() {
        fontSize = Self.clampFontSize(fontSize - 1)
    }

    func resetFontSize() {
        fontSize = Self.fontSizeDefault
    }

    // MARK: - Recent files

    func addRecent(_ url: URL) {
        let normalized = url.standardizedFileURL
        var list = recentFiles
        list.removeAll { $0 == normalized }
        list.insert(normalized, at: 0)
        if list.count > Self.recentFilesMax {
            list = Array(list.prefix(Self.recentFilesMax))
        }
        recentFiles = list
    }

    func clearRecent() {
        recentFiles = []
    }

    // MARK: - Recent folders

    func addRecentFolder(_ url: URL) {
        let normalized = url.standardizedFileURL
        var list = recentFolders
        list.removeAll { $0 == normalized }
        list.insert(normalized, at: 0)
        if list.count > Self.recentFilesMax {
            list = Array(list.prefix(Self.recentFilesMax))
        }
        recentFolders = list
    }

    func clearRecentFolders() {
        recentFolders = []
    }

    // MARK: - Theme overrides (Phase 39b)

    /// Read the current overrides for `themeID`. Returns an empty
    /// `ThemeOverrides` (no slots set) when the user has not
    /// customized that preset yet.
    func overrides(for themeID: ThemeID) -> ThemeOverrides {
        themeOverrides[themeID] ?? ThemeOverrides()
    }

    /// Pin one slot of one theme to `color`. Triggers a single
    /// outright assignment to `themeOverrides` so SwiftUI's
    /// `@Published` observers and the `didSet` persistence both
    /// fire — see the mutation contract on `themeOverrides`.
    func setOverride(_ themeID: ThemeID, slot: ThemeSlot, color: Int) {
        var t = themeOverrides[themeID] ?? ThemeOverrides()
        t.slots[slot] = color
        themeOverrides[themeID] = t
    }

    /// Drop one slot's override. If the theme then has no remaining
    /// overrides, remove its entry entirely so the persisted JSON
    /// doesn't bloat with empty objects (sparse stays sparse).
    func clearOverride(_ themeID: ThemeID, slot: ThemeSlot) {
        guard var t = themeOverrides[themeID] else { return }
        t.slots.removeValue(forKey: slot)
        if t.isEmpty {
            themeOverrides.removeValue(forKey: themeID)
        } else {
            themeOverrides[themeID] = t
        }
    }

    /// Drop every override for one theme — the "Reset all colors
    /// for {Theme}" Settings action.
    func clearAllOverrides(_ themeID: ThemeID) {
        themeOverrides.removeValue(forKey: themeID)
    }

    /// Persistence: re-encode the full map to JSON whenever
    /// `themeOverrides` mutates. Outer keys are stringified
    /// `ThemeID.rawValue` so future enum-case removal doesn't
    /// crash the decoder (see ThemeOverrides.swift header).
    private func persistThemeOverrides() {
        let stringKeyed: [String: ThemeOverrides] = Dictionary(
            uniqueKeysWithValues: themeOverrides.map { ($0.key.rawValue, $0.value) }
        )
        do {
            let data = try JSONEncoder().encode(stringKeyed)
            defaults.set(data, forKey: Key.themeOverrides)
        } catch {
            // Silent — see SnippetCatalog precedent. Worst case the
            // user's pending override doesn't survive relaunch.
        }
    }

    /// Load + migrate per-theme overrides at init time. Legacy raw
    /// outer keys (Dracula / Monokai / etc.) get folded into their
    /// Phase 39a counterparts via `legacyThemeAlias`. If two legacy
    /// keys collapse to the same modern theme, last-write-wins —
    /// stable enough given the alias map has at most one collision
    /// per modern target (the user can re-customize anyway).
    private static func loadThemeOverrides(from defaults: UserDefaults) -> [ThemeID: ThemeOverrides] {
        guard let data = defaults.data(forKey: Key.themeOverrides) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([String: ThemeOverrides].self, from: data) else {
            return [:]
        }
        var result: [ThemeID: ThemeOverrides] = [:]
        for (rawKey, value) in decoded {
            guard let themeID = ThemeID(rawValue: rawKey) ?? legacyThemeAlias[rawKey] else {
                continue   // unknown / never-shipped key — skip cleanly
            }
            // Merge: if two legacy keys collapsed onto the same
            // modern theme, union the slot maps (later writes win
            // on collision within the same slot).
            var entry = result[themeID] ?? ThemeOverrides()
            for (slot, color) in value.slots {
                entry.slots[slot] = color
            }
            if !entry.isEmpty {
                result[themeID] = entry
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func clampFontSize(_ v: CGFloat) -> CGFloat {
        min(max(v, fontSizeMin), fontSizeMax)
    }

    private static func clampTabWidth(_ v: Int) -> Int {
        min(max(v, tabWidthMin), tabWidthMax)
    }
}
