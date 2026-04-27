//
//  LexerCatalog.swift
//  Maps file extensions to Lexilla lexer names and exposes the keyword
//  lists Scintilla expects via SCI_SETKEYWORDS. Phase 1.8 keeps the set
//  small (cpp / swift / python / json / md / sh / xml / html / js / ts);
//  the underlying Lexilla static library carries 100+ lexers — we just
//  haven't wired the rest up yet.
//

import Foundation

/// A description of one supported language. `lexillaName` is the string
/// passed to `LexillaBridgeCreateLexer`; if Lexilla doesn't recognise it,
/// the editor falls back to the null lexer.
struct LexerDescriptor: Sendable {
    /// Display name shown in the status bar (e.g. "C++", "Swift").
    let display: String
    /// Name accepted by `Lexilla::CreateLexer`. Empty string ⇒ no
    /// highlighting.
    let lexillaName: String
    /// Space-separated keyword lists, one per Scintilla keyword set
    /// (`SCI_SETKEYWORDS` index 0..n-1). Optional — most languages we
    /// supply just the primary keyword list.
    let keywords: [String]
}

enum LexerCatalog {
    /// Phase 1.8 baseline — extend as more languages get themed.
    static let cpp = LexerDescriptor(
        display: "C++",
        lexillaName: "cpp",
        keywords: [
            // Primary keywords — C and C++ together so the same lexer
            // colours both.
            "alignas alignof and and_eq asm auto bitand bitor bool break case catch char char16_t char32_t class compl const constexpr const_cast continue decltype default delete do double dynamic_cast else enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept not not_eq nullptr operator or or_eq private protected public register reinterpret_cast return short signed sizeof static static_assert static_cast struct switch template this thread_local throw true try typedef typeid typename union unsigned using virtual void volatile wchar_t while xor xor_eq override final"
        ]
    )

    static let swift = LexerDescriptor(
        display: "Swift",
        // Lexilla doesn't ship a Swift lexer; the C++ one is close enough
        // for keywords/strings/comments to read right while we wait for a
        // dedicated grammar.
        lexillaName: "cpp",
        keywords: [
            "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var actor async await break case continue default defer do else fallthrough for guard if in repeat return throw switch where while as Any catch false is nil super self Self throws true try mutating nonmutating optional required some throws weak willSet didSet get set"
        ]
    )

    static let python = LexerDescriptor(
        display: "Python",
        lexillaName: "python",
        keywords: [
            "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"
        ]
    )

    static let json = LexerDescriptor(
        display: "JSON", lexillaName: "json",
        keywords: ["true false null"]
    )

    static let markdown = LexerDescriptor(
        display: "Markdown", lexillaName: "markdown", keywords: []
    )

    static let shell = LexerDescriptor(
        display: "Shell", lexillaName: "bash",
        keywords: [
            "alias bg bind break builtin caller case cd command compgen complete continue coproc declare dirs disown do done echo elif else enable esac eval exec exit export false fc fg fi for function getopts hash help history if in jobs kill let local logout mapfile popd printf pushd pwd read readarray readonly return select set shift shopt source suspend test then time times trap true type typeset ulimit umask unalias unset until wait while"
        ]
    )

    static let xml = LexerDescriptor(display: "XML", lexillaName: "xml", keywords: [])
    static let html = LexerDescriptor(display: "HTML", lexillaName: "hypertext", keywords: [])
    static let javascript = LexerDescriptor(
        display: "JavaScript", lexillaName: "cpp",
        keywords: [
            "abstract async await break case catch class const continue debugger default delete do else enum export extends false finally for function if implements import in instanceof interface let new null of package private protected public return static super switch this throw true try typeof var void while with yield"
        ]
    )

    static let plain = LexerDescriptor(display: "Plain Text", lexillaName: "", keywords: [])

    /// Catalog shown in the status-bar language menu. Add a new entry here
    /// to make it user-selectable.
    static let all: [LexerDescriptor] = [
        plain, cpp, swift, python, javascript, json, markdown, shell, xml, html
    ]

    /// Find a descriptor by Lexilla lexer name (`""` ⇒ plain). Used when
    /// applying an explicit user override stored on `Document`.
    static func descriptor(forLexillaName name: String) -> LexerDescriptor {
        all.first { $0.lexillaName == name } ?? plain
    }

    /// Lookup by lower-case file extension (no leading dot). Falls back to
    /// `plain` when nothing matches.
    static func descriptor(forExtension ext: String) -> LexerDescriptor {
        switch ext.lowercased() {
        case "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx", "m", "mm":
            return cpp
        case "swift":
            return swift
        case "py", "pyw":
            return python
        case "json":
            return json
        case "md", "markdown":
            return markdown
        case "sh", "bash", "zsh":
            return shell
        case "xml", "plist":
            return xml
        case "html", "htm":
            return html
        case "js", "jsx", "ts", "tsx", "mjs", "cjs":
            return javascript
        default:
            return plain
        }
    }

    /// Convenience — pull the descriptor straight off a `Document`. Honors
    /// `doc.lexerOverride` first, then falls back to extension detection.
    /// Marked `@MainActor` because `Document` is main-actor isolated.
    @MainActor
    static func descriptor(for doc: Document) -> LexerDescriptor {
        if let override = doc.lexerOverride {
            return descriptor(forLexillaName: override)
        }
        guard let ext = doc.url?.pathExtension, !ext.isEmpty else { return plain }
        return descriptor(forExtension: ext)
    }
}
