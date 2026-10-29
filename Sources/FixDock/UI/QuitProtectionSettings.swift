// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Adapted from upstream. Applications are picked with an open panel instead
/// of upstream's installed-app browser.
struct QuitProtectionSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = QuitProtectionService.shared
    private var s: Strings { l10n.s }

    @AppStorage(DefaultsKey.quitProtectionQuitEnabled) private var quitEnabled = false
    @AppStorage(DefaultsKey.quitProtectionQuitMode) private var quitMode = QuitProtectionMode.hold.rawValue
    @AppStorage(DefaultsKey.quitProtectionQuitHoldDurationMs) private var quitHoldDuration = QuitProtectionSupport.defaultHoldDurationMilliseconds
    @AppStorage(DefaultsKey.quitProtectionQuitDoubleIntervalMs) private var quitDoubleInterval = QuitProtectionSupport.defaultDoublePressIntervalMilliseconds
    @AppStorage(DefaultsKey.quitProtectionQuitExtraModifier) private var quitExtraModifier = QuitProtectionExtraModifier.shift.rawValue
    @AppStorage(DefaultsKey.quitProtectionQuitScope) private var quitScope = QuitProtectionScope.all.rawValue
    @AppStorage(DefaultsKey.quitProtectionQuitShowFeedback) private var quitShowFeedback = true

    @AppStorage(DefaultsKey.quitProtectionCloseEnabled) private var closeEnabled = false
    @AppStorage(DefaultsKey.quitProtectionCloseMode) private var closeMode = QuitProtectionMode.hold.rawValue
    @AppStorage(DefaultsKey.quitProtectionCloseHoldDurationMs) private var closeHoldDuration = QuitProtectionSupport.defaultHoldDurationMilliseconds
    @AppStorage(DefaultsKey.quitProtectionCloseDoubleIntervalMs) private var closeDoubleInterval = QuitProtectionSupport.defaultDoublePressIntervalMilliseconds
    @AppStorage(DefaultsKey.quitProtectionCloseExtraModifier) private var closeExtraModifier = QuitProtectionExtraModifier.shift.rawValue
    @AppStorage(DefaultsKey.quitProtectionCloseScope) private var closeScope = QuitProtectionScope.all.rawValue
    @AppStorage(DefaultsKey.quitProtectionCloseShowFeedback) private var closeShowFeedback = true

    var body: some View {
        Form {
            Section {
                Text(s.quitProtectionIntro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(s.quitProtectionAccessibilityCaption, systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if service.isWaitingForAccessibility {
                    Label(s.quitProtectionNeedsAccessibility, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(s.permissionRequest) { permissions.request(.accessibility) }
                } else if service.isRunning {
                    Label(s.quitProtectionActiveNow, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            shortcutSection(shortcut: .quit,
                            enabled: $quitEnabled,
                            mode: $quitMode,
                            holdDuration: $quitHoldDuration,
                            doubleInterval: $quitDoubleInterval,
                            extraModifier: $quitExtraModifier,
                            scope: $quitScope,
                            showFeedback: $quitShowFeedback)
            shortcutSection(shortcut: .close,
                            enabled: $closeEnabled,
                            mode: $closeMode,
                            holdDuration: $closeHoldDuration,
                            doubleInterval: $closeDoubleInterval,
                            extraModifier: $closeExtraModifier,
                            scope: $closeScope,
                            showFeedback: $closeShowFeedback)
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            service.syncWithPreferences()
        }
    }

    @ViewBuilder
    private func shortcutSection(shortcut: QuitProtectionShortcut,
                                 enabled: Binding<Bool>,
                                 mode: Binding<String>,
                                 holdDuration: Binding<Double>,
                                 doubleInterval: Binding<Double>,
                                 extraModifier: Binding<String>,
                                 scope: Binding<String>,
                                 showFeedback: Binding<Bool>) -> some View {
        let currentMode = QuitProtectionSupport.modeFor(mode.wrappedValue)
        let currentScope = QuitProtectionSupport.scopeFor(scope.wrappedValue)
        let currentModifier = QuitProtectionSupport.extraModifierFor(extraModifier.wrappedValue)

        Section(shortcut.symbol) {
            Toggle(s.quitProtectionEnabled, isOn: enabled)
                .onChange(of: enabled.wrappedValue) { _, _ in service.syncWithPreferences() }
            Text(s.quitProtectionEnabledCaption)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(s.quitProtectionMode, selection: mode) {
                Text(s.quitProtectionHold).tag(QuitProtectionMode.hold.rawValue)
                Text(s.quitProtectionDoublePress).tag(QuitProtectionMode.doublePress.rawValue)
                Text(s.quitProtectionExtraModifier).tag(QuitProtectionMode.extraModifier.rawValue)
            }

            if currentMode == .hold {
                Slider(value: holdDuration,
                       in: QuitProtectionSupport.holdDurationRange,
                       step: 50) {
                    Text(s.quitProtectionHoldDuration)
                } minimumValueLabel: {
                    Text("250 ms").font(.caption2)
                } maximumValueLabel: {
                    Text("2 s").font(.caption2)
                }
                Text("\(Int(holdDuration.wrappedValue.rounded())) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if currentMode == .doublePress {
                Slider(value: doubleInterval,
                       in: QuitProtectionSupport.doublePressIntervalRange,
                       step: 50) {
                    Text(s.quitProtectionDoublePressInterval)
                } minimumValueLabel: {
                    Text("200 ms").font(.caption2)
                } maximumValueLabel: {
                    Text("1.5 s").font(.caption2)
                }
                Text("\(Int(doubleInterval.wrappedValue.rounded())) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if currentMode == .extraModifier {
                Picker(s.quitProtectionModifier, selection: extraModifier) {
                    Text("\(s.quitProtectionShiftKey) (⇧)").tag(QuitProtectionExtraModifier.shift.rawValue)
                    Text("\(s.quitProtectionOptionKey) (⌥)").tag(QuitProtectionExtraModifier.option.rawValue)
                    Text("\(s.quitProtectionControlKey) (⌃)").tag(QuitProtectionExtraModifier.control.rawValue)
                }
                Text("\(modifierSymbol(currentModifier))\(shortcut.symbol)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker(s.quitProtectionAppScope, selection: scope) {
                Text(s.quitProtectionAllApps).tag(QuitProtectionScope.all.rawValue)
                Text(s.quitProtectionSelectedOnly).tag(QuitProtectionScope.selectedOnly.rawValue)
                Text(s.quitProtectionAllExceptSelected).tag(QuitProtectionScope.allExceptSelected.rawValue)
            }

            exceptionsSection(for: shortcut, scope: currentScope, enabled: enabled.wrappedValue)

            Toggle(s.quitProtectionFeedback, isOn: showFeedback)
        }
    }

    @ViewBuilder
    private func exceptionsSection(for shortcut: QuitProtectionShortcut,
                                   scope: QuitProtectionScope,
                                   enabled: Bool) -> some View {
        if scope != .all {
            VStack(alignment: .leading, spacing: 7) {
                Text(s.quitProtectionExceptions)
                    .font(.subheadline.weight(.semibold))
                let values = service.exceptions(for: shortcut)
                if values.isEmpty {
                    Text(s.quitProtectionNoExceptions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(values, id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            Image(nsImage: Self.icon(for: bundleID))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(Self.name(for: bundleID))
                            Spacer()
                            Button {
                                service.removeException(bundleID, for: shortcut)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(s.quitProtectionRemoveApp)
                        }
                    }
                }
                Button {
                    pickApplication(for: shortcut)
                } label: {
                    Label(s.quitProtectionAddApp, systemImage: "plus")
                }
            }
            .disabled(!enabled)
        }
    }

    private func pickApplication(for shortcut: QuitProtectionShortcut) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = s.quitProtectionAddApp
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        service.addException(bundleID, for: shortcut)
    }

    private static func appURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// An app removed since it was picked still shows, by its bundle id.
    private static func name(for bundleID: String) -> String {
        guard let url = appURL(for: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private static func icon(for bundleID: String) -> NSImage {
        guard let url = appURL(for: bundleID) else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func modifierSymbol(_ modifier: QuitProtectionExtraModifier) -> String {
        switch modifier {
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }
}
