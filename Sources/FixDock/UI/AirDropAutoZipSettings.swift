// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// AirDrop auto-zip's page: the switch, the level and what happens. Batches
/// are reported by notification only; no history is kept on screen. New in
/// FixDock.
struct AirDropAutoZipSettingsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = AirDropAutoZipService.shared
    @AppStorage(DefaultsKey.airdropAutoZipEnabled) private var enabled = false
    private var s: Strings { l10n.s }

    var body: some View {
        Form {
            Section {
                Toggle(s.airdropEnable, isOn: $enabled)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
                AirDropStatusLine()
            }

            Section {
                MediaPresetBar(key: DefaultsKey.airdropAutoZipPreset, tool: .image)
            }

            Section(s.airdropHowTitle) {
                ForEach([s.airdropHowCandidates, s.airdropHowBatch, s.airdropHowZip,
                         s.airdropHowOriginals, s.airdropHowOthers, s.airdropHowLocation], id: \.self) { line in
                    Label(line, systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(s.airdropOpenDownloads) { NSWorkspace.shared.open(service.folder) }
            }
        }
        .formStyle(.grouped)
        .onAppear { service.syncWithPreferences() }
    }
}

/// Watching, waiting, or why not.
struct AirDropStatusLine: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = AirDropAutoZipService.shared

    var body: some View {
        let s = l10n.s
        if service.folderUnavailable {
            Label(s.airdropFolderUnavailable, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if service.isProcessing {
            Label(s.airdropProcessing, systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if service.isWatching {
            Label(s.airdropWatching, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }
}

/// The menu panel row: the switch and the status.
struct PanelAirDropRow: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = AirDropAutoZipService.shared
    @AppStorage(DefaultsKey.airdropAutoZipEnabled) private var enabled = false

    var body: some View {
        let s = l10n.s
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: AppFeature.airdropAutoZip.symbolName)
                    .frame(width: 16)
                Text(AppFeature.airdropAutoZip.title(s))
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
            }
            AirDropStatusLine()
        }
    }
}
