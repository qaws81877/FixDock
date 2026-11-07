// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import SwiftUI

/// The Settings window. The toolbar shows the current page's title, as in
/// System Settings: a hosted view's `navigationTitle` did not reach the
/// window, so the window title follows the navigator.
final class SettingsWindow: NSWindow {
    private var titleWatch: AnyCancellable?

    convenience init() {
        let host = NSHostingController(rootView: SettingsView())
        host.sceneBridgingOptions = [.toolbars]
        self.init(contentViewController: host)
        // No full size content: with it the toolbar capsule sits past the
        // sidebar, not next to the traffic lights.
        styleMask = [.titled, .closable, .miniaturizable, .resizable]
        setContentSize(NSSize(width: 780, height: 540))
        minSize = NSSize(width: 680, height: 440)
        isReleasedWhenClosed = false
        titleWatch = SettingsNavigator.shared.$destination
            .combineLatest(L10n.shared.$language)
            .sink { [weak self] destination, language in
                self?.title = destination.title(Strings.localized(language))
            }
    }

    /// Grows the window so the whole expanded sidebar fits, down to the App
    /// block's last row (Advanced), within the screen's visible height.
    /// Never shrinks below the current size. Call before showing the window.
    func fitHeightToSidebar() {
        contentView?.layoutSubtreeIfNeeded()
        guard let table = Self.sidebarTable(in: contentView),
              let scroll = table.enclosingScrollView,
              table.numberOfRows > 0 else { return }
        let lastRow = table.rect(ofRow: table.numberOfRows - 1)
        let insets = scroll.contentInsets
        let needed = lastRow.maxY + insets.top + insets.bottom + 8
        let extra = ceil(needed - scroll.frame.height)
        guard extra > 0 else { return }
        var target = frame
        target.size.height += extra
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            target.size.height = min(target.size.height, visible.height)
        }
        target.origin.y = frame.maxY - target.size.height
        setFrame(target, display: false)
    }

    /// The sidebar List's table: the first one in the view tree, since the
    /// split view puts the sidebar column before the detail.
    private static func sidebarTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = sidebarTable(in: child) { return table }
        }
        return nil
    }
}

struct SettingsView: View {
    @ObservedObject private var navigator = SettingsNavigator.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let strings = l10n.s
        NavigationSplitView(columnVisibility: $navigator.columnVisibility) {
            sidebar(strings)
                .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 280)
                // A hosted split view opened its sidebar at 144 pt, ignoring
                // the ideal width above.
                .frame(minWidth: 200)
                .searchable(text: $navigator.searchQuery, placement: .sidebar,
                            prompt: Text(strings.settingsSearchPrompt))
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ScrollView {
                page(for: navigator.destination)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar {
                // One group, so the toggle and Back/Forward share one capsule
                // with the title after it.
                ToolbarItemGroup(placement: .navigation) {
                    navigationButtons(strings)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private func navigationButtons(_ strings: Strings) -> some View {
        let sidebarLabel = navigator.columnVisibility == .detailOnly ? strings.settingsShowSidebar : strings.settingsHideSidebar
        Button {
            withAnimation { navigator.toggleSidebar() }
        } label: {
            Label(sidebarLabel, systemImage: "sidebar.left")
        }
        .help(sidebarLabel)
        .keyboardShortcut("s", modifiers: [.command, .control])
        Button {
            navigator.goBack()
        } label: {
            Label(strings.settingsBack, systemImage: "chevron.left")
        }
        .help(strings.settingsBack)
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!navigator.canGoBack)
        Button {
            navigator.goForward()
        } label: {
            Label(strings.settingsForward, systemImage: "chevron.right")
        }
        .help(strings.settingsForward)
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!navigator.canGoForward)
    }

    private func sidebar(_ strings: Strings) -> some View {
        let results = navigator.isSearching ? navigator.searchResults(strings) : []
        // Category headers are untagged rows, not Section headers: on
        // macOS 27, List(selection:) hid Section headers.
        return List(selection: navigator.selection) {
            if navigator.isSearching {
                ForEach(results, id: \.self) { item in
                    resultRow(item, strings)
                        .tag(SidebarRow.result(item))
                }
            } else {
                ForEach(navigator.sections) { section in
                    sidebarSection(section, strings)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if navigator.isSearching, results.isEmpty {
                ContentUnavailableView(
                    String(format: strings.settingsSearchNoResultsFormat, navigator.searchQuery),
                    systemImage: "magnifyingglass"
                )
            }
        }
    }

    private func resultRow(_ item: SettingsSearchItem, _ strings: Strings) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title(strings))
                Text(item.location(strings))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: item.destination.symbolName)
        }
    }

    @ViewBuilder
    private func sidebarSection(_ section: SidebarSection, _ strings: Strings) -> some View {
        if let title = section.id.title(strings) {
            Section {
                sectionHeader(section.id, title: title, strings)
                if navigator.isExpanded(section.id) {
                    destinationRows(section.destinations, strings)
                }
            }
        } else {
            Section {
                destinationRows(section.destinations, strings)
            }
        }
    }

    /// Tap gesture rather than `DisclosureHeaderRow`: a Button in this sidebar
    /// List did not receive clicks, while tap-gesture rows do.
    private func sectionHeader(_ id: SidebarSection.ID, title: String, _ strings: Strings) -> some View {
        let expanded = navigator.isExpanded(id)
        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                navigator.expansion(of: id).wrappedValue.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(expanded ? strings.disclosureExpanded : strings.disclosureCollapsed)
    }

    @ViewBuilder
    private func destinationRows(_ destinations: [SettingsDestination], _ strings: Strings) -> some View {
        ForEach(destinations, id: \.self) { destination in
            Label(destination.title(strings), systemImage: destination.symbolName)
                .tag(SidebarRow.destination(destination))
        }
    }

    @ViewBuilder
    private func page(for destination: SettingsDestination) -> some View {
        switch destination {
        case .shell(.general): GeneralSettingsPage()
        case .shell(.features): FeaturesSettingsPage()
        case .shell(.shortcut): ShortcutRecorder().settingsCard()
        case .shell(.about): AboutSettingsPage()
        case .shell(.updateLog): UpdateLogPage()
        case .shell(.advanced): AdvancedSettingsPage()
        case .feature(let page): page.body()
        }
    }
}

private struct GeneralSettingsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var launchAtLogin = UserDefaults.standard.bool(forKey: DefaultsKey.launchAtLoginWanted)
    @State private var loginMessage: String?
    @State private var showsFeedback = false

    var body: some View {
        let strings = l10n.s
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(strings.languageTitle).font(.headline)
                    Text(strings.languageCaption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(strings.languageTitle, selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .settingsCard()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(strings.launchAtLogin).font(.headline)
                        Text(strings.launchAtLoginCaption)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle(strings.launchAtLogin, isOn: Binding(
                        get: { launchAtLogin },
                        set: { applyLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                if let loginMessage {
                    Text(loginMessage)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsCard()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(strings.feedbackTitle).font(.headline)
                    Text(strings.feedbackSectionCaption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(strings.feedbackButton) { showsFeedback = true }
            }
            .settingsCard()
            .sheet(isPresented: $showsFeedback) { FeedbackSheet() }

            Button(strings.relaunch) { appDelegate()?.relaunch() }
        }
        .onAppear { refreshLogin() }
    }

    private func refreshLogin() {
        LaunchAtLogin.refresh { registration in
            launchAtLogin = registration == .enabled
        }
    }

    private func applyLogin(_ enabled: Bool) {
        LaunchAtLogin.setEnabled(enabled) { registration, error in
            switch registration {
            case .enabled:
                launchAtLogin = true
            case .needsApproval:
                launchAtLogin = enabled
            case .off:
                launchAtLogin = false
            }
            loginMessage = error?.localizedDescription
        }
    }
}

/// Settings only. Onboarding shows `FeatureHubList` on its own.
private struct FeaturesSettingsPage: View {
    @ObservedObject private var navigator = SettingsNavigator.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let strings = l10n.s
        VStack(alignment: .leading, spacing: 16) {
            Picker(strings.tabFeatures, selection: navigator.featuresTabSelection) {
                ForEach(FeaturesTab.allCases) { tab in
                    Text(tab.title(strings)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            switch navigator.featuresTab {
            case .features:
                InstalledSummaryCard()
                FeatureHubList(showsInstallButtons: true, showsBulkButtons: false)
            case .permissions:
                PermissionsTab()
            }
        }
    }
}

private struct InstalledSummaryCard: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var runtime = FeatureRuntime.shared

    var body: some View {
        let strings = l10n.s
        let tools = AppFeature.allCases.filter(\.hasService)
        let installed = tools.filter(\.isAvailable).count
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: strings.featuresInstalledCountFormat, installed, tools.count))
                    .font(.headline)
                    .monospacedDigit()
                ProgressView(value: Double(installed), total: Double(tools.count))
                    .progressViewStyle(.linear)
            }
            Spacer(minLength: 8)
            FeatureBulkButtons()
        }
        .settingsCard()
    }
}

/// `setPageVisible` follows this view's onAppear and onDisappear, which fire
/// on a tab or page switch but not when the reused window closes.
private struct PermissionsTab: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var runtime = FeatureRuntime.shared

    var body: some View {
        let strings = l10n.s
        let needed = Set(runtime.installedFeatures.flatMap(\.requiredPermissions))
        VStack(alignment: .leading, spacing: 12) {
            Text(strings.permissionsIntro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(PermissionKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.title(strings)).font(.headline)
                    Text(kind.detail(strings))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(needed.contains(kind) ? strings.permissionNeededNow : strings.permissionNotNeededYet)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if permissions.isGranted(kind) {
                        Label(strings.permissionGranted, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(strings.permissionRequest) { permissions.request(kind) }
                    }
                }
                .settingsCard()
            }
        }
        .onAppear {
            permissions.refresh()
            permissions.setPageVisible(true)
        }
        .onDisappear { permissions.setPageVisible(false) }
    }
}

private struct AboutSettingsPage: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let strings = l10n.s
        VStack(alignment: .leading, spacing: 16) {
            about(strings)
            UpdatesSection()
        }
    }

    private func about(_ strings: Strings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AppIconImage(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppInfo.name).font(.title2.weight(.semibold))
                    Text(String(format: strings.versionFormat, AppInfo.version))
                        .foregroundStyle(.secondary)
                }
            }
            Text(strings.aboutFork)
                .fixedSize(horizontal: false, vertical: true)
            Text(strings.aboutLicense)
                .fixedSize(horizontal: false, vertical: true)
            Text(strings.aboutNoTelemetry)
            HStack {
                Button(strings.aboutRepositoryButton) {
                    NSWorkspace.shared.open(AppInfo.repositoryURL)
                }
                Button(strings.aboutUpstreamButton) {
                    NSWorkspace.shared.open(AppInfo.upstreamURL)
                }
                Button("GPL-3.0") {
                    NSWorkspace.shared.open(AppInfo.licenseURL)
                }
            }
        }
        .settingsCard()
    }
}

/// Each release's changes from `Changelog`, in the app's language.
private struct UpdateLogPage: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let strings = l10n.s
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Changelog.entries, id: \.version) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: strings.versionFormat, entry.version))
                            .font(.headline)
                        Spacer(minLength: 8)
                        Text(entry.date)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ForEach(Array(items(of: entry).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(ReleaseNotesText.inline(item))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsCard()
            }
        }
        .textSelection(.enabled)
    }

    private func items(of entry: ChangelogEntry) -> [String] {
        switch l10n.language {
        case .enUS: return entry.english
        case .ko: return entry.korean
        }
    }
}
