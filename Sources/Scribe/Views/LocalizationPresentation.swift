//
//  LocalizationPresentation.swift
//  Small string-formatting helpers for UI text that is assembled in
//  code before it reaches SwiftUI/AppKit.
//

import Foundation

enum FindBarPresentation {
    static func statusText(status: String,
                           currentMatch: Int,
                           matchCount: Int,
                           query: String,
                           countText: (Int, Int) -> String = {
                               L10n.t("findbar.matches.count", $0, $1)
                           },
                           noMatchesText: () -> String = {
                               L10n.t("findbar.matches.none")
                           }) -> String {
        if !status.isEmpty {
            return status
        }
        if matchCount > 0 {
            return countText(currentMatch, matchCount)
        }
        if !query.isEmpty {
            return noMatchesText()
        }
        return ""
    }

    static func noMatchesStatus(localize: (String) -> String = L10n.t) -> String {
        localize("findbar.matches.none")
    }

    static func wrappedStatus(forward: Bool,
                              localize: (String) -> String = L10n.t) -> String {
        localize(forward
                 ? "findbar.status.wrappedTop"
                 : "findbar.status.wrappedBottom")
    }

    static func replacedStatus(localize: (String) -> String = L10n.t) -> String {
        localize("findbar.status.replaced")
    }

    static func replacedCountStatus(count: Int,
                                    text: (Int) -> String = {
                                        L10n.t("findbar.status.replacedCount", $0)
                                    }) -> String {
        text(count)
    }
}

enum FindInFilesPresentation {
    static func replaceSummaryText(_ summary: ReplaceSummary,
                                   baseText: (Int, Int, Int) -> String = {
                                       L10n.t("finfiles.replaceSummary.completed", $0, $1, $2)
                                   },
                                   errorsText: (String) -> String = {
                                       L10n.t("finfiles.replaceSummary.errors", $0 as NSString)
                                   },
                                   moreText: (Int) -> String = {
                                       L10n.t("finfiles.replaceSummary.errors.more", $0)
                                   }) -> String {
        var message = baseText(summary.totalReplacements,
                               summary.filesChanged,
                               summary.filesScanned)
        guard !summary.errors.isEmpty else { return message }

        let head = summary.errors.prefix(2)
            .map { "\($0.0.lastPathComponent): \($0.1)" }
            .joined(separator: "; ")
        let tail = summary.errors.count > 2
            ? " \(moreText(summary.errors.count - 2))"
            : ""
        message += " \(errorsText("\(head)\(tail)"))"
        return message
    }

    static func fileToggleHelp(isSelected: Bool,
                               localize: (String) -> String = L10n.t) -> String {
        localize(isSelected
                 ? "finfiles.selection.file.includeHelp"
                 : "finfiles.selection.file.skipHelp")
    }

    static func fileToggleAccessibility(isSelected: Bool,
                                        fileName: String,
                                        selectedText: (String) -> String = {
                                            L10n.t("finfiles.selection.file.selected", $0 as NSString)
                                        },
                                        excludedText: (String) -> String = {
                                            L10n.t("finfiles.selection.file.excluded", $0 as NSString)
                                        }) -> String {
        isSelected ? selectedText(fileName) : excludedText(fileName)
    }

    static func matchToggleHelp(isSelected: Bool,
                                localize: (String) -> String = L10n.t) -> String {
        localize(isSelected
                 ? "finfiles.selection.match.includeHelp"
                 : "finfiles.selection.match.skipHelp")
    }

    static func matchToggleAccessibility(lineNumber: Int,
                                         isSelected: Bool,
                                         selectedText: (Bool) -> String = {
                                             $0 ? L10n.t("common.yes") : L10n.t("common.no")
                                         },
                                         labelText: (Int, String) -> String = {
                                             L10n.t("finfiles.selection.match.accessibility",
                                                    $0,
                                                    $1 as NSString)
                                         }) -> String {
        labelText(lineNumber, selectedText(isSelected))
    }
}

enum SettingsPresentation {
    static func fontSizeSummary(points: Int,
                                text: (Int) -> String = {
                                    L10n.t("settings.font.size.points", $0)
                                }) -> String {
        text(points)
    }

    static func tabWidthSummary(spaces: Int,
                                text: (Int) -> String = {
                                    L10n.t("settings.indent.tabWidth.spaces", $0)
                                }) -> String {
        text(spaces)
    }

    static func recentFilesSummary(count: Int,
                                   maxCount: Int,
                                   text: (Int, Int) -> String = {
                                       L10n.t("settings.recent.summary", $0, $1)
                                   }) -> String {
        text(count, maxCount)
    }
}
