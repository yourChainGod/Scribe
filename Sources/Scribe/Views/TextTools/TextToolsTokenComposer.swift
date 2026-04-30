//
//  TextToolsTokenComposer.swift
//  Phase 40c — heart of the Column Merger.
//
//  Renders a horizontal row of "token chips" that, in order, form
//  the per-row template. Two chip kinds:
//
//      ╔═══╗   column reference  — shows {n} + column sample
//      ║{n}║
//      ╚═══╝
//
//      ╔═══╗   literal           — single-click to edit inline
//      ║" "║
//      ╚═══╝
//
//  Phase 40c changes (vs 40a):
//
//   • The standalone "Column Palette" pane is gone. Adding a new
//     column / literal now happens through the "+▾" popover at
//     the top-right of the composer header. The popover hosts a
//     mini column grid (single-click to append, drag to drop at
//     a precise position) plus shortcut buttons for "+ text" and
//     "+ newline".
//
//   • Literal chips are now bi-modal: idle ⇒ static Text label
//     that the whole chip can be dragged from; tap ⇒ TextField
//     edit mode (un-draggable while focused). This fixes the
//     "fresh literal can't be dragged" bug — a TextField's
//     internal NSTextField was eating the .onDrag gesture.
//

import SwiftUI
import UniformTypeIdentifiers

struct TextToolsTokenComposer: View {
    @ObservedObject var model: TextToolsModel
    @FocusState private var focusedLiteralID: UUID?
    @State private var addPopoverOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chipRow
            missingFillRow
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            TextToolsPanelTitle("textTools.composer.title", systemImage: "wand.and.rays")
            Text(L10n.t("textTools.composer.tokenCount",
                        model.tokens.filter(\.isColumn).count,
                        model.tokens.count))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()

            // Add (+▾) — opens the column / literal picker popover.
            Button {
                addPopoverOpen.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(L10n.t("textTools.composer.addMenu.help"))
            .popover(isPresented: $addPopoverOpen, arrowEdge: .top) {
                addPopoverContent
            }

            if !model.tokens.isEmpty {
                Button {
                    model.clearTokens()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(L10n.t("textTools.composer.clear"))
            }
        }
    }

    // MARK: Add popover

    private var addPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("textTools.composer.addMenu.title", bundle: .module)
                .font(.system(size: 12, weight: .semibold))

            if model.columnCount > 0 {
                if !model.tokens.isEmpty {
                    Button {
                        model.reseedAllColumns()
                        addPopoverOpen = false
                    } label: {
                        Label(L10n.t("textTools.palette.addAll"),
                              systemImage: "rectangle.stack.badge.plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }

                Text("textTools.composer.addMenu.columns", bundle: .module)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<model.columnCount, id: \.self) { index in
                            paletteChip(for: index)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 70)

                Divider()
                    .padding(.vertical, 2)
            } else {
                Text("textTools.palette.empty", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }

            Text("textTools.composer.addMenu.literals", bundle: .module)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                let id = model.appendEmptyLiteral()
                addPopoverOpen = false
                DispatchQueue.main.async { focusedLiteralID = id }
            } label: {
                Label(L10n.t("textTools.composer.addLiteral.menu"),
                      systemImage: "textformat")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            Button {
                model.tokens.append(.literal("\n"))
                addPopoverOpen = false
            } label: {
                Label(L10n.t("textTools.composer.addNewline.menu"),
                      systemImage: "return")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 360)
    }

    private func paletteChip(for index: Int) -> some View {
        let sample = model.sample(forColumn: index)
        return Button {
            model.appendColumn(index)
            addPopoverOpen = false
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("{\(index + 1)}")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                Text(sample.isEmpty
                     ? L10n.t("textTools.column.noSample")
                     : sample)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 70, alignment: .leading)
            }
            .frame(width: 80, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.30), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(L10n.t("textTools.palette.chip.help", index + 1))
        .onDrag {
            // Drag-out from the popover is also supported — once
            // the user starts dragging we close the popover so the
            // chip-row underneath can receive the drop.
            addPopoverOpen = false
            model.draggingTokenSource = .palette(columnIndex: index)
            return NSItemProvider(
                object: TokenDragSource.palette(columnIndex: index).serialized as NSString
            )
        }
    }

    // MARK: Chip row

    @ViewBuilder
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 6) {
                ForEach(model.tokens) { token in
                    chip(for: token)
                        .onDrop(of: [UTType.text],
                                delegate: TokenDropDelegate(
                                    model: model,
                                    target: .before(tokenID: token.id)
                                ))
                }
                trailingDropZone
            }
            .padding(10)
        }
        .frame(minHeight: 80, maxHeight: 88)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(model.tokens.isEmpty
                      ? Color.accentColor.opacity(0.04)
                      : Color.primary.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: model.tokens.isEmpty ? 1.5 : 1,
                                                 dash: model.tokens.isEmpty ? [4, 3] : []))
                .foregroundStyle(model.tokens.isEmpty
                                 ? Color.accentColor.opacity(0.4)
                                 : Color.primary.opacity(0.10))
        }
        .overlay(alignment: .center) {
            if model.tokens.isEmpty {
                emptyHint
            }
        }
        .onDrop(of: [UTType.text],
                delegate: TokenDropDelegate(model: model,
                                            target: .end))
    }

    private var emptyHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .semibold))
            Text("textTools.composer.empty", bundle: .module)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color.accentColor.opacity(0.7))
    }

    // MARK: Chip

    @ViewBuilder
    private func chip(for token: ColumnToken) -> some View {
        switch token {
        case .column(let id, let index):
            ColumnChipView(id: id, index: index, model: model)
        case .literal(let id, let text):
            LiteralChipView(id: id,
                            text: text,
                            model: model,
                            focusedLiteralID: $focusedLiteralID)
        }
    }

    // MARK: Trailing drop zone

    /// Dual-purpose anchor at the end of the chip row: single-tap
    /// appends a fresh empty literal and immediately focuses its
    /// inline TextField (the user's cursor lands inside the chip
    /// ready to type ", " / " | " / etc.); drag-drop accepts the
    /// same sources as any other drop slot, anchored to "end".
    private var trailingDropZone: some View {
        Button {
            let id = model.appendEmptyLiteral()
            DispatchQueue.main.async {
                focusedLiteralID = id
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .frame(width: 32, height: 36)
                .background(Color.accentColor.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.35),
                                      style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
        }
        .buttonStyle(.plain)
        .help(L10n.t("textTools.composer.addLiteral.help"))
        .onDrop(of: [UTType.text],
                delegate: TokenDropDelegate(model: model,
                                            target: .end))
    }

    // MARK: Missing-fill row

    private var missingFillRow: some View {
        HStack(spacing: 8) {
            Text("textTools.composer.missing", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L10n.t("textTools.composer.missing.placeholder"),
                      text: $model.missingCellPlaceholder)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 140)
            Spacer()
        }
    }
}

// MARK: - Column chip

/// Pulled out so the body of the composer stays terse, and so the
/// chip can react to its own dragging state without retriggering
/// the parent's `body` recomputation.
private struct ColumnChipView: View {
    let id: UUID
    let index: Int
    @ObservedObject var model: TextToolsModel

    var body: some View {
        let dragging = model.draggingTokenSource == .composer(tokenID: id)
        return HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text("{\(index + 1)}")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                Text(model.sample(forColumn: index).isEmpty
                     ? L10n.t("textTools.column.noSample")
                     : model.sample(forColumn: index))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 60, alignment: .leading)
            }
            removeButton(model: model, id: id)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
        }
        .opacity(dragging ? 0.45 : 1)
        .onDrag {
            model.draggingTokenSource = .composer(tokenID: id)
            return NSItemProvider(
                object: TokenDragSource.composer(tokenID: id).serialized as NSString
            )
        }
    }
}

// MARK: - Literal chip (bi-modal)

/// Idle state: shows the literal as a static, monospaced text
/// label. The whole chip is a drag source. Tapping the label
/// flips into edit mode and presents a TextField focused inline.
/// Blur ⇒ flips back to label mode. This fixes the Phase 40a
/// issue where TextField's NSTextField swallowed `.onDrag`, so
/// fresh literals couldn't be repositioned without first leaving
/// edit mode (which there was no way to do other than tabbing
/// out — a hidden affordance).
private struct LiteralChipView: View {
    let id: UUID
    let text: String
    @ObservedObject var model: TextToolsModel
    @FocusState.Binding var focusedLiteralID: UUID?

    @State private var isEditing = false

    var body: some View {
        let dragging = model.draggingTokenSource == .composer(tokenID: id)
        return HStack(spacing: 4) {
            if isEditing {
                editingField
            } else {
                displayLabel
            }
            removeButton(model: model, id: id)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isEditing ? 0.10 : 0.06))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isEditing
                        ? Color.accentColor.opacity(0.55)
                        : Color.primary.opacity(0.18),
                        lineWidth: 1)
        }
        .opacity(dragging ? 0.45 : 1)
        .modifier(ConditionalDrag(enabled: !isEditing,
                                  payload: TokenDragSource.composer(tokenID: id),
                                  model: model))
        .onChange(of: focusedLiteralID) { _, newValue in
            if newValue == id { isEditing = true }
            if newValue != id, isEditing { isEditing = false }
        }
    }

    private var displayLabel: some View {
        Text(displayText)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
            .lineLimit(1)
            .frame(minWidth: 24, idealWidth: 60, maxWidth: 120, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
            .onTapGesture {
                isEditing = true
                DispatchQueue.main.async { focusedLiteralID = id }
            }
    }

    private var editingField: some View {
        TextField(L10n.t("textTools.composer.literalPlaceholder"),
                  text: Binding(
                    get: { text },
                    set: { model.updateLiteral(id: id, text: $0) }
                  ))
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.primary)
            .focused($focusedLiteralID, equals: id)
            .frame(minWidth: 24, idealWidth: 60, maxWidth: 120)
            .fixedSize(horizontal: true, vertical: false)
            .onSubmit { commitEdit() }
            .onExitCommand { commitEdit() }
    }

    private func commitEdit() {
        focusedLiteralID = nil
        isEditing = false
    }

    /// Show readable substitutes for control chars so a "\n"
    /// literal doesn't render as an invisible empty chip.
    private var displayText: String {
        if text.isEmpty {
            return L10n.t("textTools.composer.literalPlaceholder")
        }
        if text == "\n" { return "↵" }
        if text == "\t" { return "→" }
        return text
    }
}

/// SwiftUI's `.onDrag` cannot be applied conditionally inside a
/// `body`; this modifier gates whether to attach the drag source
/// based on `enabled`. Used by the literal chip to suppress
/// dragging while in edit mode.
private struct ConditionalDrag: ViewModifier {
    let enabled: Bool
    let payload: TokenDragSource
    @ObservedObject var model: TextToolsModel

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                model.draggingTokenSource = payload
                return NSItemProvider(object: payload.serialized as NSString)
            }
        } else {
            content
        }
    }
}

// MARK: - Shared remove button

@MainActor
@ViewBuilder
private func removeButton(model: TextToolsModel, id: UUID) -> some View {
    Button {
        model.removeToken(id: id)
    } label: {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
            .background(Color.primary.opacity(0.08), in: Circle())
    }
    .buttonStyle(.plain)
    .help(L10n.t("textTools.composer.remove"))
}

// MARK: - Drop delegate

/// Drop semantics for the token bar. Two target shapes:
///   • `.before(tokenID)` — chip-relative drop. We always insert
///     before the target chip; the user can land on the trailing
///     "+" zone for "append".
///   • `.end` — append.
///
/// On drop, the payload is decoded as a `TokenDragSource`. A
/// `.palette(idx)` payload becomes a fresh `.column(idx)` token at
/// the target index. A `.composer(id)` payload reorders the
/// existing token. Cross-source drag preserves the chip's identity
/// when reordering, so SwiftUI's animations don't reset focus on
/// neighbouring literal chips.
struct TokenDropDelegate: DropDelegate {
    enum Target {
        case before(tokenID: UUID)
        case end
    }

    let model: TextToolsModel
    let target: Target

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.text])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.text.identifier,
                          options: nil) { item, _ in
            let raw: String?
            if let data = item as? Data {
                raw = String(data: data, encoding: .utf8)
            } else if let str = item as? String {
                raw = str
            } else if let nsstr = item as? NSString {
                raw = nsstr as String
            } else {
                raw = nil
            }
            guard let raw, let source = TokenDragSource(serialized: raw) else { return }
            DispatchQueue.main.async {
                self.apply(source: source)
                self.model.draggingTokenSource = nil
            }
        }
        return true
    }

    @MainActor
    private func apply(source: TokenDragSource) {
        let position = resolveIndex()
        switch source {
        case .palette(let columnIndex):
            model.insertColumn(columnIndex, at: position)
        case .composer(let id):
            model.moveToken(id: id, to: position)
        }
    }

    @MainActor
    private func resolveIndex() -> Int {
        switch target {
        case .end:
            return model.tokens.count
        case .before(let id):
            return model.tokens.firstIndex(where: { $0.id == id }) ?? model.tokens.count
        }
    }
}
