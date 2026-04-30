//
//  RegexPlaygroundSheet.swift
//  Phase 41e — interactive regex tester. Three panes:
//    1. Pattern + flags (caseInsensitive / multiline / dotAll /
//       allowComments) and a replacement template.
//    2. Subject text (multiline editor).
//    3. Output: highlighted matches inside the subject + a
//       capture-group table per match + a live replace preview.
//
//  Re-evaluation runs on every change to pattern / subject / flags /
//  template, all on the main thread. NSRegularExpression compiles
//  for free at the scales a "playground" sheet operates on; we
//  don't need a debounce.
//

import AppKit
import SwiftUI

struct RegexSheetRequest: Identifiable, Equatable {
    let id: UUID
    var prefillSubject: String

    init(prefillSubject: String, id: UUID = UUID()) {
        self.prefillSubject = prefillSubject
        self.id = id
    }
}

struct RegexPlaygroundSheet: View {
    let request: RegexSheetRequest
    let onClose: () -> Void

    @State private var pattern: String = ""
    @State private var subject: String
    @State private var template: String = ""
    @State private var options = RegexPlayground.Options()
    @State private var matches: [RegexPlayground.Match] = []
    @State private var replacementPreview: String = ""
    @State private var errorMessage: String?

    init(request: RegexSheetRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _subject = State(initialValue: request.prefillSubject)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("regex.sheet.title", bundle: .module)
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Text("button.close", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
            }

            patternRow

            flagsRow

            HStack(alignment: .top, spacing: 12) {
                subjectColumn
                outputColumn
            }
            .frame(minHeight: 280)

            replaceSection

            statusRow
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .onAppear { recompute() }
        .onChange(of: pattern)  { _, _ in recompute() }
        .onChange(of: subject)  { _, _ in recompute() }
        .onChange(of: template) { _, _ in recompute() }
        .onChange(of: options)  { _, _ in recompute() }
    }

    // MARK: - Subviews

    private var patternRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("regex.pattern", bundle: .module).font(.subheadline)
            TextField("", text: $pattern, prompt: Text("regex.pattern.placeholder",
                                                       bundle: .module))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var flagsRow: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $options.caseInsensitive) {
                Text("regex.flag.caseInsensitive", bundle: .module)
            }
            Toggle(isOn: $options.multiline) {
                Text("regex.flag.multiline", bundle: .module)
            }
            Toggle(isOn: $options.dotAll) {
                Text("regex.flag.dotAll", bundle: .module)
            }
            Toggle(isOn: $options.allowComments) {
                Text("regex.flag.allowComments", bundle: .module)
            }
            Spacer()
        }
        .toggleStyle(.checkbox)
    }

    private var subjectColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("regex.subject", bundle: .module).font(.subheadline)
            TextEditor(text: $subject)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
    }

    private var outputColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("regex.matches", bundle: .module).font(.subheadline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if matches.isEmpty {
                        Text("regex.matches.none", bundle: .module)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(matches.indices, id: \.self) { idx in
                            matchRow(idx: idx, match: matches[idx])
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor))
            .border(Color.secondary.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
    }

    private func matchRow(idx: Int, match: RegexPlayground.Match) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(idx + 1)").bold()
                    .frame(width: 22, alignment: .trailing)
                Text(verbatim: match.value)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 4)
                    .background(Color.yellow.opacity(0.4))
                Spacer()
                Text(verbatim: "[\(match.range.location), \(match.range.length)]")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if match.groups.count > 1 {
                ForEach(1..<match.groups.count, id: \.self) { gi in
                    HStack {
                        Text(verbatim: "$\(gi)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 22, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text(verbatim: match.groups[gi] ?? "—")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
    }

    private var replaceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("regex.replace.template", bundle: .module).font(.subheadline)
            TextField("", text: $template, prompt: Text("regex.replace.placeholder",
                                                        bundle: .module))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Text("regex.replace.preview", bundle: .module).font(.subheadline)
            ScrollView {
                Text(verbatim: replacementPreview.isEmpty ? " " : replacementPreview)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 64, maxHeight: 96)
            .background(Color(NSColor.textBackgroundColor))
            .border(Color.secondary.opacity(0.3))
        }
    }

    private var statusRow: some View {
        HStack {
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(L10n.t("regex.status.matchCount", matches.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func recompute() {
        do {
            matches = try RegexPlayground.matches(in: subject,
                                                  pattern: pattern,
                                                  options: options)
            replacementPreview = template.isEmpty
                ? subject
                : (try RegexPlayground.replace(in: subject,
                                               pattern: pattern,
                                               template: template,
                                               options: options))
            errorMessage = nil
        } catch let RegexPlayground.RegexError.invalidPattern(reason) {
            matches = []
            replacementPreview = ""
            errorMessage = reason
        } catch {
            matches = []
            replacementPreview = ""
            errorMessage = error.localizedDescription
        }
    }
}
