//
//  TextTransformCommandButtons.swift
//  Phase 37 — shared menu content for selection text transforms.
//

import AppKit
import SwiftUI

struct TextTransformCommandButtons: View {
    @ObservedObject var findState: FindState
    /// Phase 41a — JWT decoder + future encode/hash actions that
    /// raise sheets need a workspace handle. Optional so legacy
    /// callers that haven't updated yet keep compiling; the JWT
    /// menu item silently no-ops if it's nil (which can only happen
    /// in tests / detached previews).
    var workspace: Workspace?
    /// Phase 41d — Line Ops submenu reads `prefs.tabWidth` for the
    /// tabs/spaces converters. Optional for the same reason as
    /// `workspace`.
    var prefs: EditorPreferences?

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
        // Phase 41a — Hash submenu. Replaces the selection with the
        // lowercase hex digest of the UTF-8 bytes. MD5 / SHA-1 are
        // kept around for ETag / checksum use (cryptographically
        // broken — labelled as such in the menu); SHA-256 / SHA-512
        // are the safe defaults; CRC32 matches zlib so users can
        // cross-check against `python -c "zlib.crc32(...)"`.
        Divider()
        Menu {
            Button {
                send(.md5)
            } label: {
                Text("transform.hash.md5", bundle: .module)
            }
            Button {
                send(.sha1)
            } label: {
                Text("transform.hash.sha1", bundle: .module)
            }
            Button {
                send(.sha256)
            } label: {
                Text("transform.hash.sha256", bundle: .module)
            }
            Button {
                send(.sha512)
            } label: {
                Text("transform.hash.sha512", bundle: .module)
            }
            Button {
                send(.crc32)
            } label: {
                Text("transform.hash.crc32", bundle: .module)
            }
        } label: {
            Text("transform.hash.menu", bundle: .module)
        }
        // Phase 41a — JWT decoder pops a sheet pre-filled with the
        // current selection (if any). Read-only inspector — does
        // NOT verify the signature; that's a server-side concern.
        if workspace != nil {
            Button {
                presentJWTDecoder()
            } label: {
                Text("transform.jwt.decode", bundle: .module)
            }
        }
        // Phase 41d — Line Ops submenu. Surfaces the same actions
        // the Tools ▶ Line Ops menu owns; mirrors the right-click
        // muscle memory editors like BBEdit / Sublime have for
        // sort-line / dedupe / case toggles.
        if let prefs {
            Divider()
            Menu {
                LineOpsCommandButtons(findState: findState, prefs: prefs)
            } label: {
                Text("lineops.menu", bundle: .module)
            }
        }
        // Phase 41c — Format / Minify nested by language. Same
        // shape as Tools ▸ Format so the user can reach it via
        // right-click without leaving the editor.
        Menu {
            CodeFormatCommandButtons(findState: findState)
        } label: {
            Text("format.menu", bundle: .module)
        }
    }

    @MainActor
    private func presentJWTDecoder() {
        guard let workspace else { return }
        let prefill = workspace.activeTextSelection
        workspace.jwtSheet = JWTSheetRequest(prefill: prefill)
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
