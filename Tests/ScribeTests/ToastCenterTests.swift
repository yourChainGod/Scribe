//
//  ToastCenterTests.swift
//  Phase 43-T — locks the model behaviour the SwiftUI overlay and
//  every Workspace error-path replacement depend on. Wall-clock
//  timing is *not* tested here — `Task.sleep` is verified via the
//  `scheduledDismissCount` hook, which counts pending dismiss
//  tasks without actually waiting on them.
//

import XCTest
@testable import Scribe

@MainActor
final class ToastCenterTests: XCTestCase {

    // MARK: - Basic queue behaviour

    func test_post_addsToastToList() {
        let center = ToastCenter()
        let toast = Toast(severity: .success, title: "Saved")
        let id = center.post(toast)
        XCTAssertEqual(id, toast.id)
        XCTAssertEqual(center.toasts.count, 1)
        XCTAssertEqual(center.toasts.first?.title, "Saved")
        XCTAssertEqual(center.toasts.first?.severity, .success)
    }

    func test_dismiss_removesToastById() {
        let center = ToastCenter()
        let toast = Toast(severity: .info, title: "X")
        center.post(toast)
        center.dismiss(toast.id)
        XCTAssertTrue(center.toasts.isEmpty)
    }

    func test_dismiss_unknownIdIsNoop() {
        let center = ToastCenter()
        center.post(Toast(severity: .info, title: "A"))
        center.dismiss(UUID())
        XCTAssertEqual(center.toasts.count, 1)
    }

    func test_dismissAll_clearsList() {
        let center = ToastCenter()
        center.post(Toast(severity: .info, title: "A"))
        center.post(Toast(severity: .info, title: "B"))
        center.dismissAll()
        XCTAssertTrue(center.toasts.isEmpty)
        XCTAssertEqual(center.scheduledDismissCount, 0)
    }

    // MARK: - Stack cap

    func test_maxStack_evictsOldestWhenExceeded() {
        let center = ToastCenter(maxStack: 3)
        for i in 0..<5 {
            // Each title differs so dedupe never fires.
            center.post(Toast(severity: .info, title: "T\(i)"))
        }
        XCTAssertEqual(center.toasts.count, 3)
        XCTAssertEqual(center.toasts.first?.title, "T2")
        XCTAssertEqual(center.toasts.last?.title, "T4")
    }

    func test_maxStack_evictedToastCancelsItsDismissTask() {
        // success severity ⇒ scheduled dismiss task. Evicted
        // toast must release its task so the eviction count
        // matches the visible-list count.
        let center = ToastCenter(maxStack: 2)
        for i in 0..<4 {
            center.post(Toast(severity: .success, title: "T\(i)"))
        }
        XCTAssertEqual(center.toasts.count, 2)
        XCTAssertEqual(center.scheduledDismissCount, 2,
                       "evicted toasts must cancel their dismiss task")
    }

    // MARK: - Dedupe window

    func test_dedupe_dropsDuplicateWithinWindow() {
        let center = ToastCenter()
        center.post(Toast(severity: .error, title: "Failed"))
        let second = center.post(Toast(severity: .error, title: "Failed"))
        XCTAssertNil(second)
        XCTAssertEqual(center.toasts.count, 1)
    }

    func test_dedupe_allowsDifferentTitle() {
        let center = ToastCenter()
        center.post(Toast(severity: .error, title: "A"))
        center.post(Toast(severity: .error, title: "B"))
        XCTAssertEqual(center.toasts.count, 2)
    }

    func test_dedupe_allowsDifferentSeverity() {
        let center = ToastCenter()
        center.post(Toast(severity: .error, title: "X"))
        center.post(Toast(severity: .info, title: "X"))
        XCTAssertEqual(center.toasts.count, 2)
    }

    // MARK: - Auto-dismiss policy

    func test_errorDefaultsToPersistent() {
        let center = ToastCenter()
        let id = center.error("Boom")
        XCTAssertNotNil(id)
        XCTAssertEqual(center.scheduledDismissCount, 0,
                       "error severity must not schedule auto-dismiss")
        XCTAssertNil(center.toasts.first?.autoDismissAfter)
    }

    func test_successSchedulesAutoDismiss() {
        let center = ToastCenter()
        _ = center.success("Ok")
        XCTAssertEqual(center.scheduledDismissCount, 1)
        XCTAssertEqual(center.toasts.first?.autoDismissAfter, 3)
    }

    func test_infoSchedulesAutoDismiss() {
        let center = ToastCenter()
        _ = center.info("Info")
        XCTAssertEqual(center.scheduledDismissCount, 1)
        XCTAssertEqual(center.toasts.first?.autoDismissAfter, 4)
    }

    func test_warningSchedulesAutoDismiss() {
        let center = ToastCenter()
        _ = center.warning("Hmm")
        XCTAssertEqual(center.scheduledDismissCount, 1)
        XCTAssertEqual(center.toasts.first?.autoDismissAfter, 5)
    }

    func test_overrideToPersistentOnSuccess() {
        let center = ToastCenter()
        let toast = Toast(severity: .success,
                          title: "Sticky",
                          autoDismissOverride: .some(nil))
        center.post(toast)
        XCTAssertNil(center.toasts.first?.autoDismissAfter)
        XCTAssertEqual(center.scheduledDismissCount, 0)
    }

    func test_overrideToCustomInterval() {
        let center = ToastCenter()
        let toast = Toast(severity: .error,
                          title: "Soft",
                          autoDismissOverride: .some(2))
        center.post(toast)
        XCTAssertEqual(center.toasts.first?.autoDismissAfter, 2)
        XCTAssertEqual(center.scheduledDismissCount, 1)
    }

    // MARK: - Error helper

    func test_errorFromLocalizedErrorPullsDescription() {
        struct Boom: LocalizedError {
            var errorDescription: String? { "Disk on fire" }
            var recoverySuggestion: String? { "Try water" }
        }
        let center = ToastCenter()
        center.error(Boom())
        XCTAssertEqual(center.toasts.first?.title, "Disk on fire")
        XCTAssertEqual(center.toasts.first?.message, "Try water")
        XCTAssertEqual(center.toasts.first?.severity, .error)
    }

    func test_errorFromNSErrorFallsBackToLocalizedDescription() {
        let ns = NSError(domain: NSCocoaErrorDomain,
                         code: NSFileReadUnknownError,
                         userInfo: [NSLocalizedDescriptionKey: "Cannot read"])
        let center = ToastCenter()
        center.error(ns)
        XCTAssertEqual(center.toasts.first?.title, "Cannot read")
    }

    // MARK: - Severity defaults

    func test_severityDefaults_matchSpec() {
        XCTAssertEqual(ToastSeverity.success.defaultAutoDismiss, 3)
        XCTAssertEqual(ToastSeverity.info.defaultAutoDismiss, 4)
        XCTAssertEqual(ToastSeverity.warning.defaultAutoDismiss, 5)
        XCTAssertNil(ToastSeverity.error.defaultAutoDismiss)
    }
}
