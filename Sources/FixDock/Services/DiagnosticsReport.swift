// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox

/// The text the feedback sheet shows and copies. Plain English so it reads
/// the same whoever receives it. It holds state and health events only:
/// no snippet triggers or texts, no exception lists, no typed keys.
/// Nothing here leaves the Mac unless the person pastes it somewhere.
enum DiagnosticsReport {
    /// The note on top of a `snapshot()`.
    static func compose(comment: String, snapshot: String) -> String {
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return "FixDock feedback\n\nComment:\n\(note.isEmpty ? "(none)" : note)\n\n\(snapshot)"
    }

    /// State and recent events, read once when the sheet opens. Main thread.
    static func snapshot() -> String {
        let health = KeyTapHealth.shared
        let defaults = UserDefaults.standard
        var out: [String] = []

        out.append("App: \(AppInfo.name) \(AppInfo.version) (\(AppInfo.buildNumber)), \(Bundle.main.bundleIdentifier ?? "no bundle id")")
        out.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString), \(hardwareModel() ?? "unknown model")")
        out.append("Report time: \(timestamp(Date()))")
        out.append("Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing")")
        out.append("Session on screen: \(SessionActivity.shared.isActive ? "yes" : "no")")
        let installed = AppFeature.allCases.filter(\.isAvailable).map(\.rawValue)
        out.append("Tools installed: \(installed.isEmpty ? "none" : installed.joined(separator: ", "))")
        out.append("")

        let quit = QuitProtectionService.shared
        out.append("Quit protection: Command-Q \(onOff(defaults.bool(forKey: DefaultsKey.quitProtectionQuitEnabled))), Command-W \(onOff(defaults.bool(forKey: DefaultsKey.quitProtectionCloseEnabled))), tap \(describe(health.state(of: .quitProtection)))\(quit.isWaitingForAccessibility ? ", waiting for Accessibility" : "")")
        let snippets = TextSnippetSupport.decode(defaults.data(forKey: DefaultsKey.textSnippets))
        out.append("Text snippets: \(onOff(defaults.bool(forKey: DefaultsKey.textSnippetsEnabled))), \(snippets.filter(\.enabled).count) of \(snippets.count) enabled, tap \(describe(health.state(of: .textSnippets)))")
        health.refreshSecureInput()
        if let secure = health.secureInput {
            out.append("Secure input: ON, reported pid \(secure.processIdentifier.map(String.init) ?? "unknown") (\(secure.applicationName ?? "unknown"))\(secure.holderExited ? ", process gone" : "")")
        } else {
            out.append("Secure input: \(IsSecureEventInputEnabled() ? "ON" : "off")")
        }
        out.append("")

        let events = DiagnosticsJournal.shared.recent(100)
        out.append("Recent key tap events (oldest first, \(events.count)):")
        out.append(contentsOf: events.isEmpty ? ["(none)"] : events)
        return out.joined(separator: "\n") + "\n"
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    private static func describe(_ state: KeyTapHealth.TapState) -> String {
        switch state {
        case .off: return "off"
        case .running: return "running"
        case .failed: return "FAILED to start"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
