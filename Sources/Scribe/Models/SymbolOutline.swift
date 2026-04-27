//
//  SymbolOutline.swift
//  Phase 7 — observable outline of the currently-active document.
//  Re-parses on text or document changes with a 250 ms debounce so we
//  don't burn CPU mid-keystroke. Parsing itself runs off-main, since
//  scanLines on a multi-thousand-line file is in the millisecond
//  range but still worth keeping out of the run loop.
//

import Combine
import Foundation

@MainActor
final class SymbolOutline: ObservableObject {
    @Published private(set) var symbols: [SymbolEntry] = []
    @Published private(set) var isParsing: Bool = false

    /// Last document we computed for. nil ⇒ no doc bound; switching
    /// docs always forces a re-parse even if the text hasn't changed.
    private var lastDocID: UUID?
    private var debounceTask: Task<Void, Never>?

    /// Debounce window — chosen so a fast typist sees the outline
    /// settle inside one half-second pause without flickering on
    /// every keystroke.
    private static let debounceNanos: UInt64 = 250_000_000

    /// Re-compute symbols for the given document. Cheap to call from
    /// onChange; uses lastDocID + Equatable text comparison to skip
    /// no-op invocations.
    func update(for doc: Document?) {
        guard let doc else {
            cancel()
            symbols = []
            lastDocID = nil
            return
        }
        let ext = doc.url?.pathExtension.lowercased() ?? ""
        guard let parser = SymbolParserCatalog.parser(forExtension: ext) else {
            cancel()
            symbols = []
            lastDocID = doc.id
            return
        }

        // Capture by value; the doc may mutate or get deallocated mid-flight.
        let text = doc.text
        let docID = doc.id

        debounceTask?.cancel()
        isParsing = true
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            if Task.isCancelled { return }

            // Off-main parse. SymbolParser is Sendable and pure.
            let result = await Task.detached(priority: .userInitiated) {
                parser.parse(text)
            }.value
            if Task.isCancelled { return }

            await MainActor.run {
                guard let self else { return }
                // Bail if a newer update has already overtaken us.
                guard self.debounceTask?.isCancelled == false else { return }
                self.symbols = result
                self.lastDocID = docID
                self.isParsing = false
            }
        }
    }

    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        isParsing = false
    }
}
