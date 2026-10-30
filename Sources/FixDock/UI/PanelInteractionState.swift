// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine

/// Shared state between the panel content and the AppKit popover host.
/// Adapted from upstream: the hosted sub-view is the one stored fact, and
/// everything the popover asks is derived from it, so nothing goes stale
/// when the popover closes without its views seeing `onDisappear`.
final class PanelInteractionState: ObservableObject {
    static let shared = PanelInteractionState()

    /// The tool whose sub-view the panel shows instead of its cards, or nil.
    /// Only tools with a panel sub-view (media, URL cleaner) are ever set.
    @Published var hostedTool: AppFeature?

    /// The hosted tool while it is still installed. Uninstalling it while its
    /// sub-view is up drops the panel back to its cards.
    var activeHostedTool: AppFeature? {
        guard let hostedTool, hostedTool.isAvailable else { return nil }
        return hostedTool
    }

    /// A sub-view turns the panel into a work surface whose use spans clicks
    /// in other apps (a file dragged from Finder onto the media drop zone, a
    /// link copied in a browser), so an outside click must not close it.
    var viewKeepsPopoverOpen: Bool {
        activeHostedTool != nil
    }

    /// The Settings page of the hosted tool, so the footer's Settings button
    /// lands on it instead of on the general page.
    var hostedSettingsPage: FeaturePage? {
        activeHostedTool?.settingsPage
    }

    /// The one answer every outside-click dismissal path uses.
    var preventsPopoverDismissal: Bool {
        viewKeepsPopoverOpen
    }

    /// The screen the menu bar icon is on, so the panel caps its height
    /// against that display. Not published: the panel reads it while
    /// measuring itself, and a change mid layout would bounce the height.
    var anchorScreen: NSScreen?

    private init() {}
}

/// The two cards of the panel. Raw values are stored nowhere; the keys are.
enum PanelCard: String, CaseIterable, Identifiable {
    case quickActions
    case onAndOff

    var id: String { rawValue }

    /// The card's rows in their default order (catalog order within the card).
    var defaultOrder: [AppFeature] {
        switch self {
        case .quickActions:
            return [.screenshot, .screenRecorder, .cleaningMode, .mediaTools, .urlCleaner, .cleaner]
        case .onAndOff:
            return [.quitWindowProtection, .textSnippets, .airdropAutoZip]
        }
    }

    var orderKey: String {
        switch self {
        case .quickActions: return DefaultsKey.panelQuickActionsOrder
        case .onAndOff: return DefaultsKey.panelOnOffOrder
        }
    }

    func title(_ strings: Strings) -> String {
        switch self {
        case .quickActions: return strings.panelQuickActionsTitle
        case .onAndOff: return strings.panelOnOffTitle
        }
    }
}

/// Saved panel layout: each card's order and the hidden rows. Reads are
/// sanitized by `PanelLayoutSupport`, so a damaged or older value never
/// loses a row.
enum PanelLayout {
    private static var defaults: UserDefaults { .standard }

    static func order(_ card: PanelCard) -> [AppFeature] {
        let ids = PanelLayoutSupport.sanitizedOrder(
            saved: defaults.string(forKey: card.orderKey) ?? "",
            defaultOrder: card.defaultOrder.map(\.rawValue))
        return ids.compactMap(AppFeature.init(rawValue:))
    }

    static func setOrder(_ order: [AppFeature], for card: PanelCard) {
        defaults.set(PanelLayoutSupport.encodeOrder(order.map(\.rawValue)), forKey: card.orderKey)
    }

    static var allRowIDs: [String] {
        PanelCard.allCases.flatMap { $0.defaultOrder.map(\.rawValue) }
    }

    static func hidden() -> Set<String> {
        PanelLayoutSupport.sanitizedHidden(saved: defaults.string(forKey: DefaultsKey.panelHiddenRows) ?? "",
                                           allowed: allRowIDs)
    }

    static func isHidden(_ feature: AppFeature) -> Bool {
        hidden().contains(feature.rawValue)
    }

    static func setHidden(_ hidden: Bool, for feature: AppFeature) {
        let updated = PanelLayoutSupport.settingHidden(hidden, id: feature.rawValue, in: self.hidden())
        defaults.set(PanelLayoutSupport.encodeHidden(updated), forKey: DefaultsKey.panelHiddenRows)
    }

    /// The card's default order, and every one of its rows shown again.
    /// The other card is left as it is.
    static func reset(_ card: PanelCard) {
        defaults.removeObject(forKey: card.orderKey)
        let mine = Set(card.defaultOrder.map(\.rawValue))
        let remaining = hidden().subtracting(mine)
        defaults.set(PanelLayoutSupport.encodeHidden(remaining), forKey: DefaultsKey.panelHiddenRows)
    }
}

extension NSScreen {
    /// Whether this display is still plugged in, by display id: AppKit may
    /// hand out fresh NSScreen objects after a reconfiguration.
    var isStillAttached: Bool {
        let id = displayID
        guard id != 0 else { return false }
        return NSScreen.screens.contains { $0.displayID == id }
    }

    /// The display that owns the menu bar: the one at the origin. `main`
    /// follows the key window and is the wrong answer for the bar.
    static var withMenuBar: NSScreen? {
        screens.first { $0.frame.origin == .zero } ?? screens.first
    }
}
