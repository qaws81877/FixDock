// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics
import Foundation

/// Pure rules for the menu bar panel: the saved row order, the hidden rows
/// and the panel's height. No AppKit, so a harness compiles it on its own.
/// The height formula and the order format follow upstream's panel.
enum PanelLayoutSupport {

    // MARK: - Order

    /// The saved order of one card's rows. Ids not in `defaultOrder` and
    /// repeats are dropped. A row the saved order does not know yet (a tool
    /// added in a later build) goes back to its default place: right after
    /// the nearest row that comes before it by default, or first when none
    /// does. So a row can never silently disappear, and a new one does not
    /// pile up at the end.
    static func sanitizedOrder(saved: String, defaultOrder: [String]) -> [String] {
        let allowed = Set(defaultOrder)
        var seen = Set<String>()
        var result: [String] = []
        for raw in saved.split(separator: ",") {
            let id = raw.trimmingCharacters(in: .whitespaces)
            guard allowed.contains(id), seen.insert(id).inserted else { continue }
            result.append(id)
        }
        for (index, id) in defaultOrder.enumerated() where !seen.contains(id) {
            seen.insert(id)
            let before = defaultOrder[..<index].reversed()
            if let neighbour = before.first(where: { result.contains($0) }),
               let position = result.firstIndex(of: neighbour) {
                result.insert(id, at: position + 1)
            } else {
                result.insert(id, at: 0)
            }
        }
        return result
    }

    static func encodeOrder(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    // MARK: - Hidden rows

    /// The rows hidden from the panel. Unknown ids are dropped.
    static func sanitizedHidden(saved: String, allowed: [String]) -> Set<String> {
        let known = Set(allowed)
        return Set(saved.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { known.contains($0) })
    }

    /// Sorted, so the stored text does not change with set order.
    static func encodeHidden(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }

    /// `hidden` with `id` shown or hidden.
    static func settingHidden(_ hidden: Bool, id: String, in set: Set<String>) -> Set<String> {
        var result = set
        if hidden { result.insert(id) } else { result.remove(id) }
        return result
    }

    /// The rows a card shows: in order, without the hidden ones unless the
    /// card is being edited (edit mode lists them with a Hidden badge).
    static func visibleRows(order: [String], hidden: Set<String>, editing: Bool) -> [String] {
        editing ? order : order.filter { !hidden.contains($0) }
    }

    // MARK: - Height

    /// Fallback when no screen is known yet.
    static let fallbackVisibleHeight: CGFloat = 760
    /// The popover's window is the panel plus 13 pt for the arrow and 13 pt
    /// below it. A window taller than the usable height makes AppKit open
    /// the popover beside the icon instead of under it, so the cap leaves
    /// those 26 pt and 2 more.
    static let screenMargin: CGFloat = 28
    static let minimumMaxHeight: CGFloat = 360
    /// Outer padding (12 + 12), header (about 36), footer (about 34) and the
    /// two 12 pt gaps between them and the scrolling content.
    static let chromeHeight: CGFloat = 120
    static let minimumScrollHeight: CGFloat = 80
    static let minimumPanelHeight: CGFloat = 200

    /// The tallest the panel may be on a screen whose visible frame (below
    /// the menu bar, above the Dock) is `visibleHeight` tall.
    static func maxHeight(visibleHeight: CGFloat?) -> CGFloat {
        max(minimumMaxHeight, (visibleHeight ?? fallbackVisibleHeight) - screenMargin)
    }

    /// The scrolling area: the content's measured height, or `estimated`
    /// before the first measurement, capped so the panel fits the screen.
    static func scrollHeight(measured: CGFloat, estimated: CGFloat,
                             maxHeight: CGFloat, chrome: CGFloat = chromeHeight) -> CGFloat {
        let content = measured <= 0 ? estimated : measured
        return min(content, max(minimumScrollHeight, maxHeight - chrome))
    }

    static func panelHeight(scrollHeight: CGFloat, maxHeight: CGFloat,
                            chrome: CGFloat = chromeHeight) -> CGFloat {
        min(maxHeight, max(minimumPanelHeight, scrollHeight + chrome))
    }

    /// A guess at the list's height before it has been measured once: each
    /// card is a header and its rows, with 12 pt between cards.
    static func estimatedContentHeight(rowsPerCard: [Int]) -> CGFloat {
        let cards = rowsPerCard.filter { $0 > 0 }
        guard !cards.isEmpty else { return 80 }
        let rows = cards.reduce(0, +)
        return CGFloat(cards.count) * 30 + CGFloat(rows) * 40 + CGFloat(cards.count - 1) * 12
    }

    /// Whether a new measurement differs enough to be applied. The 0.5 pt
    /// guard breaks the measure, resize, measure loop.
    static func shouldApply(measured: CGFloat, current: CGFloat) -> Bool {
        measured > 1 && abs(measured - current) > 0.5
    }
}
