//
//  LineOpsCommandButtons.swift
//  Phase 41d — shared menu content for line operations. Sits in
//  Tools ▶ Line Ops at the top level *and* in the right-click ▸
//  Transform ▸ Line Ops submenu so users meet it from either
//  direction. Action dispatch goes through `findState.commands`,
//  same path as every other selection transform.
//

import SwiftUI

struct LineOpsCommandButtons: View {
    @ObservedObject var findState: FindState
    @ObservedObject var prefs: EditorPreferences

    var body: some View {
        // — Mutating order
        Button { send(.dedupeLines) } label: {
            Text("lineops.dedupe", bundle: .module)
        }
        Button { send(.dropBlankLines) } label: {
            Text("lineops.dropBlank", bundle: .module)
        }
        Button { send(.reverseLines) } label: {
            Text("lineops.reverse", bundle: .module)
        }
        Divider()
        // — Whitespace cleanup
        Button { send(.trimTrailing) } label: {
            Text("lineops.trimTrailing", bundle: .module)
        }
        Button { send(.tabsToSpaces(width: prefs.tabWidth)) } label: {
            Text("lineops.tabsToSpaces", bundle: .module)
        }
        Button { send(.spacesToTabs(width: prefs.tabWidth)) } label: {
            Text("lineops.spacesToTabs", bundle: .module)
        }
        Divider()
        // — Sort submenu
        Menu {
            Button { send(.sortLines(mode: .lexicographic, descending: false)) } label: {
                Text("lineops.sort.lex", bundle: .module)
            }
            Button { send(.sortLines(mode: .lexicographic, descending: true)) } label: {
                Text("lineops.sort.lex.desc", bundle: .module)
            }
            Button { send(.sortLines(mode: .caseInsensitive, descending: false)) } label: {
                Text("lineops.sort.icase", bundle: .module)
            }
            Button { send(.sortLines(mode: .natural, descending: false)) } label: {
                Text("lineops.sort.natural", bundle: .module)
            }
            Button { send(.sortLines(mode: .numeric, descending: false)) } label: {
                Text("lineops.sort.numeric", bundle: .module)
            }
            Button { send(.sortLines(mode: .length, descending: false)) } label: {
                Text("lineops.sort.length", bundle: .module)
            }
        } label: {
            Text("lineops.sort.menu", bundle: .module)
        }
        // — Case submenu
        Menu {
            Button { send(.caseTransform(mode: .lower)) } label: {
                Text("lineops.case.lower", bundle: .module)
            }
            Button { send(.caseTransform(mode: .upper)) } label: {
                Text("lineops.case.upper", bundle: .module)
            }
            Button { send(.caseTransform(mode: .title)) } label: {
                Text("lineops.case.title", bundle: .module)
            }
            Button { send(.caseTransform(mode: .sentence)) } label: {
                Text("lineops.case.sentence", bundle: .module)
            }
            Button { send(.caseTransform(mode: .camel)) } label: {
                Text("lineops.case.camel", bundle: .module)
            }
            Button { send(.caseTransform(mode: .snake)) } label: {
                Text("lineops.case.snake", bundle: .module)
            }
            Button { send(.caseTransform(mode: .kebab)) } label: {
                Text("lineops.case.kebab", bundle: .module)
            }
        } label: {
            Text("lineops.case.menu", bundle: .module)
        }
    }

    @MainActor
    private func send(_ action: TextTransformAction) {
        findState.commands.send(.transformSelection(action))
    }
}
