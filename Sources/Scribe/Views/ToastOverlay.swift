//
//  ToastOverlay.swift
//  Phase 43-T — SwiftUI rendering for the `ToastCenter` queue.
//
//  ToastOverlay sits at the top of MainWindow's ZStack (above the
//  editor, above sheets that don't need full focus, below modal
//  NSAlerts). It anchors the visible stack to the top-trailing
//  corner with springy enter/exit transitions and a hairline
//  hover-revealed close button on each banner.
//
//  Style note — banners use the system `regularMaterial` so they
//  blend with whatever theme background sits underneath. The
//  severity tint paints a 0.5pt border + the leading icon; we
//  deliberately don't tint the whole fill because at 4 stacked
//  toasts the saturation gets noisy. Modern editors (Linear,
//  Raycast, Arc) all use this hairline-tint pattern.
//

import SwiftUI

/// Anchored top-trailing stack of `Toast` banners. Mount as an
/// `.overlay` on whatever view should host notifications.
struct ToastOverlay: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.toasts) { toast in
                ToastBanner(toast: toast) { center.dismiss(toast.id) }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing))
                    ))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // Stable identity for the spring — ids change ⇒ animate.
        .animation(.spring(response: 0.42, dampingFraction: 0.85),
                   value: center.toasts.map(\.id))
        .allowsHitTesting(!center.toasts.isEmpty)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("toast.region.label", bundle: .module))
    }
}

/// One banner row.
struct ToastBanner: View {
    let toast: Toast
    let onDismiss: () -> Void

    @State private var hover = false
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.severity.iconName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(toast.severity.tint)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let msg = toast.message, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let action = toast.action {
                    Button {
                        action.handler()
                        onDismiss()
                    } label: {
                        Text(action.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(toast.severity.tint)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0.55)
            .help(Text("toast.close.help", bundle: .module))
            .accessibilityLabel(Text("toast.close.help", bundle: .module))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(toast.severity.tint.opacity(0.35), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 4)
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

extension ToastSeverity {
    /// SF Symbols glyph for the leading icon.
    var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    /// Tint colour (icon + border + action button). System
    /// semantic colours so they auto-flip on Dark mode.
    var tint: Color {
        switch self {
        case .success: return .green
        case .info:    return .accentColor
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
