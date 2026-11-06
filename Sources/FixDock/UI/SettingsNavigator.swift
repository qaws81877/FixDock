// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Combine
import SwiftUI

/// App pages present in every build. Declaration order is sidebar order
/// within each block.
enum ShellPage: String, CaseIterable, Identifiable, Hashable {
    case general, features, shortcut, about

    var id: String { rawValue }

    /// The untitled top block or the App category at the bottom.
    var section: SidebarSection.ID {
        switch self {
        case .general, .features: return .main
        case .shortcut, .about: return .app
        }
    }

    func title(_ strings: Strings) -> String {
        switch self {
        case .general: return strings.tabGeneral
        case .features: return strings.tabFeatures
        case .shortcut: return strings.tabShortcut
        case .about: return strings.tabAbout
        }
    }

    /// Symbols from the upstream settings sidebar (`SettingsDirectory`).
    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .features: return "square.grid.2x2"
        case .shortcut: return "command"
        case .about: return "info.circle"
        }
    }
}

/// The Features page's sub-tabs. Permissions lives here, not in the sidebar.
enum FeaturesTab: String, CaseIterable, Identifiable, Hashable {
    case features, permissions

    var id: String { rawValue }

    func title(_ strings: Strings) -> String {
        switch self {
        case .features: return strings.tabFeatures
        case .permissions: return strings.tabPermissions
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
        /// General and Features. Never collapses. Flat untitled block on top (L1).
        case main
        case category(FeatureGroup)
        /// App-level pages, the last block. Collapses like a category.
        case app

        /// Nil for the untitled main block.
        func title(_ strings: Strings) -> String? {
            switch self {
            case .main: return nil
            case .category(let group): return group.title(strings)
            case .app: return strings.groupApp
            }
        }
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

    /// Which sub-tab the Features page shows.
    @Published private(set) var featuresTab: FeaturesTab = .features

    @Published private var collapsed: Set<SidebarSection.ID> = []

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

    /// For the Features page's sub-tab picker.
    var featuresTabSelection: Binding<FeaturesTab> {
        Binding(
            get: { self.featuresTab },
            set: { self.featuresTab = $0 }
        )
    }

    func isExpanded(_ section: SidebarSection.ID) -> Bool {
        !collapsed.contains(section)
    }

    /// For the sidebar's tap-gesture header rows. Collapse never moves the
    /// selection.
    func expansion(of section: SidebarSection.ID) -> Binding<Bool> {
        Binding(
            get: { self.isExpanded(section) },
            set: { expanded in
                if expanded {
                    self.collapsed.remove(section)
                } else {
                    self.collapsed.insert(section)
                }
            }
        )
    }

    /// Programmatic navigation. No-op when unreachable. Expands the block
    /// that holds the target. Opening Features always shows `tab`.
    func open(_ destination: SettingsDestination, tab: FeaturesTab = .features) {
        guard isReachable(destination) else { return }
        if let section = sections.first(where: { $0.destinations.contains(destination) }) {
            collapsed.remove(section.id)
        }
        if destination == .shell(.features) {
            featuresTab = tab
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

    /// L1: untitled main block first, then non-empty feature categories (P1:
    /// only installed features that have a settings page), then App.
    private static func buildSections() -> [SidebarSection] {
        func shellPages(in section: SidebarSection.ID) -> [SettingsDestination] {
            ShellPage.allCases.filter { $0.section == section }.map { .shell($0) }
        }
        var result = [SidebarSection(id: .main, destinations: shellPages(in: .main))]
        for group in FeatureGroup.allCases {
            let destinations = group.features.compactMap { feature -> SettingsDestination? in
                guard feature.isAvailable, let page = feature.settingsPage else { return nil }
                return .feature(page)
            }
            if !destinations.isEmpty {
                result.append(SidebarSection(id: .category(group), destinations: destinations))
            }
        }
        result.append(SidebarSection(id: .app, destinations: shellPages(in: .app)))
        return result
    }
}
