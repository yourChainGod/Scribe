//
//  StatusBarView.swift
//  Bottom strip: language, encoding, line ending, cursor position.
//

import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 12) {
            if let doc = workspace.current {
                Label(doc.languageGuess.uppercased(),
                      systemImage: "chevron.left.forwardslash.chevron.right")
                Divider().frame(height: 12)
                Text(encodingDescription(doc.encoding))
                Divider().frame(height: 12)
                Text(doc.lineEnding.short)
                Divider().frame(height: 12)
                Text("\(doc.text.count) chars")
            } else {
                Text("Ready")
            }
            Spacer()
            if let doc = workspace.current, doc.isDirty {
                Label("Modified", systemImage: "circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
    }

    private func encodingDescription(_ enc: String.Encoding) -> String {
        switch enc {
        case .utf8: "UTF-8"
        case .utf16: "UTF-16"
        case .ascii: "ASCII"
        default: "Unknown"
        }
    }
}
