// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardHistorySettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = ClipboardHistoryService.shared
    @ObservedObject private var ignored = ClipboardIgnoredApps.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.clipboardHistoryEnabled) private var enabled = false
    @AppStorage(DefaultsKey.clipboardHistoryRetentionDays) private var retentionDays =
        ClipboardHistoryRetention.default.rawValue
    @AppStorage(DefaultsKey.clipboardHistoryRecordsMedia) private var recordsMedia = true
    @AppStorage(DefaultsKey.clipboardHistoryImageBudgetMB) private var imageBudgetMB =
        ClipboardHistoryImageBudget.default.rawValue
    @State private var confirmation: [UUID: Date]?
    private var s: Strings { l10n.s }

    var body: some View {
        Form {
            Section {
                Toggle(s.clipboardHistoryEnable, isOn: $enabled)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
                Text(s.clipboardHistoryEnableCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let problem = service.storeProblem {
                    ClipboardHistoryProblemView(problem: problem, fileURL: service.storeProblemItemURL)
                }
            }

            Section {
                ShortcutRecorderRow(role: .clipboardHistory, title: s.clipboardHistoryShortcut,
                                    enabledKey: DefaultsKey.clipboardHistoryShortcutEnabled)
                    .disabled(!enabled)
                Text(s.clipboardHistoryShortcutCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if permissions.accessibility {
                    Label(s.clipboardHistoryAccessibilityGranted, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label(s.clipboardHistoryAccessibilityMissing, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(s.permissionRequest) { permissions.request(.accessibility) }
                }
            }

            Section {
                Picker(s.clipboardHistoryRetentionTitle, selection: $retentionDays) {
                    ForEach(ClipboardHistoryRetention.allCases) { Text($0.label(s)).tag($0.rawValue) }
                }
                .onChange(of: retentionDays) { _, _ in service.applyRetention() }
                Text(s.clipboardHistoryRetentionCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(s.clipboardHistoryRecordsMedia, isOn: $recordsMedia)
                Text(s.clipboardHistoryRecordsMediaCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(s.clipboardHistoryImageBudgetTitle, selection: $imageBudgetMB) {
                    ForEach(ClipboardHistoryImageBudget.allCases) { Text($0.label(s)).tag($0.rawValue) }
                }
                .onChange(of: imageBudgetMB) { _, _ in service.applyRetention() }
                Text(String(format: s.clipboardHistoryImageBudgetCaptionFormat, unpinnedImageTotal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(s.clipboardHistoryExcludedTitle) {
                if ignored.apps.isEmpty {
                    Text(s.clipboardHistoryExcludedNone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(ignored.apps, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        let app = ClipboardHistorySourceApp.info(for: bundleID)
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                        Button {
                            ignored.remove(bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(s.clipboardHistoryExcludedRemove)
                    }
                }
                Button {
                    pickApplication()
                } label: {
                    Label(s.clipboardHistoryExcludedAdd, systemImage: "plus")
                }
                Text(s.clipboardHistoryExcludedCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(s.clipboardHistoryClearUnpinned, role: .destructive) {
                    confirmation = service.unpinnedSnapshot
                }
                .disabled(service.storeProblem != nil || service.unpinnedSnapshot.isEmpty)
                .confirmationDialog(String(format: s.clipboardHistoryClearConfirmFormat, confirmation?.count ?? 0),
                                    isPresented: Binding(get: { confirmation != nil },
                                                         set: { if !$0 { confirmation = nil } }),
                                    titleVisibility: .visible) {
                    Button(s.clipboardHistoryClearConfirm, role: .destructive) {
                        if let confirmation { service.clearUnpinned(confirmed: confirmation) }
                        confirmation = nil
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    private func pickApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = s.clipboardHistoryExcludedAdd
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        ignored.add(bundleID)
    }

    private var unpinnedImageTotal: String {
        let bytes = service.entries.reduce(0) { total, entry in
            guard !entry.isPinned, case .image(let ref) = entry.content else { return total }
            return total + ref.byteCount
        }
        return Int64(bytes).formatted(.byteCount(style: .file).locale(Locale(identifier: l10n.language.rawValue)))
    }
}

extension ClipboardHistoryImageBudget {
    func label(_ s: Strings) -> String {
        guard let bytes else { return s.clipboardHistoryImageBudgetUnlimited }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
