// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import SwiftUI

/// Listens for one key combination and stores it as the panel shortcut.
final class ShortcutRecorderModel: ObservableObject {
    @Published var recording = false
    @Published var shortcut = GlobalShortcut.saved(for: DefaultsKey.panelShortcut,
                                                   fallback: .panelDefault)
    private var monitor: Any?

    func toggle() {
        recording ? cancel() : start()
    }

    func start() {
        recording = true
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
                self.commit(.panelDefault)
                return nil
            }
            let candidate = GlobalShortcut(keyCode: keyCode, modifiers: modifiers)
            guard candidate.isValid else { return nil }
            self.commit(candidate)
            return nil
        }
    }

    func cancel() {
        stopMonitoring()
        recording = false
        HotkeyManager.shared.sync()
    }

    private func commit(_ shortcut: GlobalShortcut) {
        self.shortcut = shortcut
        UserDefaults.standard.set(shortcut.storageValue, forKey: DefaultsKey.panelShortcut)
        stopMonitoring()
        recording = false
        HotkeyManager.shared.sync()
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
            if model.recording {
                Text("\(strings.shortcutRecording) \(strings.shortcutEscapeHint) \(strings.shortcutDeleteHint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if hotkeys.registrationFailed, !model.recording {
                Text(strings.shortcutFailed)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear { model.cancel() }
    }
}
