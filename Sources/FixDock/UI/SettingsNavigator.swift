// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Combine
import SwiftUI

/// App pages present in every build. Declaration order is sidebar order
/// within each block.
enum ShellPage: String, CaseIterable, Identifiable, Hashable {
    case general, features, shortcut, about, updateLog, advanced

    var id: String { rawValue }

    /// The untitled top block or the App category at the bottom.
    var section: SidebarSection.ID {
        switch self {
        case .general, .features: return .main
        case .shortcut, .about, .updateLog, .advanced: return .app
        }
    }

    func title(_ strings: Strings) -> String {
        switch self {
        case .general: return strings.tabGeneral
        case .features: return strings.tabFeatures
        case .shortcut: return strings.tabShortcut
        case .about: return strings.tabAbout
        case .updateLog: return strings.tabUpdateLog
        case .advanced: return strings.tabAdvanced
        }
    }

    /// Symbols from the upstream settings sidebar (`SettingsDirectory`).
    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .features: return "square.grid.2x2"
        case .shortcut: return "command"
        case .about: return "info.circle"
        case .updateLog: return "list.bullet.rectangle"
        case .advanced: return "slider.horizontal.3"
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

/// What a sidebar row selects: a page, or a search result (several results
/// can open the same page, so each needs its own tag).
enum SidebarRow: Hashable {
    case destination(SettingsDestination)
    case result(SettingsSearchItem)
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
/// selection, the back/forward history and sidebar collapse state. Reads
/// availability from `FeatureRuntime`; never writes it. Main thread only, like
/// `FeatureRuntime`.
///
/// Collapse resets to all-expanded whenever the settings window opens; history
/// and the search query reset when a closed window opens. Nothing is saved in
/// UserDefaults.
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

    /// Pages left by `open`, most recent last. Only page changes are recorded,
    /// never the Features sub-tab. Every entry is reachable and none equals
    /// its neighbour.
    @Published private(set) var backStack: [SettingsDestination] = []
    @Published private(set) var forwardStack: [SettingsDestination] = []

    /// The sidebar search field. Non-blank replaces the sections with results.
    @Published var searchQuery = "" {
        didSet {
            if searchQuery != oldValue { searchSelection = nil }
        }
    }

    /// The result row last chosen for the current query.
    @Published private var searchSelection: SettingsSearchItem?

    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    private var installWatch: AnyCancellable?

    private init() {
        sections = Self.buildSections()
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Labels on reachable pages that match the query, in sidebar order.
    func searchResults(_ strings: Strings) -> [SettingsSearchItem] {
        SettingsSearch.results(for: searchQuery,
                               in: SettingsSearch.index(of: sections.flatMap(\.destinations)),
                               strings: strings)
    }

    /// For the sidebar `List(selection:)`. Ignores `nil` (click on empty
    /// space or a category header).
    var selection: Binding<SidebarRow?> {
        Binding(
            get: {
                if self.isSearching { return self.searchSelection.map(SidebarRow.result) }
                return .destination(self.destination)
            },
            set: { newValue in
                switch newValue {
                case nil:
                    return
                case .destination(let destination):
                    self.open(destination)
                case .result(let item):
                    self.searchSelection = item
                    self.open(item.destination, tab: item.tab)
                }
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
    /// that holds the target. Opening Features always shows `tab`. A page
    /// change is recorded for Back and drops the forward history.
    func open(_ destination: SettingsDestination, tab: FeaturesTab = .features) {
        guard isReachable(destination) else { return }
        if destination == .shell(.features) {
            featuresTab = tab
        }
        if destination != self.destination {
            backStack.append(self.destination)
            forwardStack.removeAll()
        }
        show(destination)
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(destination)
        show(target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(destination)
        show(target)
    }

    func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    private func show(_ destination: SettingsDestination) {
        if let section = sections.first(where: { $0.destinations.contains(destination) }) {
            collapsed.remove(section.id)
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

    /// Hook for a closed Settings window opening again. The page is unchanged.
    func resetHistoryAndSearch() {
        backStack = []
        forwardStack = []
        searchQuery = ""
    }

    private func refreshFromRuntime() {
        sections = Self.buildSections()
        if !isReachable(destination) {
            destination = .shell(.features)
        }
        backStack = Self.pruned(backStack, current: destination, keeping: isReachable)
        forwardStack = Self.pruned(forwardStack, current: destination, keeping: isReachable)
        if let item = searchSelection, !isReachable(item.destination) {
            searchSelection = nil
        }
    }

    /// Drops pages that are no longer reachable, then the repeats that leaves:
    /// adjacent equal entries, and a top entry equal to `current` (a step that
    /// would not move).
    private static func pruned(_ stack: [SettingsDestination],
                               current: SettingsDestination,
                               keeping isReachable: (SettingsDestination) -> Bool) -> [SettingsDestination] {
        var result: [SettingsDestination] = []
        for destination in stack where isReachable(destination) && destination != result.last {
            result.append(destination)
        }
        if result.last == current {
            result.removeLast()
        }
        return result
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
