//
//  SettingsView.swift
//  Real settings panel: editor font, tab width, soft tabs.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var prefs: EditorPreferences

    var body: some View {
        TabView {
            EditorSettingsPane(prefs: prefs)
                .tabItem { Label("Editor", systemImage: "text.cursor") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 360)
    }
}

private struct EditorSettingsPane: View {
    @ObservedObject var prefs: EditorPreferences

    var body: some View {
        Form {
            Section("Font") {
                HStack {
                    Text("Family")
                    Spacer()
                    Picker("", selection: $prefs.fontName) {
                        Text("System Monospaced").tag("")
                        ForEach(monospacedFamilies, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }

                HStack {
                    Text("Size")
                    Spacer()
                    Stepper(value: $prefs.fontSize,
                            in: EditorPreferences.fontSizeMin...EditorPreferences.fontSizeMax,
                            step: 1) {
                        Text("\(Int(prefs.fontSize)) pt")
                            .monospacedDigit()
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                }
            }

            Section("Indentation") {
                HStack {
                    Text("Tab width")
                    Spacer()
                    Stepper(value: $prefs.tabWidth,
                            in: EditorPreferences.tabWidthMin...EditorPreferences.tabWidthMax) {
                        Text("\(prefs.tabWidth) spaces")
                            .monospacedDigit()
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                }
                Toggle("Insert spaces when Tab is pressed", isOn: $prefs.softTabs)
            }

            Section("Recent Files") {
                HStack {
                    Text("\(prefs.recentFiles.count) remembered (max \(EditorPreferences.recentFilesMax))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { prefs.clearRecent() }
                        .disabled(prefs.recentFiles.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }

    private var monospacedFamilies: [String] {
        let preferred = ["Menlo", "Monaco", "SF Mono", "JetBrains Mono",
                         "Fira Code", "Source Code Pro", "PT Mono",
                         "Andale Mono", "Courier New"]
        let available = Set(NSFontManager.shared.availableFontFamilies)
        return preferred.filter { available.contains($0) }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("Scribe")
                .font(.system(size: 24, weight: .light))
            Text("Phase 0.2 · Native macOS text editor")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("GPL-3.0 · aligned with notepad--")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
