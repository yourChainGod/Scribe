//
//  JWTDecoderSheet.swift
//  Phase 41a — JWT inspector sheet. Two-pane layout: the input
//  field on top (token), the decoded header / payload / signature
//  panes below. Read-only — does not verify the signature.
//
//  Mounted via `Workspace.jwtSheet`. Pre-fills with the active
//  text selection if it looks like a JWT, otherwise opens empty
//  so the user can paste.
//

import SwiftUI
import AppKit

/// Sheet request payload — `Identifiable` for `.sheet(item:)`.
struct JWTSheetRequest: Identifiable, Equatable {
    let id: UUID
    var prefill: String

    init(prefill: String, id: UUID = UUID()) {
        self.prefill = prefill
        self.id = id
    }
}

struct JWTDecoderSheet: View {
    let request: JWTSheetRequest
    let onClose: () -> Void

    @State private var token: String
    @State private var decoded: JWTDecoded?
    @State private var errorMessage: String?

    @Environment(\.appTheme) private var appTheme

    init(request: JWTSheetRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        // Prefill with the selection if it parses; otherwise
        // leave it raw so the user can hand-edit.
        _token = State(initialValue: request.prefill)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            tokenEditor
            Divider()
            if let decoded {
                decodedPanes(decoded)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12))
            } else {
                Label {
                    Text("jwt.placeholder", bundle: .module)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .onAppear { reparse() }
        .onChange(of: token) { _, _ in reparse() }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .center) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("jwt.title", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                Text("jwt.subtitle", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var tokenEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("jwt.input.label", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextEditor(text: $token)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 88)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(rgb: appTheme.editor.background).opacity(0.5))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                }
                .scrollContentBackground(.hidden)
        }
    }

    private func decodedPanes(_ d: JWTDecoded) -> some View {
        HStack(alignment: .top, spacing: 12) {
            decodedPane(titleKey: "jwt.section.header",
                        body: d.header,
                        tint: .red)
            decodedPane(titleKey: "jwt.section.payload",
                        body: d.payload,
                        tint: .purple)
            decodedPane(titleKey: "jwt.section.signature",
                        body: d.signature,
                        tint: .blue)
        }
        .frame(maxHeight: .infinity)
    }

    private func decodedPane(titleKey: LocalizedStringKey,
                             body: String,
                             tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(titleKey, bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("jwt.copy.help", bundle: .module))
            }
            ScrollView {
                Text(body)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tint.opacity(0.20), lineWidth: 0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                onClose()
            } label: {
                Text("common.close", bundle: .module)
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Logic

    private func reparse() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            decoded = nil
            errorMessage = nil
            return
        }
        do {
            decoded = try JWTDecoder.decode(trimmed)
            errorMessage = nil
        } catch let err as JWTDecodeError {
            decoded = nil
            errorMessage = errorDescription(err)
        } catch {
            decoded = nil
            errorMessage = error.localizedDescription
        }
    }

    private func errorDescription(_ err: JWTDecodeError) -> String {
        switch err {
        case .malformed:
            return L10n.t("jwt.error.malformed")
        case .invalidBase64(let seg):
            return L10n.t("jwt.error.invalidBase64", seg.rawValue as NSString)
        case .invalidUTF8(let seg):
            return L10n.t("jwt.error.invalidUTF8", seg.rawValue as NSString)
        }
    }
}
