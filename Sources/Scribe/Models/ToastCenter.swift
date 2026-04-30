//
//  ToastCenter.swift
//  Phase 43-T — non-blocking toast notification surface.
//
//  Replaces the scattered `NSAlert(error:).runModal()` callsites
//  that surfaced *informational* failures (file decode errors,
//  encoding round-trip failures, git engine failures, regex
//  compile errors). True confirmations (close-with-unsaved,
//  reopen-with-encoding, revert-hunk, discard-changes) stay on
//  NSAlert / NSSheet — those need a user choice, not a notice.
//
//  Design notes
//    • `@MainActor ObservableObject` — fits the app's existing
//      state-graph idiom; SwiftUI `ToastOverlay` observes directly.
//    • Stack capped at `maxStack` (default 4); oldest evicted FIFO.
//    • Dedupe window: identical {severity,title} within 1s drops
//      the second post — saves a flapping git engine from spamming.
//    • Auto-dismiss policy keyed on severity:
//        success → 3s · info → 4s · warning → 5s · error → persistent
//      The `.error` exception is intentional — users should be
//      able to read the failure even if it lands while they're
//      mid-keystroke; they close it explicitly.
//    • Scheduled dismiss uses `Task.sleep` so cancellation is
//      trivial. Tests verify task counts (`scheduledDismissCount`)
//      rather than wall-clock timing.
//

import Foundation
import SwiftUI

/// One of four colour/icon-coded toast varieties.
enum ToastSeverity: String, Sendable, Hashable, CaseIterable {
    case success
    case info
    case warning
    case error

    /// Default time-to-live in seconds. `nil` ⇒ persistent until
    /// the user dismisses or the stack rolls.
    var defaultAutoDismiss: TimeInterval? {
        switch self {
        case .success: return 3
        case .info:    return 4
        case .warning: return 5
        case .error:   return nil
        }
    }
}

/// Optional inline action button on a toast (e.g. "Reload" /
/// "Open in Finder"). The handler runs on the main actor; the
/// banner dismisses itself after invocation.
struct ToastAction: Sendable {
    let title: String
    let handler: @MainActor @Sendable () -> Void

    init(title: String, handler: @escaping @MainActor @Sendable () -> Void) {
        self.title = title
        self.handler = handler
    }
}

/// One toast notification. Identifiable + Equatable on `id` so
/// SwiftUI's `ForEach` and `.animation(_:value:)` track inserts /
/// removes by stable identity instead of hashing the whole struct.
struct Toast: Identifiable, Sendable, Equatable {
    let id: UUID
    let severity: ToastSeverity
    let title: String
    let message: String?
    let action: ToastAction?
    let createdAt: Date
    let autoDismissAfter: TimeInterval?

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }

    init(severity: ToastSeverity,
         title: String,
         message: String? = nil,
         action: ToastAction? = nil,
         id: UUID = UUID(),
         createdAt: Date = Date(),
         autoDismissOverride: TimeInterval?? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.message = message
        self.action = action
        self.createdAt = createdAt
        // `autoDismissOverride` is double-optional so the caller
        // can distinguish "use severity default" (nil) from
        // "force persistent" (.some(nil)) and "explicit interval"
        // (.some(.some(t))). Most callers don't need this — the
        // severity-default path is fine.
        if let override = autoDismissOverride {
            self.autoDismissAfter = override
        } else {
            self.autoDismissAfter = severity.defaultAutoDismiss
        }
    }
}

/// Central queue + dispatcher for non-blocking notifications.
/// One instance lives on `Workspace`; SwiftUI views observe it
/// and `ToastOverlay` renders the visible stack.
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var toasts: [Toast] = []

    let maxStack: Int
    let dedupeWindow: TimeInterval

    /// Pending auto-dismiss tasks, keyed by toast id. Used both
    /// to cancel on manual dismiss / eviction and as a test hook
    /// (see `scheduledDismissCount`).
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    init(maxStack: Int = 4, dedupeWindow: TimeInterval = 1.0) {
        self.maxStack = maxStack
        self.dedupeWindow = dedupeWindow
    }

    /// Test hook — number of toasts with an active auto-dismiss
    /// task. Persistent (`.error`) toasts never schedule one, so a
    /// pure `error()` post leaves this at 0.
    var scheduledDismissCount: Int { dismissTasks.count }

    /// Push a toast onto the stack. Returns the assigned id, or
    /// `nil` if the post was dropped by the dedupe window.
    @discardableResult
    func post(_ toast: Toast) -> UUID? {
        // Dedupe within the rolling window.
        let now = Date()
        if toasts.contains(where: {
            $0.severity == toast.severity &&
            $0.title == toast.title &&
            now.timeIntervalSince($0.createdAt) < dedupeWindow
        }) {
            return nil
        }

        toasts.append(toast)

        // Evict oldest while over capacity. We cancel the
        // scheduled dismiss for evicted toasts so a replaced
        // toast doesn't yank a *new* toast off the list when
        // its sleeper finally wakes.
        while toasts.count > maxStack {
            let removed = toasts.removeFirst()
            dismissTasks.removeValue(forKey: removed.id)?.cancel()
        }

        // Schedule auto-dismiss if non-persistent.
        if let interval = toast.autoDismissAfter {
            let id = toast.id
            let nanos = UInt64(max(0, interval) * 1_000_000_000)
            dismissTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.dismiss(id) }
            }
        }
        return toast.id
    }

    /// Manually dismiss one toast.
    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
        dismissTasks.removeValue(forKey: id)?.cancel()
    }

    /// Clear the entire stack (used on app deactivate /
    /// window close).
    func dismissAll() {
        toasts.removeAll()
        for (_, task) in dismissTasks { task.cancel() }
        dismissTasks.removeAll()
    }

    // MARK: - Convenience constructors

    @discardableResult
    func success(_ title: String, message: String? = nil, action: ToastAction? = nil) -> UUID? {
        post(Toast(severity: .success, title: title, message: message, action: action))
    }

    @discardableResult
    func info(_ title: String, message: String? = nil, action: ToastAction? = nil) -> UUID? {
        post(Toast(severity: .info, title: title, message: message, action: action))
    }

    @discardableResult
    func warning(_ title: String, message: String? = nil, action: ToastAction? = nil) -> UUID? {
        post(Toast(severity: .warning, title: title, message: message, action: action))
    }

    @discardableResult
    func error(_ title: String, message: String? = nil, action: ToastAction? = nil) -> UUID? {
        post(Toast(severity: .error, title: title, message: message, action: action))
    }

    /// Surface a Cocoa / Foundation error as a persistent error
    /// toast. Pulls `LocalizedError.errorDescription` first, falls
    /// back to NSError's `localizedDescription`, then
    /// `NSError.localizedRecoverySuggestion` as the message line.
    @discardableResult
    func error(_ error: Error, action: ToastAction? = nil) -> UUID? {
        let title: String
        let message: String?
        if let localized = error as? LocalizedError, let described = localized.errorDescription {
            title = described
            message = localized.recoverySuggestion ?? localized.failureReason
        } else {
            let ns = error as NSError
            title = ns.localizedDescription
            message = ns.localizedRecoverySuggestion ?? ns.localizedFailureReason
        }
        return self.error(title, message: message, action: action)
    }
}
