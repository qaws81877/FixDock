// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import Foundation

/// Modifier set stored with a global shortcut. The storage text is the same
/// shape as upstream (`control+option+command:3`), so later features can keep
/// using it.
struct GlobalShortcutModifiers: OptionSet, Hashable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let control = GlobalShortcutModifiers(rawValue: 1 << 0)
    static let option = GlobalShortcutModifiers(rawValue: 1 << 1)
    static let shift = GlobalShortcutModifiers(rawValue: 1 << 2)
    static let command = GlobalShortcutModifiers(rawValue: 1 << 3)
    static let validMask: GlobalShortcutModifiers = [.control, .option, .shift, .command]

    var hasPrimaryModifier: Bool {
        contains(.control) || contains(.option) || contains(.command)
    }

    var carbonFlags: UInt32 {
        var flags = UInt32(0)
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        if contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }

    var keyCaps: [String] {
        var caps: [String] = []
        if contains(.control) { caps.append("⌃") }
        if contains(.option) { caps.append("⌥") }
        if contains(.shift) { caps.append("⇧") }
        if contains(.command) { caps.append("⌘") }
        return caps
    }

    var storageTokens: [String] {
        var tokens: [String] = []
        if contains(.control) { tokens.append("control") }
        if contains(.option) { tokens.append("option") }
        if contains(.shift) { tokens.append("shift") }
        if contains(.command) { tokens.append("command") }
        return tokens
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var modifiers: GlobalShortcutModifiers = []
        if eventFlags.contains(.control) { modifiers.insert(.control) }
        if eventFlags.contains(.option) { modifiers.insert(.option) }
        if eventFlags.contains(.shift) { modifiers.insert(.shift) }
        if eventFlags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}

struct GlobalShortcut: Equatable, Hashable {
    let keyCode: Int64
    let modifiers: GlobalShortcutModifiers

    init(keyCode: Int64, modifiers: GlobalShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.validMask)
    }

    init?(storageValue: String) {
        guard let separator = storageValue.firstIndex(of: ":"),
              let keyCode = Int64(storageValue[storageValue.index(after: separator)...])
        else { return nil }
        var modifiers: GlobalShortcutModifiers = []
        let prefix = storageValue[..<separator]
        if !prefix.isEmpty {
            for token in prefix.split(separator: "+") {
                switch token {
                case "control": modifiers.insert(.control)
                case "option": modifiers.insert(.option)
                case "shift": modifiers.insert(.shift)
                case "command": modifiers.insert(.command)
                default: return nil
                }
            }
        }
        self.init(keyCode: keyCode, modifiers: modifiers)
        guard isValid else { return nil }
    }

    /// Delete on its own clears a shortcut field. With Control, Option, or
    /// Command it is an ordinary key.
    static func clearsShortcut(keyCode: Int64, modifiers: GlobalShortcutModifiers) -> Bool {
        guard keyCode == Int64(kVK_Delete) || keyCode == Int64(kVK_ForwardDelete) else { return false }
        return !modifiers.hasPrimaryModifier
    }

    static func cancelsRecording(keyCode: Int64) -> Bool {
        keyCode == Int64(kVK_Escape)
    }

    /// Control-Option-Command-F. F is for FixDock, on the free modifier layer.
    static let panelDefault = GlobalShortcut(keyCode: Int64(kVK_ANSI_F),
                                             modifiers: [.control, .option, .command])

    static func saved(for key: String, fallback: GlobalShortcut) -> GlobalShortcut {
        if let raw = UserDefaults.standard.string(forKey: key),
           let shortcut = GlobalShortcut(storageValue: raw) {
            return shortcut
        }
        return fallback
    }

    var storageValue: String {
        "\(modifiers.storageTokens.joined(separator: "+")):\(keyCode)"
    }

    static let keyCodeRange: ClosedRange<Int64> = 0...0xFFFF

    var hasUsableKeyCode: Bool { Self.keyCodeRange.contains(keyCode) }

    var hasPrintableKey: Bool { hasUsableKeyCode && keyLabel != nil }

    var isValid: Bool {
        hasPrintableKey
            && (modifiers.hasPrimaryModifier || Self.standaloneFunctionKeys.contains(keyCode))
    }

    var displayString: String {
        let label = keyLabel ?? "Key \(keyCode)"
        let needsSeparator = label.count == 1
            && label.rangeOfCharacter(from: .alphanumerics) == nil
        return modifiers.keyCaps.joined() + (needsSeparator ? " " : "") + label
    }

    var keyCaps: [String] {
        modifiers.keyCaps + [keyLabel ?? "Key \(keyCode)"]
    }

    var carbonKeyCode: UInt32 { UInt32(exactly: keyCode) ?? 0 }
    var carbonModifiers: UInt32 { modifiers.carbonFlags }

    private static let standaloneFunctionKeys: Set<Int64> = Set(([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ] as [Int]).map(Int64.init))

    private var keyLabel: String? {
        switch Int(keyCode) {
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default:
            if let label = Self.layoutKeyLabel(for: keyCode, usesCommand: modifiers.contains(.command)) {
                return label
            }
            return Self.fallbackAnsiKeyLabel(for: keyCode)
        }
    }

    private static func fallbackAnsiKeyLabel(for keyCode: Int64) -> String? {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        case kVK_ISO_Section: return "§"
        default: return nil
        }
    }

    /// The character the current layout prints for a key. Command shortcuts
    /// read the layout's Command table, because a non-Latin layout still
    /// answers Command combinations from that table. Adapted from upstream.
    /// Quit protection reads it from its event tap, on the main run loop.
    static func layoutKeyLabel(for keyCode: Int64, usesCommand: Bool) -> String? {
        guard Thread.isMainThread, let code = UInt16(exactly: keyCode) else { return nil }
        let cacheKey = LayoutLabelKey(keyCode: keyCode, usesCommand: usesCommand)
        if let cached = layoutLabels[cacheKey] { return cached }
        guard let layoutData = currentLayoutData(),
              let label = derivedLayoutKeyLabel(for: code, layoutData: layoutData, usesCommand: usesCommand)
        else { return nil }
        layoutLabels[cacheKey] = label
        return label
    }

    private struct LayoutLabelKey: Hashable {
        let keyCode: Int64
        let usesCommand: Bool
    }

    private static var layoutLabels: [LayoutLabelKey: String] = [:]

    private static func currentLayoutData() -> Data? {
        guard Thread.isMainThread else { return nil }
        let source = inputMethodIsActive
            ? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
            : TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source,
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
    }

    private static var inputMethodIsActive: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
        else { return false }
        let value = Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String
        return value != (kTISTypeKeyboardLayout as String)
    }

    private static func derivedLayoutKeyLabel(for code: UInt16,
                                              layoutData: Data,
                                              usesCommand: Bool) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let modifierState = usesCommand ? UInt32((cmdKey >> 8) & 0xFF) : 0
        let status = layoutData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress
            else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), modifierState,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let label = String(utf16CodeUnits: chars, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count == 1,
              let scalar = label.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar)
        else { return nil }
        return label.uppercased()
    }
}
