//
//  StartupEnvironment.swift
//  ScribeApp pre-Workspace startup — environment-variable parsing,
//  activation policy, and the post-init auto-open dispatch.
//
//  Why an extra type: ScribeApp.init() used to inline-handle three
//  separate environment knobs (SCRIBE_AUTO_OPEN, SCRIBE_AUTO_FOLDER,
//  SCRIBE_AUTO_COMPARE) plus the NSApplication activation dance. With
//  the SCRIBE_TEST_* surface broken out into TestHooks, splitting the
//  startup parsing here too keeps `ScribeApp` itself readable as the
//  pure SwiftUI Scene declaration it should be.
//
//  All members are pure value-level reads of ProcessInfo.environment;
//  we never mutate the environment from this file.
//

import Foundation
import AppKit

/// Parsed form of the SCRIBE_AUTO_* environment knobs that ScribeApp.init
/// reads. Every field is non-optional — empty arrays / strings represent
/// "nothing requested".
struct StartupEnvironment {
    /// Files passed via `SCRIBE_AUTO_OPEN`, colon-separated. Only paths
    /// that actually exist on disk make it through; missing files are
    /// silently dropped because the test rigs occasionally pass paths
    /// that don't yet exist (a copy step happens in parallel).
    let autoOpenURLs: [URL]

    /// Folder requested via `SCRIBE_AUTO_FOLDER`. Empty string means
    /// "no auto-folder"; the caller treats this as "skip the open
    /// folder" branch entirely.
    let autoFolder: String

    /// Two `:`-separated paths passed via `SCRIBE_AUTO_COMPARE`. Empty
    /// when not set. Caller validates both halves exist before taking
    /// the diff path.
    let autoCompare: String

    /// Resolve from the current process environment.
    static func current() -> StartupEnvironment {
        let env = ProcessInfo.processInfo.environment

        let openList = env["SCRIBE_AUTO_OPEN"] ?? ""
        let urls: [URL] = openList
            .split(separator: ":")
            .map(String.init)
            .compactMap { path in
                FileManager.default.fileExists(atPath: path)
                    ? URL(fileURLWithPath: path)
                    : nil
            }

        return StartupEnvironment(
            autoOpenURLs: urls,
            autoFolder: env["SCRIBE_AUTO_FOLDER"] ?? "",
            autoCompare: env["SCRIBE_AUTO_COMPARE"] ?? ""
        )
    }
}

// MARK: - Activation policy

/// SwiftPM-built executables default to `.background` activation
/// policy, so the window never reaches the Dock and AppKit doesn't
/// claim foreground focus. Forcing `.regular` + `activate` mirrors
/// what an Xcode-built `.app` bundle gets for free.
@MainActor
enum AppActivation {
    static func makeRegular() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Auto-open dispatch

/// Apply `StartupEnvironment` to a freshly-constructed Workspace.
/// Runs on the next runloop turn — eager mutation of `@Published`
/// state at @main init time is observed to delay or skip NSWindow
/// creation on macOS 14+ / swift-tools 5.9. Defer until the
/// WindowGroup has its NSWindow materialised first.
@MainActor
enum StartupAutoOpen {
    static func apply(_ env: StartupEnvironment, to workspace: Workspace) {
        DispatchQueue.main.async {
            for url in env.autoOpenURLs {
                workspace.openFile(at: url)
            }
            if !env.autoFolder.isEmpty {
                let url = URL(fileURLWithPath: env.autoFolder)
                if FileManager.default.fileExists(atPath: url.path) {
                    workspace.openFolder(at: url)
                }
            }
            if !env.autoCompare.isEmpty {
                let parts = env.autoCompare
                    .split(separator: ":", maxSplits: 1)
                    .map(String.init)
                if parts.count == 2,
                   FileManager.default.fileExists(atPath: parts[0]),
                   FileManager.default.fileExists(atPath: parts[1]) {
                    let session = DiffSession()
                    session.load(left: URL(fileURLWithPath: parts[0]),
                                 right: URL(fileURLWithPath: parts[1]))
                    workspace.compareSession = session
                }
            }
        }
    }
}
