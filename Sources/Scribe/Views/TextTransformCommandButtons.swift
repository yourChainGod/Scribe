//
//  TextTransformCommandButtons.swift
//  Phase 37 — shared menu content for selection text transforms.
//

import AppKit
import SwiftUI

struct TextTransformCommandButtons: View {
    @ObservedObject var findState: FindState

    var body: some View {
        Button {
            send(.urlEncode)
        } label: {
            Text("transform.url.encode", bundle: .module)
        }
        Button {
            send(.urlDecode)
        } label: {
            Text("transform.url.decode", bundle: .module)
        }
        Divider()
        Button {
            send(.base64Encode)
        } label: {
            Text("transform.base64.encode", bundle: .module)
        }
        Button {
            send(.base64Decode)
        } label: {
            Text("transform.base64.decode", bundle: .module)
        }
        Divider()
        Button {
            send(.htmlEscape)
        } label: {
            Text("transform.html.escape", bundle: .module)
        }
        Button {
            send(.htmlUnescape)
        } label: {
            Text("transform.html.unescape", bundle: .module)
        }
        Button {
            send(.jsonStringEscape)
        } label: {
            Text("transform.json.escape", bundle: .module)
        }
        Button {
            send(.jsonStringUnescape)
        } label: {
            Text("transform.json.unescape", bundle: .module)
        }
        Divider()
        Menu {
            Button {
                send(.convertBase(fromBase: 2, toBase: 10))
            } label: {
                Text("transform.base.binaryToDecimal", bundle: .module)
            }
            Button {
                send(.convertBase(fromBase: 10, toBase: 2))
            } label: {
                Text("transform.base.decimalToBinary", bundle: .module)
            }
            Button {
                send(.convertBase(fromBase: 8, toBase: 10))
            } label: {
                Text("transform.base.octalToDecimal", bundle: .module)
            }
            Button {
                send(.convertBase(fromBase: 10, toBase: 8))
            } label: {
                Text("transform.base.decimalToOctal", bundle: .module)
            }
            Button {
                send(.convertBase(fromBase: 16, toBase: 10))
            } label: {
                Text("transform.base.hexToDecimal", bundle: .module)
            }
            Button {
                send(.convertBase(fromBase: 10, toBase: 16))
            } label: {
                Text("transform.base.decimalToHex", bundle: .module)
            }
        } label: {
            Text("transform.base.menu", bundle: .module)
        }
        Divider()
        Menu {
            Button {
                sendPasswordAction(encrypt: true)
            } label: {
                Text("transform.crypto.encryptAESGCM", bundle: .module)
            }
            Button {
                sendPasswordAction(encrypt: false)
            } label: {
                Text("transform.crypto.decryptAESGCM", bundle: .module)
            }
        } label: {
            Text("transform.crypto.menu", bundle: .module)
        }
        Divider()
        Button {
            send(.shuffleLines(seed: UInt64.random(in: UInt64.min...UInt64.max)))
        } label: {
            Text("transform.lines.shuffle", bundle: .module)
        }
    }

    @MainActor
    private func send(_ action: TextTransformAction) {
        findState.commands.send(.transformSelection(action))
    }

    @MainActor
    private func sendPasswordAction(encrypt: Bool) {
        let titleKey = encrypt
            ? "transform.crypto.password.title.encrypt"
            : "transform.crypto.password.title.decrypt"
        guard let password = TextTransformPasswordPrompt.request(
            title: L10n.t(titleKey),
            message: L10n.t("transform.crypto.password.message")
        ) else { return }
        send(encrypt ? .aesGCMEncrypt(password: password) : .aesGCMDecrypt(password: password))
    }
}

private enum TextTransformPasswordPrompt {
    @MainActor
    static func request(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("common.cancel"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = L10n.t("transform.crypto.password.placeholder")
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let password = field.stringValue
        return password.isEmpty ? nil : password
    }
}
