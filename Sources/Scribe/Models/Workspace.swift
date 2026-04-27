//
//  Workspace.swift
//  Top-level state: documents, tabs, current selection.
//

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class Workspace: ObservableObject {
    @Published var documents: [Document] = []
    @Published var selectedID: UUID?
    @Published var sidebarVisible: Bool = true
    @Published var folderRoot: FileNode?

    let prefs: EditorPreferences

    init(prefs: EditorPreferences) {
        self.prefs = prefs
        // Open one empty doc by default so the editor isn't blank on first run.
        newDocument()
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let root = FileNode(url: url)
            root.isExpanded = true
            root.loadChildren()
            self.folderRoot = root
        }
    }

    func closeFolder() {
        folderRoot = nil
    }

    var current: Document? {
        documents.first { $0.id == selectedID }
    }

    func newDocument() {
        let untitledIndex = documents.filter { $0.url == nil }.count
        let title = untitledIndex == 0 ? "Untitled" : "Untitled \(untitledIndex)"
        let doc = Document(title: title)
        documents.append(doc)
        selectedID = doc.id
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let txtType = UTType("public.plain-text") {
            panel.allowedContentTypes = [txtType]
        }
        panel.allowsOtherFileTypes = true
        panel.runModal()
        for url in panel.urls {
            openFile(at: url)
        }
    }

    func openFile(at url: URL) {
        let normalized = url.standardizedFileURL
        // Reuse if already open.
        if let existing = documents.first(where: { $0.url?.standardizedFileURL == normalized }) {
            selectedID = existing.id
            prefs.addRecent(normalized)
            return
        }
        do {
            let text = try String(contentsOf: normalized, encoding: .utf8)
            let doc = Document(title: normalized.lastPathComponent, text: text, url: normalized)
            documents.append(doc)
            selectedID = doc.id
            prefs.addRecent(normalized)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func saveCurrent() {
        guard let doc = current else { return }
        if let url = doc.url {
            write(doc: doc, to: url)
        } else {
            saveAs(doc: doc)
        }
    }

    private func saveAs(doc: Document) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.title
        if panel.runModal() == .OK, let url = panel.url {
            let normalized = url.standardizedFileURL
            write(doc: doc, to: normalized)
            doc.url = normalized
            doc.title = normalized.lastPathComponent
            prefs.addRecent(normalized)
        }
    }

    private func write(doc: Document, to url: URL) {
        do {
            try doc.text.write(to: url, atomically: true, encoding: doc.encoding)
            doc.isDirty = false
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func close(documentID: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == documentID }) else { return }
        let doc = documents[idx]

        if doc.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to “\(doc.title)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")        // returns .alertFirstButtonReturn
            alert.addButton(withTitle: "Don't Save")  // returns .alertSecondButtonReturn
            alert.addButton(withTitle: "Cancel")      // returns .alertThirdButtonReturn

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if doc.url != nil {
                    write(doc: doc, to: doc.url!)
                } else {
                    saveAs(doc: doc)
                }
                if doc.isDirty { return } // user cancelled the save panel
            case .alertSecondButtonReturn:
                break // discard
            default:
                return // cancel close
            }
        }

        documents.remove(at: idx)
        if selectedID == documentID {
            selectedID = documents.last?.id
        }
        if documents.isEmpty {
            newDocument()
        }
    }
}
