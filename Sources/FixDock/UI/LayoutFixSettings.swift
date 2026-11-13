// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings page for the Korean/English layout fix: the switch, why the tool
/// is resting when it is, and the apps it is turned off for.
struct LayoutFixSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = LayoutFixService.shared
    @AppStorage(DefaultsKey.layoutFixEnabled) private var enabled = false
    private var s: Strings { l10n.s }

    var body: some View {
        Form {
            Section {
                Toggle(s.layoutFixEnable, isOn: $enabled)
                    .onChange(of: enabled) { _, _ in
                        LayoutFixService.shared.syncWithPreferences()
                    }
                Text(s.layoutFixEnableCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(s.layoutFixLimitsCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if service.mode == .resting(.needsAccessibility) {
                    Label(s.layoutFixNeedsAccessibility, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(s.permissionRequest) { permissions.request(.accessibility) }
                } else if let status = LayoutFixStatus.text(service.mode, s) {
                    Label(status, systemImage: service.mode == .active ? "checkmark.circle.fill" : "pause.circle")
                        .font(.caption)
                        .foregroundStyle(service.mode == .active ? Color.green : Color.orange)
                }
                KeyTapStatusView(client: .layoutFix)
            }

            Section(s.layoutFixExcludedTitle) {
                if service.ignoredApps.isEmpty {
                    Text(s.layoutFixExcludedNone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(service.ignoredApps, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        let app = ClipboardHistorySourceApp.info(for: bundleID)
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                        Button {
                            service.stopIgnoring(bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(s.layoutFixExcludedRemove)
                    }
                }
                Button {
                    pickApplication()
                } label: {
                    Label(s.layoutFixExcludedAdd, systemImage: "plus")
                }
                Text(s.layoutFixExcludedCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            LayoutFixService.shared.syncWithPreferences()
        }
    }

    private func pickApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = s.layoutFixExcludedAdd
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        service.ignore(bundleID)
    }
}

/// The one line that says what the tool is doing. nil while it is off.
enum LayoutFixStatus {
    static func text(_ mode: LayoutFixMode, _ s: Strings) -> String? {
        switch mode {
        case .off: return nil
        case .active: return s.layoutFixActiveNow
        case .resting(.needsAccessibility): return s.layoutFixNeedsAccessibility
        case .resting(.otherFixer(let name)): return String(format: s.layoutFixRestOtherFixerFormat, name)
        case .resting(.developerBuild): return s.layoutFixRestDeveloperBuild
        case .resting(.unknownLayout): return s.layoutFixRestUnknownLayout
        case .resting(.listsMissing): return s.layoutFixRestListsMissing
        case .resting(.listsLoading): return s.layoutFixRestListsLoading
        }
    }
}

struct LayoutFixPanelRow: View {
    let isEditing: Bool
    let visibility: Binding<Bool>
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = LayoutFixService.shared
    @AppStorage(DefaultsKey.layoutFixEnabled) private var enabled = false

    var body: some View {
        let s = l10n.s
        let waiting = service.mode == .resting(.needsAccessibility)
        let resting: String? = {
            if case .resting = service.mode { return LayoutFixStatus.text(service.mode, s) }
            return nil
        }()
        PanelToggleRow(title: AppFeature.layoutFix.title(s),
                       caption: resting ?? AppFeature.layoutFix.summary(s),
                       systemImage: AppFeature.layoutFix.symbolName,
                       isOn: $enabled,
                       isEditing: isEditing,
                       showsDragHandle: true,
                       visibility: visibility,
                       isActive: service.mode == .active,
                       activeText: s.layoutFixActiveNow,
                       needsAttention: resting != nil,
                       permissionButtonTitle: s.permissionRequest,
                       permissionAction: waiting ? { Permissions.shared.request(.accessibility) } : nil)
            .onChange(of: enabled) { _, _ in
                LayoutFixService.shared.syncWithPreferences()
            }
    }
}
