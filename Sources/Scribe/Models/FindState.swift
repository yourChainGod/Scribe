//
//  FindState.swift
//  Phase 4 — observable model behind ⌘F / ⌘R. Lives in the SwiftUI
//  environment so the bar stays visible across tab switches and retains
//  its query / replacement strings, which is what every modern editor
//  does.
//
//  The bar publishes user intent (toggle visibility, change query…)
//  through @Published; the editor coordinator subscribes to a Combine
//  PassthroughSubject for one-shot commands (Find Next, Replace All)
//  that aren't naturally state.
//

import Combine
import Foundation

@MainActor
final class FindState: ObservableObject {
    /// Show/hide the find bar above the editor.
    @Published var isVisible: Bool = false

    /// `true` shows the second row with the replacement field +
    /// "Replace" / "Replace All" buttons.
    @Published var isReplaceMode: Bool = false

    @Published var query: String = ""
    @Published var replacement: String = ""

    @Published var matchCase: Bool = false
    @Published var wholeWord: Bool = false
    @Published var regex: Bool = false

    /// 1-based ordinal of the currently selected match. `0` means "no
    /// active match". Driven by the editor coordinator after each search.
    @Published var currentMatch: Int = 0
    @Published var matchCount: Int = 0

    /// Short status line shown next to the count, e.g. "Wrapped" or
    /// "Replaced 12". Empty string ⇒ render nothing.
    @Published var status: String = ""

    /// One-shot commands the bar fires at the editor coordinator. The
    /// coordinator owns the search + selection logic; this state struct
    /// stays UI-only.
    enum Command {
        case findNext
        case findPrev
        /// Re-evaluate the search anchored at the *start* of the current
        /// selection — used by live-search-as-you-type so growing the
        /// query doesn't skip the match the user is staring at.
        case findCurrent
        case replaceCurrent
        case replaceAll
        case useSelection
    }
    let commands = PassthroughSubject<Command, Never>()

    // MARK: - Convenience

    func show(replaceMode: Bool) {
        isReplaceMode = replaceMode
        isVisible = true
    }

    func hide() {
        isVisible = false
        status = ""
    }
}
