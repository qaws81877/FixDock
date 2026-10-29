// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The menu bar panel. URL cleaner runs here once it is installed. The
/// other catalog entries are saved choices and do not run yet.
struct MenuPanelView: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var runtime = FeatureRuntime.shared

    var body: some View {
        let strings = l10n.s
        let waiting = runtime.installedFeatures.filter { !$0.hasService }
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
                if cleanerInstalled {
                    PanelURLCleanerView(onClose: { appDelegate()?.closePopover() })
                }
                if waiting.isEmpty, !cleanerInstalled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(strings.panelEmptyTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text(strings.panelEmptyBody)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .settingsCard()
                } else if !waiting.isEmpty {
                    sectionTitle(strings.panelInstalledHeading)
                    ForEach(waiting) { feature in
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
}
