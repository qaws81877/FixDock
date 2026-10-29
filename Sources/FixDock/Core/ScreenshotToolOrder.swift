// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Carbon.HIToolbox
import Foundation

/// The rail order the person chose, the keys 1 to 9 it gives the first nine
/// tools, and the single keys a tool can have of its own. The order is
/// stored as comma-separated tool ids; anything the stored text lacks (a
/// tool added by a later version) follows in the canonical order, so new
/// tools slot in without a migration. Own keys are stored as
/// `tool=<shortcut storage>` pairs. Adapted from upstream's `Tool.ordered`,
/// `assigningShortcut` and its tool bindings; conflicts are checked only
/// against the editor's own keys, since FixDock's global shortcuts all need
/// a modifier.
extension ScreenshotSupport.Tool {
    static var defaultOrderStorage: String {
        storage(editorTools)
    }

    static func storage(_ order: [Self]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    /// Saved ids first, then any rail tool the text lacks in the canonical
    /// order. Unknown and duplicate ids, and tools that never sit in the
    /// rail, never reach the UI.
    static func ordered(from raw: String?) -> [Self] {
        let rail = Set(editorTools)
        var seen = Set<Self>()
        var result: [Self] = []
        for id in (raw ?? "").split(separator: ",") {
            guard let tool = Self(rawValue: String(id)), rail.contains(tool),
                  seen.insert(tool).inserted
            else { continue }
            result.append(tool)
        }
        for tool in editorTools where seen.insert(tool).inserted {
            result.append(tool)
        }
        return result
    }

    /// The tool in rail slot `number` (1 based), or nil past the first nine,
    /// past the rail or with the keys turned off.
    static func shortcutTool(number: Int, orderRaw: String?, enabled: Bool) -> Self? {
        guard enabled, (1...shortcutLimit).contains(number) else { return nil }
        let order = ordered(from: orderRaw)
        let index = number - 1
        return order.indices.contains(index) ? order[index] : nil
    }

    static func shortcutNumber(for tool: Self, orderRaw: String?, enabled: Bool) -> Int? {
        guard enabled,
              let index = ordered(from: orderRaw).firstIndex(of: tool),
              index < shortcutLimit
        else { return nil }
        return index + 1
    }

    /// Assigning a number is the same operation as moving the tool into
    /// that numbered rail slot. Choosing no number moves it just below the
    /// first nine, where it stays in the rail without a key.
    static func assigningShortcut(_ number: Int?, to tool: Self, orderRaw: String?) -> [Self] {
        var order = ordered(from: orderRaw)
        guard let current = order.firstIndex(of: tool) else { return order }
        if number == nil, current >= shortcutLimit { return order }
        order.remove(at: current)
        let destination: Int
        if let number, (1...shortcutLimit).contains(number) {
            destination = min(number - 1, order.count)
        } else {
            destination = min(shortcutLimit, order.count)
        }
        order.insert(tool, at: destination)
        return order
    }

    /// The order with `tool` swapped one place up (-1) or down (1); the same
    /// order at either end.
    static func moving(_ tool: Self, by offset: Int, orderRaw: String?) -> [Self] {
        var order = ordered(from: orderRaw)
        guard let index = order.firstIndex(of: tool), order.indices.contains(index + offset)
        else { return order }
        order.swapAt(index, index + offset)
        return order
    }

    // MARK: - Own keys

    /// A key of its own: one key with no modifier that has a label, so the
    /// rail badge can show it.
    static func ownKey(storage: String) -> GlobalShortcut? {
        guard let separator = storage.firstIndex(of: ":"),
              storage[..<separator].isEmpty,
              let keyCode = Int64(storage[storage.index(after: separator)...]),
              GlobalShortcut.keyCodeRange.contains(keyCode)
        else { return nil }
        let key = GlobalShortcut(keyCode: keyCode, modifiers: [])
        return key.hasPrintableKey ? key : nil
    }

    /// Keys the editor answers itself without a modifier: copy (Return),
    /// step out (Esc), delete, and keys a later version may give to moving
    /// marks (Space, arrows). Anything with a modifier is the Command
    /// shortcuts' or nobody's, so an own key never has one.
    static func isReservedEditorKey(_ key: GlobalShortcut) -> Bool {
        !key.modifiers.isEmpty || [
            kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape, kVK_Delete, kVK_ForwardDelete,
            kVK_Space, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        ].contains(Int(key.keyCode))
    }

    /// The rail slot a key names: what it types when that is a digit 1 to 9
    /// (whatever the layout), else the digit row and keypad positions.
    static func shortcutDigit(keyCode: Int64, typed: String?) -> Int? {
        if let typed, let digit = Int(typed), (1...shortcutLimit).contains(digit) { return digit }
        let digits: [Int: Int] = [
            kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
            kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
            kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3, kVK_ANSI_Keypad4: 4,
            kVK_ANSI_Keypad5: 5, kVK_ANSI_Keypad6: 6, kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8,
            kVK_ANSI_Keypad9: 9,
        ]
        return digits[Int(keyCode)]
    }

    /// The saved own keys. Unknown tools, keys with a modifier, reserved and
    /// digit keys are dropped; a key saved twice stays with the first tool
    /// in canonical order, so routing and the badges agree.
    static func bindings(from raw: String?) -> [Self: GlobalShortcut] {
        var result: [Self: GlobalShortcut] = [:]
        let rail = Set(editorTools)
        for entry in (raw ?? "").split(separator: ",") {
            let pair = entry.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let tool = Self(rawValue: String(pair[0])), rail.contains(tool),
                  let key = ownKey(storage: String(pair[1])), !isReservedEditorKey(key),
                  shortcutDigit(keyCode: key.keyCode, typed: nil) == nil
            else { continue }
            result[tool] = key
        }
        var seen = Set<GlobalShortcut>()
        for tool in editorTools {
            if let key = result[tool], !seen.insert(key).inserted { result[tool] = nil }
        }
        return result
    }

    static func bindingsStorage(_ bindings: [Self: GlobalShortcut]) -> String {
        editorTools.compactMap { tool in
            bindings[tool].map { "\(tool.rawValue)=\($0.storageValue)" }
        }.joined(separator: ",")
    }

    /// Why a recorded key cannot be a tool's own, or nil when it can. Digits
    /// never get here: they move the tool instead.
    enum BindingRejection: Equatable {
        case reserved
        case tool(ScreenshotSupport.Tool)
    }

    static func bindingRejection(for key: GlobalShortcut, excluding tool: Self,
                                 bindingsRaw: String?) -> BindingRejection? {
        if isReservedEditorKey(key) || ownKey(storage: key.storageValue) == nil { return .reserved }
        let bindings = bindings(from: bindingsRaw)
        if let other = editorTools.first(where: { $0 != tool && bindings[$0] == key }) {
            return .tool(other)
        }
        return nil
    }

    /// A recorded digit moves the tool into that slot and drops its own key;
    /// clearing drops the own key and moves the tool below the first nine.
    /// Other own keys stay with their tools through reorders.
    static func assigningBinding(_ key: GlobalShortcut?, digit: Int? = nil, to tool: Self,
                                 orderRaw: String?, bindingsRaw: String?)
        -> (orderRaw: String, bindingsRaw: String) {
        var bindings = bindings(from: bindingsRaw)
        bindings[tool] = digit == nil ? key : nil
        let order = key == nil || digit != nil
            ? assigningShortcut(digit, to: tool, orderRaw: orderRaw)
            : ordered(from: orderRaw)
        return (storage(order), bindingsStorage(bindings))
    }

    /// The tool a key press picks, or nil. A typed digit picks its rail
    /// slot unless that tool has a key of its own; any other bare key picks
    /// the tool it belongs to. Nothing while tool keys are off.
    static func shortcutTool(keyCode: Int64, modifiers: GlobalShortcutModifiers, typed: String?,
                             orderRaw: String?, bindingsRaw: String?, enabled: Bool) -> Self? {
        guard enabled, !modifiers.hasPrimaryModifier else { return nil }
        let bindings = bindings(from: bindingsRaw)
        if let typed, let number = Int(typed), (1...shortcutLimit).contains(number) {
            guard let tool = shortcutTool(number: number, orderRaw: orderRaw, enabled: true),
                  bindings[tool] == nil
            else { return nil }
            return tool
        }
        let key = GlobalShortcut(keyCode: keyCode, modifiers: modifiers)
        return editorTools.first { bindings[$0] == key }
    }

    /// What the rail badge and the order controls show: the tool's own key,
    /// or the slot digit of a tool without one in the first nine.
    static func shortcutLabel(for tool: Self, orderRaw: String?, bindingsRaw: String?,
                              enabled: Bool) -> String? {
        guard enabled else { return nil }
        if let key = bindings(from: bindingsRaw)[tool] { return key.displayString }
        return shortcutNumber(for: tool, orderRaw: orderRaw, enabled: true).map(String.init)
    }
}
