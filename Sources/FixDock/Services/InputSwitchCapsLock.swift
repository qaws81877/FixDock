// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors
// Portions adapted from gksdud, Copyright (c) 2026 CodingNoye, MIT License (full text in NOTICE).

import Carbon
import Foundation
import IOKit
import IOKit.hidsystem

/// The keyboard's Caps Lock and the current input source's language, for
/// the fast switch's long press. Reads the source only; it is never
/// selected directly: selecting a source by API breaks Hangul composition.
enum InputSwitchCapsLock {
    /// Sets the lock through the HID system. No readback: right after a change
    /// that took effect it can still report the old state (gksdud).
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS
        else { return false }
        defer { IOServiceClose(connection) }
        return IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), enabled) == KERN_SUCCESS
    }

    /// The first language of the current keyboard input source ("ko", "en"…).
    /// Main thread only.
    static func currentLanguage() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]
        return languages?.first
    }

    /// Posted by macOS when the selected keyboard input source changes.
    static let sourceChangedNotification =
        Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
}
