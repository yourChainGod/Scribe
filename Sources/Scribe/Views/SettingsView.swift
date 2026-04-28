//
//  SettingsView.swift
//  Real settings panel: editor font, tab width, soft tabs.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var prefs: EditorPreferences
    @EnvironmentObject var snippets: SnippetCatalog

    var body: some View {
        TabView {
            EditorSettingsPane(prefs: prefs)
                .tabItem {
                    Label {
                        Text("settings.tab.editor", bundle: .module)
                    } icon: {
                        Image(systemName: "text.cursor")
                    }
                }
            AppearanceSettingsPane(prefs: prefs)
                .tabItem {
                    Label {
                        Text("settings.tab.appearance", bundle: .module)
                    } icon: {
                        Image(systemName: "paintpalette")
                    }
                }
            SnippetsSettingsPane(catalog: snippets)
                .tabItem {
                    Label {
                        Text("settings.tab.snippets", bundle: .module)
                    } icon: {
                        Image(systemName: "doc.text.below.ecg")
                    }
                }
            AboutPane()
                .tabItem {
                    Label {
                        Text("settings.tab.about", bundle: .module)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                }
        }
        // Phase 33 — wider + slightly taller than the previous panel
        // to give the multi-line snippet body editor room to breathe.
        // The other tabs were already comfortable inside the old size,
        // so they just inherit the extra space without re-layout.
        .frame(width: 720, height: 460)
    }
}

private struct EditorSettingsPane: View {
    @ObservedObject var prefs: EditorPreferences

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("settings.field.family", bundle: .module)
                    Spacer()
                    Picker("", selection: $prefs.fontName) {
                        Text("settings.font.systemMonospaced", bundle: .module).tag("")
                        ForEach(monospacedFamilies, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }

                HStack {
                    Text("settings.field.size", bundle: .module)
                    Spacer()
                    Stepper(value: $prefs.fontSize,
                            in: EditorPreferences.fontSizeMin...EditorPreferences.fontSizeMax,
                            step: 1) {
                        Text("\(Int(prefs.fontSize)) pt")
                            .monospacedDigit()
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                }
            } header: {
                Text("settings.section.font", bundle: .module)
            }

            Section {
                HStack {
                    Text("settings.field.tabWidth", bundle: .module)
                    Spacer()
                    Stepper(value: $prefs.tabWidth,
                            in: EditorPreferences.tabWidthMin...EditorPreferences.tabWidthMax) {
                        Text("\(prefs.tabWidth) spaces")
                            .monospacedDigit()
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                }
                Toggle(isOn: $prefs.softTabs) {
                    Text("settings.field.softTabs", bundle: .module)
                }
            } header: {
                Text("settings.section.indent", bundle: .module)
            }

            Section {
                HStack {
                    Text("\(prefs.recentFiles.count) remembered (max \(EditorPreferences.recentFilesMax))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        prefs.clearRecent()
                    } label: {
                        Text("settings.action.clear", bundle: .module)
                    }
                    .disabled(prefs.recentFiles.isEmpty)
                }
            } header: {
                Text("settings.section.recent", bundle: .module)
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
                Picker(selection: $prefs.themeID) {
                    ForEach(ThemeID.allCases) { id in
                        Text(id.displayName).tag(id)
                    }
                } label: {
                    Text("settings.appearance.theme", bundle: .module)
                }
                .pickerStyle(.menu)
            } header: {
                Text("settings.appearance.section.theme", bundle: .module)
            } footer: {
                Text("settings.appearance.themeFooter", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Live preview swatch. Confirms the picked theme's
            // colours without forcing the user to flip back to
            // the editor.
            Section {
                ThemePreviewSwatch(theme: prefs.themeID
                                    .resolve(appearance: NSApp.effectiveAppearance))
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5),
                                          lineWidth: 0.5)
                    )
            } header: {
                Text("settings.appearance.preview", bundle: .module)
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

/// Phase 33 — Snippets settings tab. Two-pane layout: a list of
/// snippet names on the left, an editor form on the right that
/// pushes every keystroke through `catalog.update(_:)` so the JSON
/// store on disk stays in lock-step with the UI.
private struct SnippetsSettingsPane: View {
    @ObservedObject var catalog: SnippetCatalog

    /// Currently-edited snippet, by id. nil ⇒ no selection (e.g.
    /// empty catalog or the selected row was just deleted). Survives
    /// list re-orders because we store the id, not the index.
    @State private var selectedID: UUID?
    @State private var showResetAlert = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // Pick the first snippet on first appearance so the user
            // sees a populated form instead of an empty hint.
            if selectedID == nil { selectedID = catalog.snippets.first?.id }
        }
        .onChange(of: catalog.snippets.map(\.id)) { _, ids in
            // Selection survives non-destructive edits but needs
            // recovery after a delete / reset.
            if let sel = selectedID, !ids.contains(sel) {
                selectedID = ids.first
            } else if selectedID == nil {
                selectedID = ids.first
            }
        }
        .alert(L10n.t("settings.snippets.alert.reset.title"),
               isPresented: $showResetAlert) {
            Button(L10n.t("settings.snippets.button.cancel"),
                   role: .cancel) {}
            Button(L10n.t("settings.snippets.button.reset"),
                   role: .destructive) {
                catalog.resetToStarter()
                selectedID = catalog.snippets.first?.id
            }
        } message: {
            Text("settings.snippets.alert.reset.body", bundle: .module)
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            if catalog.snippets.isEmpty {
                Text("settings.snippets.empty", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(catalog.snippets) { snippet in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.name.isEmpty ? "—" : snippet.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            if !snippet.prefix.isEmpty {
                                Text(snippet.prefix)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(snippet.id)
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            HStack(spacing: 6) {
                Button {
                    let new = catalog.add(Snippet(
                        name: L10n.t("settings.snippets.placeholder.name"),
                        prefix: "",
                        body: "",
                        description: ""
                    ))
                    selectedID = new.id
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(L10n.t("settings.snippets.action.add"))

                Button {
                    guard let id = selectedID else { return }
                    catalog.remove(id: id)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil)
                .help(L10n.t("settings.snippets.action.delete"))

                Spacer()

                Button {
                    showResetAlert = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(L10n.t("settings.snippets.action.reset"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let binding = bindingForSnippet(id: id) {
            SnippetEditorForm(snippet: binding)
                .padding(20)
        } else {
            Text("settings.snippets.empty", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Two-way binding into the selected snippet that pushes every
    /// edit through `catalog.update(_:)`. Returns nil when the id
    /// isn't in the catalog (race with delete; the .onChange above
    /// recovers selection on the next tick).
    private func bindingForSnippet(id: UUID) -> Binding<Snippet>? {
        guard catalog.snippets.contains(where: { $0.id == id }) else {
            return nil
        }
        return Binding<Snippet>(
            get: {
                // Force-unwrap is safe — `contains` confirmed
                // membership and the catalog can't lose this id
                // mid-keystroke (mutations are main-actor + we just
                // checked).
                catalog.snippets.first(where: { $0.id == id })!
            },
            set: { newValue in
                catalog.update(newValue)
            }
        )
    }
}

/// Right-pane editor for a single snippet. All fields write straight
/// through the supplied binding so SnippetCatalog.update fires on
/// every keystroke; persistence is automatic.
private struct SnippetEditorForm: View {
    @Binding var snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            field(label: "settings.snippets.field.name",
                  placeholder: "settings.snippets.placeholder.name",
                  text: $snippet.name)

            field(label: "settings.snippets.field.prefix",
                  placeholder: "settings.snippets.placeholder.prefix",
                  text: $snippet.prefix)

            field(label: "settings.snippets.field.description",
                  placeholder: "settings.snippets.placeholder.description",
                  text: $snippet.description)

            VStack(alignment: .leading, spacing: 4) {
                Text("settings.snippets.field.body", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $snippet.body)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor)
                                            .opacity(0.5), lineWidth: 0.5)
                    )
            }
        }
    }

    @ViewBuilder
    private func field(label: LocalizedStringKey,
                       placeholder: String,
                       text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label, bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L10n.t(placeholder), text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text(verbatim: "Scribe")
                    .font(.system(size: 24, weight: .light))
                Text("about.tagline", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                Text("about.version", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("about.license", bundle: .module)
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
