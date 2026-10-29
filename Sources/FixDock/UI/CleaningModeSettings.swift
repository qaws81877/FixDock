// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// Adapted from the cleaning section of upstream's quick tools page.
struct CleaningModeSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.cleaningModeKeepScreenVisible) private var keepScreenVisible = false
    @AppStorage(DefaultsKey.cleaningModeClickPolicy) private var clickPolicy = CleaningClickPolicy.allowClicks.rawValue
    private var s: Strings { l10n.s }

    var body: some View {
        Form {
            Section {
                Button {
                    CleaningModeManager.shared.activate()
                } label: {
                    Label(s.cleaningModeStartNow, systemImage: AppFeature.cleaningMode.symbolName)
                }
                Text(s.cleaningModePanelCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(s.cleaningModeUnlockCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !permissions.accessibility {
                    Label(s.cleaningModeNeedsAccessibility, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(s.permissionRequest) { permissions.request(.accessibility) }
                }
            }
            Section {
                Picker(s.cleaningModeClickPolicyTitle, selection: $clickPolicy) {
                    Text(s.cleaningModeClickPolicyAllow).tag(CleaningClickPolicy.allowClicks.rawValue)
                    Text(s.cleaningModeClickPolicyHold).tag(CleaningClickPolicy.holdToUnlock.rawValue)
                    Text(s.cleaningModeClickPolicyBlock).tag(CleaningClickPolicy.blockClicks.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text(s.cleaningModeClickPolicyCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(s.cleaningModeKeepScreenVisibleToggle, isOn: $keepScreenVisible)
                Text(s.cleaningModeKeepScreenVisibleCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }
}
