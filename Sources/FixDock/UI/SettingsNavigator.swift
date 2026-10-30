// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Combine
import SwiftUI

/// App pages present in every build. Declaration order is sidebar order.
enum ShellPage: String, CaseIterable, Identifiable, Hashable {
    case general, features, shortcut, permissions, about

    var id: String { rawValue }

    func title(_ strings: Strings) -> String {
        switch self {
        case .general: return strings.tabGeneral
        case .features: return strings.tabFeatures
        case .shortcut: return strings.tabShortcut
        case .permissions: return strings.tabPermissions
        case .about: return strings.tabAbout
        }
    }

    /// Symbols from the upstream settings sidebar (`SettingsDirectory`).
    /// Upstream had no permissions page; `hand.raised` is its permission glyph.
    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .features: return "square.grid.2x2"
        case .shortcut: return "command"
        case .permissions: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

/// Everything the Settings right pane can show.
enum SettingsDestination: Hashable {
    case shell(ShellPage)
    case feature(FeaturePage)

    func title(_ strings: Strings) -> String {
        switch self {
        case .shell(let page): return page.title(strings)
        case .feature(let page): return page.feature.pageTitle(strings)
        }
    }

    var symbolName: String {
        switch self {
        case .shell(let page): return page.symbolName
        case .feature(let page): return page.feature.symbolName
        }
    }
}

/// One sidebar block, already filtered and ordered. Built only in this file,
/// so no other file can produce an empty category header.
struct SidebarSection: Identifiable {
    enum ID: Hashable {
        /// Shell pages. Never collapses. Flat untitled block above categories (L1).
        case app
        case category(FeatureGroup)
    }

    let id: ID
    /// Never empty.
    let destinations: [SettingsDestination]

    fileprivate init(id: ID, destinations: [SettingsDestination]) {
        precondition(!destinations.isEmpty)
        self.id = id
        self.destinations = destinations
    }
}

/// Owns where Settings is and what its sidebar shows: the only writer of the
/// selection and of sidebar collapse state. Reads availability from
/// `FeatureRuntime`; never writes it. Main thread only, like `FeatureRuntime`.
///
/// Collapse resets to all-expanded whenever the settings window opens. There is
/// no UserDefaults key for collapse.
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()

    /// Sidebar blocks in display order. Empty categories are absent.
    @Published private(set) var sections: [SidebarSection] = []

    /// What the right pane shows. Always reachable: installed and has a page.
    /// May sit inside a collapsed category; collapse never moves it.
    @Published private(set) var destination: SettingsDestination = .shell(.general)

    @Published private var collapsed: Set<FeatureGroup> = []

    private var installWatch: AnyCancellable?

    private init() {
        sections = Self.buildSections()
    }

    /// For the sidebar `List(selection:)`. Ignores `nil` (click on empty
    /// space or a category header).
    var selection: Binding<SettingsDestination?> {
        Binding(
            get: { self.destination },
            set: { newValue in
                guard let newValue else { return }
                self.open(newValue)
            }
        )
    }

    func isExpanded(_ group: FeatureGroup) -> Bool {
        !collapsed.contains(group)
    }

    /// For the sidebar `DisclosureHeaderRow`. Collapse never moves the selection.
    func expansion(of group: FeatureGroup) -> Binding<Bool> {
        Binding(
            get: { self.isExpanded(group) },
            set: { expanded in
                if expanded {
                    self.collapsed.remove(group)
                } else {
                    self.collapsed.insert(group)
                }
            }
        )
    }

    /// Programmatic navigation. No-op when unreachable. Expands the target's category.
    func open(_ destination: SettingsDestination) {
        guard isReachable(destination) else { return }
        if case .feature(let page) = destination {
            collapsed.remove(page.feature.group)
        }
        self.destination = destination
    }

    /// Call once after `FeatureRuntime.shared.syncAtLaunch()`. Creates the
    /// navigator before any window so installs made in onboarding are seen.
    func syncAtLaunch() {
        if installWatch == nil {
            installWatch = FeatureRuntime.shared.$revision
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshFromRuntime()
                }
        }
        refreshFromRuntime()
    }

    /// Settings window open hook. Collapse returns to the product default
    /// (all expanded). Selection is unchanged.
    func resetExpansion() {
        collapsed = []
    }

    private func refreshFromRuntime() {
        sections = Self.buildSections()
        if !isReachable(destination) {
            destination = .shell(.features)
        }
    }

    private func isReachable(_ destination: SettingsDestination) -> Bool {
        switch destination {
        case .shell:
            return true
        case .feature(let page):
            return page.feature.isAvailable && page.feature.settingsPage != nil
        }
    }

    /// L1: untitled shell block first, then non-empty feature categories (P1:
    /// only installed features that have a settings page).
    private static func buildSections() -> [SidebarSection] {
        var result: [SidebarSection] = [
            SidebarSection(
                id: .app,
                destinations: ShellPage.allCases.map { .shell($0) }
            )
        ]
        for group in FeatureGroup.allCases {
            let destinations = group.features.compactMap { feature -> SettingsDestination? in
                guard feature.isAvailable, let page = feature.settingsPage else { return nil }
                return .feature(page)
            }
            if !destinations.isEmpty {
                result.append(SidebarSection(id: .category(group), destinations: destinations))
            }
        }
        return result
    }
}
