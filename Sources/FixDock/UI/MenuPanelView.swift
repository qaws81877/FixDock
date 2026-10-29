// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The menu bar panel. Installed features are grouped by `FeatureGroup` with
/// collapse owned by `MenuPanelExpansion` (reset when the panel opens).
struct MenuPanelView: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var runtime = FeatureRuntime.shared
    @ObservedObject private var expansion = MenuPanelExpansion.shared

    var body: some View {
        let strings = l10n.s
        let installed = runtime.installedFeatures
        let tallPanel = AppFeature.urlCleaner.isAvailable || AppFeature.mediaTools.isAvailable
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppInfo.name)
                        .font(.system(size: 16, weight: .semibold))
                    Text(String(format: strings.versionFormat, AppInfo.version))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if installed.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(strings.panelEmptyTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text(strings.panelEmptyBody)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .settingsCard()
                } else {
                    ForEach(FeatureGroup.allCases) { group in
                        let features = group.features.filter(\.isAvailable)
                        if !features.isEmpty {
                            categoryBlock(group: group, features: features, strings: strings)
                        }
                    }
                }
                Divider()
                Button(strings.menuSettings) { appDelegate()?.openSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(strings.menuQuit) { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 320, height: tallPanel ? 560 : 420)
    }

    @ViewBuilder
    private func categoryBlock(group: FeatureGroup, features: [AppFeature], strings: Strings) -> some View {
        DisclosureHeaderRow(isExpanded: expansion.expansion(of: group)) {
            Text(group.title(strings))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        if expansion.isExpanded(group) {
            ForEach(features) { feature in
                installedFeatureContent(feature, strings: strings)
            }
        }
    }

    @ViewBuilder
    private func installedFeatureContent(_ feature: AppFeature, strings: Strings) -> some View {
        switch feature {
        case .urlCleaner:
            PanelURLCleanerView(onClose: { appDelegate()?.closePopover() })
        case .quitWindowProtection:
            PanelQuitProtectionRow()
        case .cleaningMode:
            PanelCleaningModeRow()
        case .textSnippets:
            PanelTextSnippetsRow()
        case .mediaTools:
            PanelMediaView()
        case .airdropAutoZip:
            PanelAirDropRow()
        case .cleaner, .screenshot, .screenRecorder:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: feature.symbolName)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(feature.title(strings))
                        .font(.system(size: 12, weight: .medium))
                    Text(strings.panelNotInBuild)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Quit protection has nothing to do from the panel; the row says whether it
/// is guarding and opens its Settings page.
private struct PanelQuitProtectionRow: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = QuitProtectionService.shared

    var body: some View {
        let strings = l10n.s
        Button {
            if let page = AppFeature.quitWindowProtection.settingsPage {
                SettingsNavigator.shared.open(.feature(page))
            }
            appDelegate()?.openSettings()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: AppFeature.quitWindowProtection.symbolName)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppFeature.quitWindowProtection.title(strings))
                        .font(.system(size: 12, weight: .medium))
                    Text(status(strings))
                        .font(.caption2)
                        .foregroundStyle(service.isWaitingForAccessibility ? .orange : .secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func status(_ strings: Strings) -> String {
        if service.isWaitingForAccessibility { return strings.quitProtectionNeedsAccessibility }
        if service.isRunning { return strings.quitProtectionActiveNow }
        return strings.featureQuitProtectionSummary
    }
}

/// Starts the lock from the panel. The panel closes first so, if the
/// Accessibility prompt has to show, it is not stranded under the open panel.
private struct PanelCleaningModeRow: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let strings = l10n.s
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: AppFeature.cleaningMode.symbolName)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppFeature.cleaningMode.title(strings))
                    .font(.system(size: 12, weight: .medium))
                Text(strings.cleaningModePanelCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(strings.cleaningModeStartNow) {
                appDelegate()?.closePopover()
                CleaningModeManager.shared.activate()
            }
            .controlSize(.small)
        }
    }
}

/// Snippets work while typing; the row counts them and opens their page.
private struct PanelTextSnippetsRow: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.textSnippets) private var stored = Data()

    var body: some View {
        let strings = l10n.s
        Button {
            if let page = AppFeature.textSnippets.settingsPage {
                SettingsNavigator.shared.open(.feature(page))
            }
            appDelegate()?.openSettings()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: AppFeature.textSnippets.symbolName)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppFeature.textSnippets.title(strings))
                        .font(.system(size: 12, weight: .medium))
                    Text(String(format: strings.snippetsCountFormat,
                                TextSnippetSupport.decode(stored.isEmpty ? nil : stored).count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
