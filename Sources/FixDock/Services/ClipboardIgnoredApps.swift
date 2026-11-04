// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import Foundation

/// Apps whose copies never reach the clipboard history. Restored from
/// upstream.
///
/// The pasteboard says what was copied, never who copied it, so the app has to
/// be worked out from who had the screen at the time. The history reads the
/// pasteboard on a timer, which means a copy is only ever noticed some time
/// after it happened, and by then the person may already be in the app they
/// went to paste into. Asking only who is in front at that moment would name
/// the wrong app exactly in the case this list exists for, since the windows
/// that hold passwords usually close themselves the instant something is
/// copied.
///
/// So instead of one guess, every app that came to the front since the last
/// look is kept, and the copy is left out when any of them is on the list. The
/// window is under a second, and leaving out one copy too many is the harmless
/// side of being wrong here.
final class ClipboardIgnoredApps: ObservableObject {
    static let shared = ClipboardIgnoredApps()

    @Published private(set) var apps: [String] = []

    private var lookup: Set<String> = []
    /// Every app that held the front since the history last looked at the
    /// pasteboard. Seeded with whoever is in front when the window opens.
    private var candidates: Set<String> = []
    private var activationObserver: NSObjectProtocol?
    /// True while the history itself is running, the only time the observer
    /// lives.
    private var historyIsRunning = false
    /// Whether the history's own window held the keys at the last check, so a
    /// copy made in it is still known as one when the check its closing
    /// makes could not run.
    private var historyPanelWasKey = false

    private init() {
        reload()
    }

    // MARK: - The list

    func reload() {
        let defaults = UserDefaults.standard
        let raw = defaults.stringArray(forKey: DefaultsKey.clipboardHistoryIgnoredApps) ?? []
        let sanitized = ClipboardHistoryBundleList.sanitized(raw)
        if raw != sanitized {
            defaults.set(sanitized, forKey: DefaultsKey.clipboardHistoryIgnoredApps)
        }
        apps = sanitized
        lookup = Set(sanitized)
    }

    func add(_ bundleID: String) {
        let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty, !apps.contains(bundleID) else { return }
        UserDefaults.standard.set(apps + [bundleID], forKey: DefaultsKey.clipboardHistoryIgnoredApps)
        reload()
    }

    func remove(_ bundleID: String) {
        guard apps.contains(bundleID) else { return }
        UserDefaults.standard.set(apps.filter { $0 != bundleID },
                                  forKey: DefaultsKey.clipboardHistoryIgnoredApps)
        reload()
    }

    // MARK: - Watching

    func setHistoryRunning(_ running: Bool) {
        guard historyIsRunning != running else { return }
        historyIsRunning = running
        if running {
            guard activationObserver == nil else { return }
            candidates = Self.frontmostBundleID().map { [$0] } ?? []
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification
                    .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    let bundleID = app.bundleIdentifier else { return }
                self?.candidates.insert(bundleID)
            }
        } else if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
            candidates = []
            historyPanelWasKey = false
        }
    }

    // MARK: - The question the history asks

    /// Whether a copy noticed right now could have come from a listed app,
    /// the app it came from when only one held the front, and whether it
    /// came from the history's own window. Called once per pasteboard check,
    /// on the main thread, whether or not anything was copied, so the window
    /// of candidates never stretches past the check it belongs to. An app
    /// that names itself on the pasteboard is believed over the guess, and is
    /// left out just the same when it is on the list. The history's window
    /// never takes the front: a copy made while it held the keys, with no
    /// mark and not from another device, comes back as `fromHistoryPanel`.
    func sourceSinceLastCheck(declared: String?, remote: Bool,
                              historyPanelIsKey: Bool, historyPanelClosing: Bool)
        -> (excluded: Bool, bundleID: String?, fromHistoryPanel: Bool) {
        guard historyIsRunning else { return (false, nil, false) }
        // An empty mark is the convention for a writer that does not know,
        // and nothing longer than 255 bytes is a bundle identifier.
        let trimmed = declared?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mark = trimmed.isEmpty || trimmed.utf8.count > 255 ? nil : trimmed
        let fromHistoryPanel = mark == nil && !remote && (historyPanelWasKey || historyPanelIsKey)
        let guessed = candidates.count == 1 && !fromHistoryPanel ? candidates.first : nil
        let named: String? = mark.map { $0 == Bundle.main.bundleIdentifier ? nil : $0 } ?? guessed
        let source = (excluded: !candidates.isDisjoint(with: lookup) || mark.map { lookup.contains($0) } == true,
                      bundleID: remote ? nil : named,
                      fromHistoryPanel: fromHistoryPanel)
        candidates = Self.frontmostBundleID().map { [$0] } ?? []
        historyPanelWasKey = historyPanelIsKey && !historyPanelClosing
        return source
    }

    private static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
