// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Carbon.HIToolbox
import Combine
import Foundation

/// The global shortcuts FixDock registers. The raw value is the Carbon
/// hotkey id under FixDock's signature.
enum HotkeyRole: UInt32, CaseIterable, Identifiable {
    /// Control-Option-Command-F opens the panel. Always registered.
    case panel = 1
    /// Control-Option-Command-4 opens the capture overlay.
    case captureOverlay = 2
    /// Control-Option-Command-3 captures the display under the pointer.
    case captureFullScreen = 3

    var id: UInt32 { rawValue }

    var storageKey: String {
        switch self {
        case .panel: return DefaultsKey.panelShortcut
        case .captureOverlay: return DefaultsKey.screenshotOverlayShortcut
        case .captureFullScreen: return DefaultsKey.screenshotFullScreenShortcut
        }
    }

    var fallback: GlobalShortcut {
        switch self {
        case .panel: return .panelDefault
        case .captureOverlay: return .captureOverlayDefault
        case .captureFullScreen: return .captureFullScreenDefault
        }
    }

    var saved: GlobalShortcut { GlobalShortcut.saved(for: storageKey, fallback: fallback) }

    /// Capture shortcuts exist only while the screenshot tool is installed
    /// and its own switch is on, so an uninstalled tool leaves the
    /// combination free for other apps.
    var wantsRegistration: Bool {
        let defaults = UserDefaults.standard
        switch self {
        case .panel: return true
        case .captureOverlay:
            return AppFeature.screenshot.isAvailable
                && defaults.bool(forKey: DefaultsKey.screenshotOverlayShortcutEnabled)
        case .captureFullScreen:
            return AppFeature.screenshot.isAvailable
                && defaults.bool(forKey: DefaultsKey.screenshotFullScreenShortcutEnabled)
        }
    }
}

/// The global shortcuts, registered with Carbon so they do not need
/// Accessibility. One event handler serves every role. Adapted from the
/// upstream hotkey registrar. The signature is FixDock's, not the upstream
/// app's.
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    /// Roles that wanted a shortcut and could not get it.
    @Published private(set) var failedRoles: Set<HotkeyRole> = []
    var registrationFailed: Bool { failedRoles.contains(.panel) }
    var onActivate: (() -> Void)?
    /// Actions for roles other than the panel, set by their services.
    var actions: [HotkeyRole: () -> Void] = [:]

    private var hotKeyRefs: [HotkeyRole: EventHotKeyRef] = [:]
    private var registeredShortcuts: [HotkeyRole: GlobalShortcut] = [:]
    private var eventHandler: EventHandlerRef?
    private var suspended = false
    /// 'FDCK'
    private let signature: UInt32 = 0x4644_434B

    private init() {}

    func sync() {
        guard !suspended else { return }
        installHandlerIfNeeded()
        var failed: Set<HotkeyRole> = []
        for role in HotkeyRole.allCases {
            guard role.wantsRegistration else {
                unregister(role)
                continue
            }
            if !register(role) { failed.insert(role) }
        }
        if failedRoles != failed { failedRoles = failed }
    }

    /// Drops every hotkey while Settings is listening for a new combination,
    /// so a current shortcut does not also fire.
    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        if suspended {
            HotkeyRole.allCases.forEach(unregister)
            if !failedRoles.isEmpty { failedRoles = [] }
        } else {
            sync()
        }
    }

    /// The role already using `shortcut`, other than `role` itself.
    func role(using shortcut: GlobalShortcut, except role: HotkeyRole) -> HotkeyRole? {
        HotkeyRole.allCases.first { $0 != role && $0.wantsRegistration && $0.saved == shortcut }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
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
            guard hotKeyID.signature == manager.signature,
                  let role = HotkeyRole(rawValue: hotKeyID.id)
            else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { manager.fire(role) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func fire(_ role: HotkeyRole) {
        switch role {
        case .panel: onActivate?()
        case .captureOverlay, .captureFullScreen: actions[role]?()
        }
    }

    private func register(_ role: HotkeyRole) -> Bool {
        let shortcut = role.saved
        if hotKeyRefs[role] != nil, registeredShortcuts[role] == shortcut { return true }
        unregister(role)
        let hotKeyID = EventHotKeyID(signature: signature, id: role.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.carbonKeyCode,
                                         shortcut.carbonModifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRefs[role] = ref
        registeredShortcuts[role] = shortcut
        return true
    }

    private func unregister(_ role: HotkeyRole) {
        if let ref = hotKeyRefs.removeValue(forKey: role) {
            UnregisterEventHotKey(ref)
        }
        registeredShortcuts[role] = nil
    }
}
