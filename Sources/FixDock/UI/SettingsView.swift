// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var navigator = SettingsNavigator.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let strings = l10n.s
        HStack(spacing: 0) {
            List(selection: navigator.selection) {
                ForEach(navigator.sections) { section in
                    sidebarSection(section, strings)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            Divider()
            ScrollView {
                page(for: navigator.destination)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private func sidebarSection(_ section: SidebarSection, _ strings: Strings) -> some View {
        switch section.id {
        case .app:
            Section {
                destinationRows(section.destinations, strings)
            }
        case .category(let group):
            Section(group.title(strings), isExpanded: navigator.expansion(of: group)) {
                destinationRows(section.destinations, strings)
            }
        }
    }

    @ViewBuilder
    private func destinationRows(_ destinations: [SettingsDestination], _ strings: Strings) -> some View {
        ForEach(destinations, id: \.self) { destination in
            Text(destination.title(strings)).tag(Optional(destination))
        }
    }

    @ViewBuilder
    private func page(for destination: SettingsDestination) -> some View {
        switch destination {
        case .shell(.general): GeneralSettingsPage()
        case .shell(.features): FeatureHubList(showsInstallButtons: true)
        case .shell(.shortcut): ShortcutRecorder().settingsCard()
        case .shell(.permissions): PermissionsSettingsPage()
        case .shell(.about): AboutSettingsPage()
        case .feature(let page): page.body()
        }
    }
}

private struct GeneralSettingsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var launchAtLogin = UserDefaults.standard.bool(forKey: DefaultsKey.launchAtLoginWanted)
    @State private var loginMessage: String?

    var body: some View {
        let strings = l10n.s
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.languageTitle).font(.headline)
                Text(strings.languageCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker(strings.languageTitle, selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            .settingsCard()

            VStack(alignment: .leading, spacing: 6) {
                Toggle(strings.launchAtLogin, isOn: Binding(
                    get: { launchAtLogin },
                    set: { applyLogin($0) }
                ))
                Text(strings.launchAtLoginCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let loginMessage {
                    Text(loginMessage)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsCard()

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

private struct PermissionsSettingsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        let strings = l10n.s
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
                    Text(strings.permissionNotNeededYet)
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
        VStack(alignment: .leading, spacing: 10) {
            Text(AppInfo.name).font(.title2.weight(.semibold))
            Text(String(format: strings.versionFormat, AppInfo.version))
                .foregroundStyle(.secondary)
            Text(strings.aboutFork)
                .fixedSize(horizontal: false, vertical: true)
            Text(strings.aboutLicense)
                .fixedSize(horizontal: false, vertical: true)
            Text(strings.aboutNoTelemetry)
            Text(strings.aboutNoUpdates)
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
