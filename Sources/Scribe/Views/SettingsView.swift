//
//  SettingsView.swift
//  Stub for now — will host theme, font, indent, etc.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            VStack(spacing: 16) {
                Text("Theme: follows system")
                Text("Font: SF Mono")
                Text("Indent: 4 spaces")
                Text("(stub)")
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 480, height: 320)
    }
}
