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
        let cleanerInstalled = AppFeature.urlCleaner.isAvailable
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
        .frame(width: 320, height: cleanerInstalled ? 560 : 420)
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
        case .quitWindowProtection, .cleaningMode, .textSnippets,
             .airdropAutoZip, .cleaner, .screenshot, .screenRecorder:
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
