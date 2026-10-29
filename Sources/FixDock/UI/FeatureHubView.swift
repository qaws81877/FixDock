// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// The feature catalog as a list. Settings and onboarding both show install
/// buttons when `showsInstallButtons` is true.
struct FeatureHubList: View {
    var showsInstallButtons: Bool
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var runtime = FeatureRuntime.shared

    var body: some View {
        let strings = l10n.s
        VStack(alignment: .leading, spacing: 14) {
            if showsInstallButtons {
                Text(strings.featuresIntro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(strings.featuresInstallAll) {
                        runtime.setAvailable(Array(AppFeature.allCases), true)
                    }
                    Button(strings.featuresRemoveAll) {
                        runtime.setAvailable(Array(AppFeature.allCases), false)
                    }
                }
                if runtime.needsRestartToUnload {
                    HStack {
                        Text(strings.featuresRestartTitle)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(strings.featuresRestartButton) { appDelegate()?.relaunch() }
                    }
                    .settingsCard()
                }
            }
            ForEach(FeatureGroup.allCases) { group in
                let features = group.features
                if !features.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle(group.title(strings))
                        ForEach(features) { feature in
                            FeatureRow(feature: feature, showsInstallButton: showsInstallButtons)
                        }
                    }
                }
            }
        }
        .id(runtime.revision)
    }
}

struct FeatureRow: View {
    let feature: AppFeature
    var showsInstallButton: Bool
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var runtime = FeatureRuntime.shared

    var body: some View {
        let strings = l10n.s
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: feature.symbolName)
                .font(.system(size: 16))
                .frame(width: 24, height: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title(strings))
                    .font(.system(size: 13, weight: .semibold))
                Text(feature.summary(strings))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !feature.hasService {
                    Text(strings.panelNotInBuild)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if showsInstallButton {
                Button(feature.isAvailable ? strings.featuresRemove : strings.featuresInstall) {
                    let turningOn = !feature.isAvailable
                    runtime.setAvailable([feature], turningOn)
                    if turningOn, let page = feature.settingsPage {
                        SettingsNavigator.shared.open(.feature(page))
                    }
                }
                .controlSize(.small)
            }
        }
        .settingsCard()
    }
}
