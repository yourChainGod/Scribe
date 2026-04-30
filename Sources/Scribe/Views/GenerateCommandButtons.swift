//
//  GenerateCommandButtons.swift
//  Phase 41b — shared menu content for the Generator Pack. Lives
//  at Tools ▸ Generate. UUID / Lorem / Timestamp insert directly
//  via the snippet command channel; Password / QR raise sheets
//  because they need parameters before the insert can happen.
//

import SwiftUI

struct GenerateCommandButtons: View {
    @ObservedObject var findState: FindState
    @ObservedObject var workspace: Workspace

    var body: some View {
        Button { send(Generators.uuidV4()) } label: {
            Text("generator.uuid", bundle: .module)
        }

        Menu {
            Button { send(Generators.lorem(wordCount: 10)) } label: {
                Text("generator.lorem.short", bundle: .module)
            }
            Button { send(Generators.lorem(wordCount: 50)) } label: {
                Text("generator.lorem.paragraph", bundle: .module)
            }
            Button { send(Generators.lorem(wordCount: 100)) } label: {
                Text("generator.lorem.long", bundle: .module)
            }
        } label: {
            Text("generator.lorem.menu", bundle: .module)
        }

        Button {
            workspace.passwordSheet = PasswordSheetRequest()
        } label: {
            Text("generator.password.menu", bundle: .module)
        }

        Menu {
            Button { send(Generators.timestamp(format: .iso8601)) } label: {
                Text("generator.timestamp.iso8601", bundle: .module)
            }
            Button { send(Generators.timestamp(format: .iso8601Compact)) } label: {
                Text("generator.timestamp.iso8601Compact", bundle: .module)
            }
            Button { send(Generators.timestamp(format: .unixSeconds)) } label: {
                Text("generator.timestamp.unixSeconds", bundle: .module)
            }
            Button { send(Generators.timestamp(format: .unixMillis)) } label: {
                Text("generator.timestamp.unixMillis", bundle: .module)
            }
            Button { send(Generators.timestamp(format: .rfc2822)) } label: {
                Text("generator.timestamp.rfc2822", bundle: .module)
            }
            Button { send(Generators.timestamp(format: .yyyymmdd)) } label: {
                Text("generator.timestamp.date", bundle: .module)
            }
            Button { send(Generators.timestamp(format: .yyyymmddHHMMSS)) } label: {
                Text("generator.timestamp.dateTime", bundle: .module)
            }
        } label: {
            Text("generator.timestamp.menu", bundle: .module)
        }

        Button {
            let prefill = workspace.activeTextSelection
            workspace.qrSheet = QRSheetRequest(prefill: prefill)
        } label: {
            Text("generator.qr.menu", bundle: .module)
        }
    }

    @MainActor
    private func send(_ text: String) {
        // Reuse the snippet channel — inserts at every caret and
        // wraps the burst in a single Scintilla undo transaction.
        findState.commands.send(.insertSnippet(text))
    }
}
