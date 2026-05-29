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
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                }
            ClipboardSettingsPane(prefs: prefs)
                .tabItem {
                    Label {
                        Text("settings.tab.clipboard", bundle: .module)
                    } icon: {
                        Image(systemName: "doc.on.clipboard")
                    }
                }
            AutoSaveSettingsPane(prefs: prefs)
                .tabItem {
                    Label {
                        Text("settings.tab.autoSave", bundle: .module)
                    } icon: {
                        Image(systemName: "tray.and.arrow.down.fill")
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
        // Phase 33 set width=720,height=460 for the multi-line
        // snippet body editor. Phase 43-S added a fifth section to
        // the Editor tab (Display, hosting the inline color-swatch
        // toggle), and 460 px started clipping the Recent Files
        // row. Bumping to 520 px lets all five sections stand
        // without needing scroll, and the other tabs still inherit
        // the extra space without re-layout.
        .frame(width: 720, height: 520)
    }
}

private struct EditorSettingsPane: View {
    @Environment(\.appTheme) private var appTheme
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
                        Text(SettingsPresentation.fontSizeSummary(points: Int(prefs.fontSize)))
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
                        Text(SettingsPresentation.tabWidthSummary(spaces: prefs.tabWidth))
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
                Toggle(isOn: $prefs.inlineColorSwatchesEnabled) {
                    Text("settings.display.colorSwatches", bundle: .module)
                }
            } header: {
                Text("settings.section.display", bundle: .module)
            } footer: {
                Text("settings.display.colorSwatchesFooter", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
            }

            Section {
                Picker(selection: $prefs.inlineBlameMode) {
                    ForEach(InlineBlameMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.titleKey), bundle: .module)
                            .tag(mode)
                    }
                } label: {
                    Text("settings.inlineBlame.mode", bundle: .module)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("settings.inlineBlame.section", bundle: .module)
            } footer: {
                Text("settings.inlineBlame.footer", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
            }

            Section {
                HStack {
                    Text(SettingsPresentation.recentFilesSummary(
                        count: prefs.recentFiles.count,
                        maxCount: EditorPreferences.recentFilesMax
                    ))
                        .foregroundStyle(appTheme.secondaryText)
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
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var prefs: EditorPreferences

    var body: some View {
        Form {
            Section {
                // Phase 36 — global UI theme. Drives sidebar /
                // status bar / panel chrome via `\.appTheme`.
                Picker(selection: $prefs.uiThemeID) {
                    ForEach(ThemeID.allCases) { id in
                        Text(id.displayName).tag(id)
                    }
                } label: {
                    Text("settings.appearance.ui.title", bundle: .module)
                }
                .pickerStyle(.menu)

                // Toggle decouples the editor from the UI theme.
                // Default: on (one theme drives everything).
                Toggle(isOn: $prefs.editorFollowsUITheme) {
                    Text("settings.appearance.editor.follow", bundle: .module)
                }

                // Editor-specific picker. Writes only to
                // `editorThemeID`; when "follow" is on the picker is
                // disabled and shows the UI theme instead, so users
                // see what's actually painting the editor.
                Picker(selection: editorThemeBinding) {
                    ForEach(ThemeID.allCases) { id in
                        Text(id.displayName).tag(id)
                    }
                } label: {
                    Text("settings.appearance.editor.title", bundle: .module)
                }
                .pickerStyle(.menu)
                .disabled(prefs.editorFollowsUITheme)
            } header: {
                Text("settings.appearance.section.theme", bundle: .module)
            } footer: {
                Text("settings.appearance.themeFooter", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
            }

            // Live preview: sidebar mock (left) + editor mock (right).
            // Both update on any of: uiThemeID change, editorThemeID
            // change, follow toggle, or system Light/Dark flip.
            // Phase 39b — overrides are applied here too so the
            // preview matches what ThemeHost / Coordinator+Theme
            // will paint once the user closes Settings.
            Section {
                ThemePreviewSwatch(
                    uiTheme: prefs.uiThemeID
                        .resolve(appearance: NSApp.effectiveAppearance)
                        .applying(prefs.overrides(for: prefs.uiThemeID)),
                    editorTheme: prefs.effectiveEditorThemeID
                        .resolve(appearance: NSApp.effectiveAppearance)
                        .applying(prefs.overrides(for: prefs.effectiveEditorThemeID))
                )
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(appTheme.separator.opacity(0.5),
                                          lineWidth: 0.5)
                    )
            } header: {
                Text("settings.appearance.preview", bundle: .module)
            }

            // Phase 39b — per-slot customization. Two collapsed
            // disclosures: editor (13 syntax/document slots) on
            // top of UI chrome (11 surface slots). Each slot has
            // its own ColorPicker + per-slot Reset; section footer
            // carries the "Reset all colors for this theme" action.
            ThemeCustomizationSection(prefs: prefs)
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }

    /// Show `uiThemeID` in the disabled-state picker (so users see
    /// what's painting), but only ever write to `editorThemeID`.
    private var editorThemeBinding: Binding<ThemeID> {
        Binding(
            get: { prefs.editorFollowsUITheme ? prefs.uiThemeID : prefs.editorThemeID },
            set: { prefs.editorThemeID = $0 }
        )
    }
}

/// Phase 39b — per-slot color customization for the active theme(s).
///
/// Layout: two collapsed `DisclosureGroup`s, one per `SlotCategory`,
/// each emitting one row per slot (label + ColorPicker + per-slot
/// reset). A footer row carries the "reset all colors for this
/// theme" actions.
///
/// Routing: when `editorFollowsUITheme = true`, both the editor
/// AND ui slot rows write into the *same* override map (the UI
/// theme's), because the editor is just mirroring it. When
/// decoupled, editor slots target `editorThemeID`'s map and UI
/// slots target `uiThemeID`'s — the headers spell out which theme
/// each disclosure is currently editing so the user isn't guessing.
private struct ThemeCustomizationSection: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var prefs: EditorPreferences

    var body: some View {
        Section {
            // Targeted-theme headers — show what each disclosure
            // is editing into, so the user knows their pink Accent
            // pick is going into Inkwell vs Daylight (etc.).
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("settings.appearance.customize.editingUI",
                            prefs.uiThemeID.displayName))
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
                if prefs.editorFollowsUITheme {
                    Text(L10n.t("settings.appearance.customize.editingEditor",
                                prefs.uiThemeID.displayName)
                         + " "
                         + L10n.t("settings.appearance.customize.followsUI"))
                        .font(.caption)
                        .foregroundStyle(appTheme.secondaryText)
                } else {
                    Text(L10n.t("settings.appearance.customize.editingEditor",
                                prefs.editorThemeID.displayName))
                        .font(.caption)
                        .foregroundStyle(appTheme.secondaryText)
                }
            }

            DisclosureGroup {
                ForEach(ThemeSlot.slots(in: .editor), id: \.self) { slot in
                    SlotRow(prefs: prefs, slot: slot,
                            themeID: editorTargetID)
                }
            } label: {
                Text("settings.appearance.customize.editor", bundle: .module)
                    .font(.callout)
            }

            DisclosureGroup {
                ForEach(ThemeSlot.slots(in: .ui), id: \.self) { slot in
                    SlotRow(prefs: prefs, slot: slot,
                            themeID: uiTargetID)
                }
            } label: {
                Text("settings.appearance.customize.ui", bundle: .module)
                    .font(.callout)
            }
        } header: {
            Text("settings.appearance.section.customize", bundle: .module)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        prefs.clearAllOverrides(uiTargetID)
                    } label: {
                        Text("settings.appearance.customize.resetAllUI",
                             bundle: .module)
                    }
                    .disabled(prefs.overrides(for: uiTargetID).isEmpty)

                    Spacer()

                    Button {
                        prefs.clearAllOverrides(editorTargetID)
                    } label: {
                        Text("settings.appearance.customize.resetAllEditor",
                             bundle: .module)
                    }
                    .disabled(prefs.overrides(for: editorTargetID).isEmpty
                              || (prefs.editorFollowsUITheme
                                  && editorTargetID == uiTargetID))
                }

                // Phase 61 — Theme bundle import/export. Operates
                // on the *UI* theme target by convention; with
                // "editor follows UI theme" on (the default), the
                // export captures both surfaces. Power users who
                // decoupled get an explicit picker row in a future
                // 61b iteration.
                HStack {
                    Button {
                        exportTheme(themeID: uiTargetID)
                    } label: {
                        Text("settings.appearance.customize.export",
                             bundle: .module)
                    }

                    Button {
                        importTheme()
                    } label: {
                        Text("settings.appearance.customize.import",
                             bundle: .module)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Phase 61 — Import / Export

    /// Snapshot the current overrides for `themeID` into a
    /// `.scribetheme` JSON file via NSSavePanel. Errors print to
    /// stderr (cheap because Settings is modal); no toast surface
    /// is reachable from inside a Settings tab.
    private func exportTheme(themeID: ThemeID) {
        let overrides = prefs.overrides(for: themeID)
        guard let data = try? ThemeBundleIO.encode(themeID: themeID,
                                                   overrides: overrides) else {
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(themeID.rawValue).scribetheme"
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Read a `.scribetheme` file via NSOpenPanel and *replace*
    /// the targeted theme's overrides with its contents. We use
    /// `replaceOverrides` rather than per-slot `setOverride` so
    /// a partial-failure decode can't leave the user with a
    /// half-applied colour set; the bundle either lands in full
    /// or not at all.
    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK,
              let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        guard let result = try? ThemeBundleIO.decode(data) else { return }
        prefs.replaceOverrides(result.themeID, with: result.overrides)
    }

    /// The theme ID whose override map UI-chrome slots should
    /// write into. Always `uiThemeID`.
    private var uiTargetID: ThemeID { prefs.uiThemeID }

    /// The theme ID whose override map editor slots should write
    /// into. Mirrors `effectiveEditorThemeID` so the row matches
    /// what's actually painted.
    private var editorTargetID: ThemeID { prefs.effectiveEditorThemeID }
}

/// One slot row inside a `DisclosureGroup`. Shows the localized
/// slot name + a SwiftUI `ColorPicker` bound to the *resolved*
/// colour (override-or-base) + a Reset button visible only when
/// this slot currently carries an override.
///
/// SwiftUI `ColorPicker` is preferred over `NSColorWell` because
/// (1) it's Swift 6 / Sendable clean, (2) it sidesteps the
/// `NSColorPanel.shared` cross-well coordination bug, and (3) it
/// requires zero `NSViewRepresentable` boilerplate.
private struct SlotRow: View {
    @ObservedObject var prefs: EditorPreferences
    let slot: ThemeSlot
    let themeID: ThemeID

    var body: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(slot.displayKey), bundle: .module)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)

            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)

            Button {
                prefs.clearOverride(themeID, slot: slot)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("settings.appearance.customize.reset"))
            .disabled(!hasOverride)
            .opacity(hasOverride ? 1 : 0.35)
        }
        .padding(.vertical, 1)
    }

    /// True when this slot currently has an override on the active
    /// target theme. Drives Reset-button visibility/enablement.
    private var hasOverride: Bool {
        prefs.overrides(for: themeID).slots[slot] != nil
    }

    /// Two-way binding between the resolved colour and the
    /// override map. Reads return overridden value if set, else
    /// the base theme's value. Writes go through `setOverride`
    /// which performs copy-mutate-assign so `@Published` fires.
    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let appearance = NSApp.effectiveAppearance
                let base = themeID.resolve(appearance: appearance)
                let resolved = base.applying(prefs.overrides(for: themeID))
                return Color(rgb: resolved.value(for: slot))
            },
            set: { newColor in
                guard let rgb = newColor.toRGBInt() else { return }
                prefs.setOverride(themeID, slot: slot, color: rgb)
            }
        )
    }
}

/// Phase 39b — `Color` → 0xRRGGBB Int. Returns nil only when the
/// underlying NSColor refuses to project into sRGB (extremely rare
/// — most system / P3 colours convert cleanly via `usingColorSpace`).
/// Caller pattern: `guard let rgb = color.toRGBInt() else { return }`
/// — silently keep current value rather than write garbage.
private extension Color {
    func toRGBInt() -> Int? {
        let nsColor = NSColor(self)
        guard let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent   * 255).rounded()) & 0xFF
        let g = Int((srgb.greenComponent * 255).rounded()) & 0xFF
        let b = Int((srgb.blueComponent  * 255).rounded()) & 0xFF
        return (r << 16) | (g << 8) | b
    }
}

/// Phase 36 — split mock-up: a stylised sidebar (using the UI
/// theme's `ui*` chrome colours) and a stylised code block (using
/// the editor theme's syntax colours). Renders both halves at the
/// same time so the user sees how their two picks combine before
/// committing. Theme values are 0xRRGGBB Ints; `Color(rgb:)`
/// (Models/AppTheme.swift) unpacks them.
private struct ThemePreviewSwatch: View {
    let uiTheme: Theme
    let editorTheme: Theme

    var body: some View {
        HStack(spacing: 0) {
            sidebarMock
                .frame(width: 110)
            editorMock
        }
    }

    @ViewBuilder
    private var sidebarMock: some View {
        ZStack(alignment: .topLeading) {
            Color(rgb: uiTheme.uiSidebarBackground)
            VStack(alignment: .leading, spacing: 4) {
                Text("settings.appearance.preview.sidebar", bundle: .module)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(rgb: uiTheme.uiSecondaryText))
                    .padding(.bottom, 2)
                sidebarRow("Files", selected: false)
                sidebarRow("greet.swift", selected: true)
                sidebarRow("README.md", selected: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
    }

    private func sidebarRow(_ text: String, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 10))
            Spacer()
        }
        .foregroundStyle(
            selected
                ? Color(rgb: uiTheme.uiAccentText)
                : Color(rgb: uiTheme.uiPrimaryText)
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(selected ? Color(rgb: uiTheme.uiAccent) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    @ViewBuilder
    private var editorMock: some View {
        ZStack(alignment: .topLeading) {
            Color(rgb: editorTheme.background)
            VStack(alignment: .leading, spacing: 4) {
                Text("settings.appearance.preview.editor", bundle: .module)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(rgb: editorTheme.marginForeground))
                    .padding(.bottom, 2)
                row(text: "func greet(name) {", tint: editorTheme.keyword)
                row(text: "    return \"Hello\"", tint: editorTheme.string)
                row(text: "    // welcome", tint: editorTheme.comment)
                row(text: "}", tint: editorTheme.foreground)
                Spacer(minLength: 0)
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

// `Color(rgb:)` lives in Models/AppTheme.swift now (Phase 36) — every
// chrome surface needs it, so the helper is internal-scoped.

/// Phase 33 — Snippets settings tab. Two-pane layout: a list of
/// snippet names on the left, an editor form on the right that
/// pushes every keystroke through `catalog.update(_:)` so the JSON
/// store on disk stays in lock-step with the UI.
private struct SnippetsSettingsPane: View {
    @Environment(\.appTheme) private var appTheme
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
                .background(appTheme.windowBackground)
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
                    .foregroundStyle(appTheme.secondaryText)
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
                                    .foregroundStyle(appTheme.secondaryText)
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
                .foregroundStyle(appTheme.secondaryText)
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
    @Environment(\.appTheme) private var appTheme
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
                    .foregroundStyle(appTheme.secondaryText)
                TextEditor(text: $snippet.body)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(appTheme.separator
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
                .foregroundStyle(appTheme.secondaryText)
            TextField(L10n.t(placeholder), text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// Phase 67 — clipboard history retention controls. Small,
/// dedicated tab because the three knobs all share one privacy
/// story: nothing leaves memory unless the user explicitly opts
/// in, and even after they do, the on-disk JSON is bounded by an
/// item count and a TTL. Each control writes straight through
/// `EditorPreferences`; the live store reacts via the
/// `.onChange(of: prefs.clipboardHistory*)` hooks in `ScribeApp`.
private struct ClipboardSettingsPane: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var prefs: EditorPreferences

    /// SwiftUI's `@ViewBuilder` Form/Section bodies don't accept
    /// stray `let` bindings, so the Stepper bounds live as
    /// computed properties. Both ranges are also referenced from
    /// tests (Phase 67e) to assert the slider matches the policy
    /// clamp.
    private var maxItemsBounds: ClosedRange<Int> {
        ClipboardHistoryPolicy.maxItemsMin...ClipboardHistoryPolicy.maxItemsMax
    }
    private var retentionDaysBounds: ClosedRange<Int> {
        ClipboardHistoryPolicy.retentionDaysMin...ClipboardHistoryPolicy.retentionDaysMax
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $prefs.clipboardHistoryPersistEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.clipboard.persist.title", bundle: .module)
                        Text("settings.clipboard.persist.help", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(appTheme.secondaryText)
                    }
                }
            } header: {
                Text("settings.clipboard.section.persistence", bundle: .module)
            }

            Section {
                HStack {
                    Text("settings.clipboard.maxItems.label", bundle: .module)
                    Spacer()
                    Stepper(value: $prefs.clipboardHistoryMaxItems,
                            in: maxItemsBounds,
                            step: 10,
                            label: {
                                Text(verbatim: "\(prefs.clipboardHistoryMaxItems)")
                                    .monospacedDigit()
                                    .frame(minWidth: 48, alignment: .trailing)
                            })
                }
                HStack {
                    Text("settings.clipboard.retention.label", bundle: .module)
                    Spacer()
                    Stepper(value: $prefs.clipboardHistoryRetentionDays,
                            in: retentionDaysBounds,
                            step: 1,
                            label: {
                                Text(retentionSummary(prefs.clipboardHistoryRetentionDays))
                                    .monospacedDigit()
                                    .frame(minWidth: 96, alignment: .trailing)
                            })
                }
                Text("settings.clipboard.retention.help", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
            } header: {
                Text("settings.clipboard.section.retention", bundle: .module)
            }
        }
        .formStyle(.grouped)
    }

    /// Human-readable summary for the retention stepper. `0 ⇒
    /// "永久"` so the user never has to second-guess what zero
    /// means; positive values render as "N 天" / "N day(s)".
    private func retentionSummary(_ days: Int) -> String {
        if days <= 0 {
            return String(localized: "settings.clipboard.retention.forever",
                          bundle: .module)
        }
        let format = String(localized: "settings.clipboard.retention.days",
                            bundle: .module)
        return String(format: format, days)
    }
}

/// Phase 69 — auto-save scratch / crash recovery pane. Three
/// knobs that all share the same privacy story as the clipboard
/// pane: nothing leaves memory unless the user explicitly opts
/// in, and the on-disk catalogue is bounded by both a debounce
/// window and a retention TTL. Each control writes straight
/// through `EditorPreferences`; the live `Workspace` reads its
/// debounce window on every per-doc sink construction so a Tab
/// switch picks up the new value immediately.
private struct AutoSaveSettingsPane: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var prefs: EditorPreferences

    private var debounceBounds: ClosedRange<Double> { 0.5...60 }
    private var retentionBounds: ClosedRange<Int> { 0...365 }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $prefs.autoSaveScratchEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.autoSave.enabled.title", bundle: .module)
                        Text("settings.autoSave.enabled.help", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(appTheme.secondaryText)
                    }
                }
            } header: {
                Text("settings.autoSave.section.scratch", bundle: .module)
            }

            Section {
                HStack {
                    Text("settings.autoSave.debounce.label", bundle: .module)
                    Spacer()
                    Stepper(value: $prefs.autoSaveScratchDebounceSeconds,
                            in: debounceBounds,
                            step: 0.5,
                            label: {
                                Text(debounceSummary(prefs.autoSaveScratchDebounceSeconds))
                                    .monospacedDigit()
                                    .frame(minWidth: 80, alignment: .trailing)
                            })
                }
                .disabled(!prefs.autoSaveScratchEnabled)

                HStack {
                    Text("settings.autoSave.retention.label", bundle: .module)
                    Spacer()
                    Stepper(value: $prefs.autoSaveScratchRetentionDays,
                            in: retentionBounds,
                            step: 1,
                            label: {
                                Text(retentionSummary(prefs.autoSaveScratchRetentionDays))
                                    .monospacedDigit()
                                    .frame(minWidth: 96, alignment: .trailing)
                            })
                }
                .disabled(!prefs.autoSaveScratchEnabled)

                Text("settings.autoSave.retention.help", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
            } header: {
                Text("settings.autoSave.section.retention", bundle: .module)
            }
        }
        .formStyle(.grouped)
    }

    private func debounceSummary(_ seconds: Double) -> String {
        let format = String(localized: "settings.autoSave.debounce.seconds",
                            bundle: .module)
        return String(format: format, seconds)
    }

    private func retentionSummary(_ days: Int) -> String {
        if days <= 0 {
            return String(localized: "settings.autoSave.retention.forever",
                          bundle: .module)
        }
        let format = String(localized: "settings.autoSave.retention.days",
                            bundle: .module)
        return String(format: format, days)
    }
}

private struct AboutPane: View {
    @Environment(\.appTheme) private var appTheme
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
                    .foregroundStyle(appTheme.secondaryText)
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
