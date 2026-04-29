//
//  InlineBlameFormatter.swift
//  Phase 35c-iii — presentation helpers for inline blame labels.
//

import Foundation

enum InlineBlameFormatter {

    static func label(for blame: GitClient.BlameLine,
                      currentAuthorName: String?) -> String {
        let sha7 = String(blame.sha.prefix(7))
        let time = RelativeTime.describe(epoch: blame.authorTime)
        return "  \(displayAuthor(for: blame, currentAuthorName: currentAuthorName)), \(time) • \(sha7)"
    }

    static func tooltip(for blame: GitClient.BlameLine,
                        currentAuthorName: String?) -> String {
        let sha7 = String(blame.sha.prefix(7))
        let author = displayAuthor(for: blame, currentAuthorName: currentAuthorName)
        let summary = blame.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty {
            return "\(author) • \(sha7)"
        }
        return "\(summary)\n\(author) • \(sha7)"
    }

    private static func displayAuthor(for blame: GitClient.BlameLine,
                                      currentAuthorName: String?) -> String {
        let author = blame.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = (currentAuthorName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !author.isEmpty, !current.isEmpty,
           author.compare(current, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return L10n.t("inlineBlame.author.you")
        }
        return author.isEmpty ? "Unknown" : author
    }
}
