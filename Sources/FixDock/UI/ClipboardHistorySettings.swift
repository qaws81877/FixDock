// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Restored from upstream's clipboard settings and its apps-to-skip list,
/// cut to what the text-only history has.
struct ClipboardHistorySettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = ClipboardHistoryService.shared
    @ObservedObject private var ignored = ClipboardIgnoredApps.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.clipboardHistoryEnabled) private var enabled = false
    @AppStorage(DefaultsKey.clipboardHistoryRetentionDays) private var retentionDays =
        ClipboardHistoryRetention.default.rawValue
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
                    ClipboardHistoryProblemView(problem: problem, fileURL: service.storeFileURL)
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

            Section(s.clipboardHistoryExcludedTitle) {
                if ignored.apps.isEmpty {
                    Text(s.clipboardHistoryExcludedNone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(ignored.apps, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        Image(nsImage: Self.icon(for: bundleID))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(Self.name(for: bundleID))
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

    /// An app removed since it was picked still shows, by its bundle id.
    private static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
