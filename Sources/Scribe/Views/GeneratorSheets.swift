//
//  GeneratorSheets.swift
//  Phase 41b — Sheet UIs for parameterised generators (Password,
//  QR Code). UUID / Lorem / Timestamp don't need a sheet; they
//  insert directly from the menu.
//

import SwiftUI

// MARK: - Sheet request payloads

/// `.sheet(item:)` payload for the password generator.
struct PasswordSheetRequest: Identifiable, Equatable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

/// `.sheet(item:)` payload for the QR code generator.
struct QRSheetRequest: Identifiable, Equatable {
    let id: UUID
    /// Selection contents at invocation time so the sheet pre-fills
    /// with whatever the user had highlighted, mirroring the JWT
    /// decoder's UX.
    var prefill: String

    init(prefill: String, id: UUID = UUID()) {
        self.prefill = prefill
        self.id = id
    }
}

// MARK: - Password sheet

struct PasswordGeneratorSheet: View {
    let request: PasswordSheetRequest
    let onInsert: (String) -> Void
    let onClose: () -> Void

    @State private var options = Generators.PasswordOptions()
    @State private var preview: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("generator.password.title", bundle: .module)
                .font(.headline)

            HStack {
                Text("generator.password.length", bundle: .module)
                Spacer(minLength: 16)
                Stepper(value: $options.length, in: 4...128) {
                    Text(verbatim: "\(options.length)")
                        .monospacedDigit()
                        .frame(minWidth: 32, alignment: .trailing)
                }
                .labelsHidden()
            }

            Toggle(isOn: $options.includeLowercase) {
                Text("generator.password.lowercase", bundle: .module)
            }
            Toggle(isOn: $options.includeUppercase) {
                Text("generator.password.uppercase", bundle: .module)
            }
            Toggle(isOn: $options.includeDigits) {
                Text("generator.password.digits", bundle: .module)
            }
            Toggle(isOn: $options.includeSymbols) {
                Text("generator.password.symbols", bundle: .module)
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("generator.password.preview", bundle: .module)
                Spacer(minLength: 12)
                Text(verbatim: preview.isEmpty ? "—" : preview)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button {
                regenerate()
            } label: {
                Text("generator.password.regenerate", bundle: .module)
            }

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(role: .cancel, action: onClose) {
                    Text("button.cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    if !preview.isEmpty {
                        onInsert(preview)
                    }
                } label: {
                    Text("generator.password.insert", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { regenerate() }
    }

    private func regenerate() {
        do {
            preview = try Generators.password(options: options)
            errorMessage = nil
        } catch let Generators.GenError.invalid(reason) {
            preview = ""
            errorMessage = reason
        } catch {
            preview = ""
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - QR sheet

struct QRCodeGeneratorSheet: View {
    let request: QRSheetRequest
    let onInsert: (String) -> Void
    let onClose: () -> Void

    @State private var payload: String
    @State private var ascii: String = ""
    @State private var errorMessage: String?

    init(request: QRSheetRequest,
         onInsert: @escaping (String) -> Void,
         onClose: @escaping () -> Void)
    {
        self.request = request
        self.onInsert = onInsert
        self.onClose = onClose
        _payload = State(initialValue: request.prefill)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("generator.qr.title", bundle: .module)
                .font(.headline)

            Text("generator.qr.payload", bundle: .module)
                .font(.subheadline)
            TextEditor(text: $payload)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 64, maxHeight: 96)
                .border(Color.secondary.opacity(0.4))

            HStack {
                Button {
                    regenerate()
                } label: {
                    Text("generator.qr.regenerate", bundle: .module)
                }
                Spacer()
                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: ascii.isEmpty ? "—" : ascii)
                    .font(.system(size: 9, design: .monospaced))
                    .lineSpacing(0)
                    .padding(8)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 220, maxHeight: 320)
            .background(Color(NSColor.textBackgroundColor))
            .border(Color.secondary.opacity(0.3))

            HStack {
                Spacer()
                Button(role: .cancel, action: onClose) {
                    Text("button.cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    if !ascii.isEmpty {
                        onInsert(ascii)
                    }
                } label: {
                    Text("generator.qr.insert", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ascii.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { regenerate() }
        .onChange(of: payload) { _, _ in regenerate() }
    }

    private func regenerate() {
        guard !payload.isEmpty else {
            ascii = ""
            errorMessage = nil
            return
        }
        do {
            ascii = try Generators.qrASCII(payload: payload)
            errorMessage = nil
        } catch let Generators.GenError.invalid(reason) {
            ascii = ""
            errorMessage = reason
        } catch {
            ascii = ""
            errorMessage = error.localizedDescription
        }
    }
}
