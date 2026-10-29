// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// The rail order the person chose and the keys 1 to 9 it gives the first
/// nine tools. The order is stored as comma-separated tool ids; anything the
/// stored text lacks (a tool added by a later version) follows in the
/// canonical order, so new tools slot in without a migration. Adapted from
/// upstream's `Tool.ordered` and `assigningShortcut`, without its custom
/// non-digit key bindings.
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
}
