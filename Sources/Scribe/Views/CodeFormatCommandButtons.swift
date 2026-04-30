//
//  CodeFormatCommandButtons.swift
//  Phase 41c — shared menu content for language-aware Pretty /
//  Minify. Lives at Tools ▸ Format and right-click ▸ Transform ▸
//  Format so the user meets it from either direction. Each language
//  is its own submenu (Pretty + Minify) so the menu stays browsable
//  even with four entries.
//

import SwiftUI

struct CodeFormatCommandButtons: View {
    @ObservedObject var findState: FindState

    var body: some View {
        Menu {
            Button { send(.formatJSON) } label: {
                Text("format.action.pretty", bundle: .module)
            }
            Button { send(.minifyJSON) } label: {
                Text("format.action.minify", bundle: .module)
            }
        } label: {
            Text("format.lang.json", bundle: .module)
        }
        Menu {
            Button { send(.formatXML) } label: {
                Text("format.action.pretty", bundle: .module)
            }
            Button { send(.minifyXML) } label: {
                Text("format.action.minify", bundle: .module)
            }
        } label: {
            Text("format.lang.xml", bundle: .module)
        }
        Menu {
            Button { send(.formatCSS) } label: {
                Text("format.action.pretty", bundle: .module)
            }
            Button { send(.minifyCSS) } label: {
                Text("format.action.minify", bundle: .module)
            }
        } label: {
            Text("format.lang.css", bundle: .module)
        }
        Menu {
            Button { send(.formatSQL) } label: {
                Text("format.action.pretty", bundle: .module)
            }
            Button { send(.minifySQL) } label: {
                Text("format.action.minify", bundle: .module)
            }
        } label: {
            Text("format.lang.sql", bundle: .module)
        }
    }

    @MainActor
    private func send(_ action: TextTransformAction) {
        findState.commands.send(.transformSelection(action))
    }
}
