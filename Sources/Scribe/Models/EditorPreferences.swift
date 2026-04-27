//
//  EditorPreferences.swift
//  Persisted user preferences for the editor (font, tab width, recent files).
//  Stored via UserDefaults; observable so SwiftUI views and AppKit bridge stay
//  in sync.
//

import Foundation
import SwiftUI
import AppKit

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
        static let themeID = "editor.themeID"
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

    /// Phase 15 — currently active editor theme. `.system` keeps the
    /// pre-Phase-15 behaviour (follow NSAppearance); explicit cases
    /// pin a specific palette regardless of the OS-wide setting.
    @Published var themeID: ThemeID {
        didSet { defaults.set(themeID.rawValue, forKey: Key.themeID) }
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

        // Theme falls back to .system if the persisted value is
        // missing or no longer maps to a known case (e.g. user
        // downgraded after a future commit removed a theme).
        let themeRaw = defaults.string(forKey: Key.themeID) ?? ""
        self.themeID = ThemeID(rawValue: themeRaw) ?? .system
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

    // MARK: - Helpers

    private static func clampFontSize(_ v: CGFloat) -> CGFloat {
        min(max(v, fontSizeMin), fontSizeMax)
    }

    private static func clampTabWidth(_ v: Int) -> Int {
        min(max(v, tabWidthMin), tabWidthMax)
    }
}
