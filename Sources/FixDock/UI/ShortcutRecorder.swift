// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import SwiftUI

/// Listens for one key combination and stores it for one shortcut role.
/// A combination another FixDock shortcut already uses is refused.
final class ShortcutRecorderModel: ObservableObject {
    @Published var recording = false
    @Published var shortcut: GlobalShortcut
    @Published var conflict = false
    let role: HotkeyRole
    private var monitor: Any?

    init(role: HotkeyRole = .panel) {
        self.role = role
        shortcut = role.saved
    }

    func toggle() {
        recording ? cancel() : start()
    }

    func start() {
        recording = true
        conflict = false
        HotkeyManager.shared.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = GlobalShortcutModifiers(eventFlags: event.modifierFlags)
            let keyCode = Int64(event.keyCode)
            if GlobalShortcut.cancelsRecording(keyCode: keyCode) {
                self.cancel()
                return nil
            }
            if GlobalShortcut.clearsShortcut(keyCode: keyCode, modifiers: modifiers) {
                self.commit(self.role.fallback)
                return nil
            }
            let candidate = GlobalShortcut(keyCode: keyCode, modifiers: modifiers)
            guard candidate.isValid else { return nil }
            self.commit(candidate)
            return nil
        }
    }

    func cancel() {
        guard recording else { return }
        stopMonitoring()
        recording = false
        HotkeyManager.shared.setSuspended(false)
    }

    private func commit(_ shortcut: GlobalShortcut) {
        stopMonitoring()
        recording = false
        if HotkeyManager.shared.role(using: shortcut, except: role) != nil {
            conflict = true
        } else {
            self.shortcut = shortcut
            UserDefaults.standard.set(shortcut.storageValue, forKey: role.storageKey)
        }
        HotkeyManager.shared.setSuspended(false)
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

struct ShortcutRecorder: View {
    @StateObject private var model = ShortcutRecorderModel()
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        let strings = l10n.s
        VStack(alignment: .leading, spacing: 8) {
            Text(strings.shortcutTitle)
                .font(.headline)
            Text(strings.shortcutCaption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                ShortcutCaps(keys: model.shortcut.keyCaps)
                Button(model.recording ? strings.shortcutRecording : strings.shortcutRecord) {
                    model.toggle()
                }
            }
            ShortcutRecorderNotes(model: model)
        }
        .onDisappear { model.cancel() }
    }
}

/// A capture shortcut's row: its switch, the keys and the record button.
struct ShortcutRecorderRow: View {
    let title: String
    let enabledKey: String
    @StateObject private var model: ShortcutRecorderModel
    @ObservedObject private var l10n = L10n.shared
    @AppStorage private var enabled: Bool

    init(role: HotkeyRole, title: String, enabledKey: String) {
        self.title = title
        self.enabledKey = enabledKey
        _model = StateObject(wrappedValue: ShortcutRecorderModel(role: role))
        _enabled = AppStorage(wrappedValue: true, enabledKey)
    }

    var body: some View {
        let strings = l10n.s
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle(title, isOn: $enabled)
                    .onChange(of: enabled) { _, _ in HotkeyManager.shared.sync() }
                Spacer(minLength: 0)
                ShortcutCaps(keys: model.shortcut.keyCaps)
                    .opacity(enabled ? 1 : 0.4)
                Button(model.recording ? strings.shortcutRecording : strings.shortcutRecord) {
                    model.toggle()
                }
                .disabled(!enabled)
            }
            ShortcutRecorderNotes(model: model)
        }
        .onDisappear { model.cancel() }
    }
}

/// Hints while recording, then a refused or failed combination.
private struct ShortcutRecorderNotes: View {
    @ObservedObject var model: ShortcutRecorderModel
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        let strings = l10n.s
        if model.recording {
            Text("\(strings.shortcutRecording) \(strings.shortcutEscapeHint) \(strings.shortcutDeleteHint)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.conflict {
            Text(strings.shortcutConflict)
                .font(.caption)
                .foregroundStyle(.orange)
        } else if hotkeys.failedRoles.contains(model.role) {
            Text(strings.shortcutFailed)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
