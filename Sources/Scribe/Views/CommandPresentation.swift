//
//  CommandPresentation.swift
//  Palette row presentation metadata shared by Command Palette, Quick Open,
//  and snippet picker surfaces.
//

import Foundation

struct CommandPresentation: Equatable {
    let iconName: String
    let title: String
    let detail: String?
    let badge: String?

    init(command: ScribeCommand,
         localize: (String) -> String = L10n.t) {
        iconName = Self.iconName(for: command)
        title = Self.cleanTitle(command.title)

        if command.id.hasPrefix("quickopen.") {
            detail = Self.visibleDetail(command.subtitle)
            badge = command.id.hasPrefix("quickopen.open:")
                ? localize("palette.badge.open")
                : nil
        } else if command.id.hasPrefix("symbol:") {
            detail = Self.visibleDetail(command.subtitle)
            badge = localize("palette.badge.symbol")
        } else if command.id.hasPrefix("gotoLine:") {
            detail = Self.visibleDetail(command.subtitle)
            badge = localize("palette.badge.line")
        } else if command.id.hasPrefix("snippet:") {
            detail = Self.visibleDetail(command.subtitle)
            badge = localize("palette.badge.snippet")
        } else if let badgeKey = Self.categoryBadgeKey(for: command)
                    ?? Self.categoryBadgeKey(forSubtitle: command.subtitle) {
            detail = nil
            badge = localize(badgeKey)
        } else {
            detail = Self.visibleDetail(command.subtitle)
            badge = nil
        }
    }

    private static func cleanTitle(_ title: String) -> String {
        title.hasPrefix("● ") ? String(title.dropFirst(2)) : title
    }

    private static func visibleDetail(_ subtitle: String?) -> String? {
        guard let subtitle,
              !subtitle.isEmpty,
              subtitle != "—" else {
            return nil
        }
        return subtitle
    }

    private static func categoryBadgeKey(for command: ScribeCommand) -> String? {
        let id = command.id
        if id.hasPrefix("file.") { return "menu.file" }
        if id.hasPrefix("view.") { return "menu.view" }
        if id.hasPrefix("tab.") { return "palette.badge.tab" }
        if id.hasPrefix("text.") { return "palette.badge.text" }
        if id.hasPrefix("enc.") { return "palette.badge.encoding" }
        if id.hasPrefix("eol.") { return "palette.badge.lineEnding" }
        if id.hasPrefix("lexer.") { return "palette.badge.syntax" }
        return nil
    }

    private static func categoryBadgeKey(forSubtitle subtitle: String?) -> String? {
        guard let subtitle else { return nil }
        switch subtitle {
        case "File": return "menu.file"
        case "View": return "menu.view"
        case "Tab": return "palette.badge.tab"
        case "Text": return "palette.badge.text"
        case "Encoding": return "palette.badge.encoding"
        case "Line Ending": return "palette.badge.lineEnding"
        case "Syntax": return "palette.badge.syntax"
        default: return nil
        }
    }

    private static func iconName(for command: ScribeCommand) -> String {
        let id = command.id
        if id.hasPrefix("quickopen.") { return "doc.text" }
        if id.hasPrefix("symbol:") { return "number" }
        if id.hasPrefix("gotoLine:") { return "arrow.right.to.line" }
        if id.hasPrefix("snippet:") { return "curlybraces" }
        if id.hasPrefix("tab.") { return "text.justify" }
        if id.hasPrefix("text.") { return "tablecells" }
        if id.hasPrefix("enc.") { return "character.cursor.ibeam" }
        if id.hasPrefix("eol.") { return "return" }
        if id.hasPrefix("lexer.") { return "curlybraces.square" }

        switch id {
        case "file.new":
            return "square.and.pencil"
        case "file.open", "file.openFolder", "file.closeFolder":
            return "folder"
        case "file.save":
            return "doc.badge.checkmark"
        case "file.clearRecent", "file.clearRecentFolders":
            return "clock.arrow.circlepath"
        case "view.toggleSidebar":
            return "sidebar.left"
        case "view.zoomIn":
            return "plus.magnifyingglass"
        case "view.zoomOut":
            return "minus.magnifyingglass"
        case "view.actualSize":
            return "textformat.size"
        case "view.toggleSoftTabs":
            return "text.alignleft"
        case "view.markdownPreview":
            return "eye"
        default:
            return "command"
        }
    }
}
