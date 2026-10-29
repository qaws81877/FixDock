// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Carbon.HIToolbox
import Combine
import Foundation

/// The shell's one global shortcut, registered with Carbon so it does not
/// need Accessibility. Adapted from the upstream hotkey registrar. The
/// signature is FixDock's, not the upstream app's.
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published private(set) var registrationFailed = false
    var onActivate: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var registeredShortcut: GlobalShortcut?
    /// 'FDCK'
    private let signature: UInt32 = 0x4644_434B
    private let hotKeyIdentity: UInt32 = 1

    private init() {}

    func sync() {
        register()
    }

    /// Drops the hotkey while Settings is listening for a new combination,
    /// so the current shortcut does not also open the panel.
    func setSuspended(_ suspended: Bool) {
        if suspended {
            unregister()
        } else {
            register()
        }
    }

    private func register() {
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.panelShortcut,
                                            fallback: .panelDefault)
        if hotKeyRef != nil, registeredShortcut == shortcut { return }
        unregister(resetFailure: false)
        if eventHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                if let event {
                    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                guard hotKeyID.signature == manager.signature, hotKeyID.id == manager.hotKeyIdentity
                else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { manager.onActivate?() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        }
        let hotKeyID = EventHotKeyID(signature: signature, id: hotKeyIdentity)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.carbonKeyCode,
                                         shortcut.carbonModifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            registeredShortcut = shortcut
            registrationFailed = false
        } else {
            hotKeyRef = nil
            registeredShortcut = nil
            registrationFailed = true
        }
    }

    private func unregister(resetFailure: Bool = true) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        registeredShortcut = nil
        if resetFailure { registrationFailed = false }
    }
}
