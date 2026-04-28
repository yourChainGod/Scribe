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
            AppearanceSettingsPane(prefs: prefs)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 380)
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

/// Phase 15 picked a theme via a top-level menu; this pane brings
/// the same selector into the Settings panel so users who never
/// browse menus can still find it. Lives in its own tab because
/// the Editor tab is already busy with font + indentation.
private struct AppearanceSettingsPane: View {
    @ObservedObject var prefs: EditorPreferences

    var body: some View {
        Form {
            Section {
                // Picker presents every ThemeID. The .system entry
                // resolves at render-time against the current
                // NSAppearance so flipping macOS dark mode doesn't
                // require re-picking.
                Picker("Theme", selection: $prefs.themeID) {
                    ForEach(ThemeID.allCases) { id in
                        Text(id.displayName).tag(id)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Editor Theme")
            } footer: {
                Text("System (auto) follows the macOS light/dark preference. Pinning a specific theme overrides that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Live preview swatch. Confirms the picked theme's
            // colours without forcing the user to flip back to
            // the editor.
            Section("Preview") {
                ThemePreviewSwatch(theme: prefs.themeID
                                    .resolve(appearance: NSApp.effectiveAppearance))
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5),
                                          lineWidth: 0.5)
                    )
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }
}

/// Tiny mock-up of a code editor at the picked theme. Renders four
/// stylised "lines" using the same colour values the Scintilla
/// pane would receive. The Theme stores colours as 0xRRGGBB Ints;
/// we unpack them into SwiftUI Colors here so we don't need to
/// instantiate a full ScintillaView for the preview.
private struct ThemePreviewSwatch: View {
    let theme: Theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(rgb: theme.background)
            VStack(alignment: .leading, spacing: 4) {
                row(text: "func greet(name) {", tint: theme.keyword)
                row(text: "    return \"Hello\"", tint: theme.string)
                row(text: "    // welcome", tint: theme.comment)
                row(text: "}", tint: theme.foreground)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func row(text: String, tint: Int) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(rgb: tint))
        }
    }
}

/// 0xRRGGBB → SwiftUI `Color`. Same byte order Theme uses.
private extension Color {
    init(rgb: Int) {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8)  & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("Scribe")
                    .font(.system(size: 24, weight: .light))
                Text("Native macOS text editor")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                Text("v1.0 · Phase 25 polish")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("GPL-3.0 · aligned with notepad--")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
