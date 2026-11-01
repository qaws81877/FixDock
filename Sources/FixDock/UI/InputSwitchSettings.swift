// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// Settings page for the fast Korean/English switch. Edits two preferences,
/// re-syncs, and shows the service's report.
struct InputSwitchSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = InputSwitchService.shared
    private var s: Strings { l10n.s }

    @AppStorage(DefaultsKey.inputSwitchEnabled) private var enabled = false
    @AppStorage(DefaultsKey.inputSwitchKey) private var key = SwitchKey.default.rawValue

    var body: some View {
        Form {
            Section {
                Text(s.inputSwitchIntro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if service.isWaitingForAccessibility {
                    Label(s.inputSwitchNeedsAccessibility, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(s.permissionRequest) { permissions.request(.accessibility) }
                } else if let status = InputSwitchStatus(service.report, enabled: enabled, strings: s) {
                    Label(status.text, systemImage: status.symbol)
                        .font(.caption)
                        .foregroundStyle(status.color)
                }
                if let problem = InputSwitchStatus.problemText(service.report, strings: s) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if service.report.restoredToMacDefault {
                    Text(s.inputSwitchRestoredToDefault)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(s.inputSwitchEnabledLabel, isOn: $enabled)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
                Picker(s.inputSwitchKeyLabel, selection: $key) {
                    ForEach(SwitchKey.allCases) { Text(InputSwitchStatus.keyTitle($0, s)).tag($0.rawValue) }
                }
                .onChange(of: key) { _, _ in service.syncWithPreferences() }
                if SwitchKey(rawValue: key) == .capsLock {
                    Text(s.inputSwitchCapsLockWarning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(s.inputSwitchShortcutCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            service.syncWithPreferences()
        }
    }
}

/// The panel's on/off row.
struct InputSwitchPanelRow: View {
    let isEditing: Bool
    let visibility: Binding<Bool>
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = InputSwitchService.shared
    @AppStorage(DefaultsKey.inputSwitchEnabled) private var enabled = false

    var body: some View {
        let s = l10n.s
        let waiting = service.isWaitingForAccessibility
        let problem = InputSwitchStatus.problemText(service.report, strings: s)
        PanelToggleRow(title: AppFeature.inputSwitch.title(s),
                       caption: waiting ? s.inputSwitchNeedsAccessibility
                           : problem ?? AppFeature.inputSwitch.summary(s),
                       systemImage: AppFeature.inputSwitch.symbolName,
                       isOn: $enabled,
                       isEditing: isEditing,
                       showsDragHandle: true,
                       visibility: visibility,
                       isActive: service.report.liveKeyCode != nil,
                       activeText: s.inputSwitchActiveNow,
                       needsAttention: waiting || problem != nil,
                       permissionButtonTitle: s.permissionRequest,
                       permissionAction: waiting ? { Permissions.shared.request(.accessibility) } : nil)
            .onChange(of: enabled) { _, _ in
                InputSwitchService.shared.syncWithPreferences()
            }
    }
}

/// Report -> words. One place, shared by the page and the panel row.
struct InputSwitchStatus {
    let text: String
    let symbol: String
    let color: Color

    init?(_ report: InputSwitchReport, enabled: Bool, strings s: Strings) {
        switch report.state {
        case .off:
            return nil
        case .live(let functionKey):
            let key = UserDefaults.standard.string(forKey: DefaultsKey.inputSwitchKey)
                .flatMap(SwitchKey.init(rawValue:)) ?? .default
            text = String(format: s.inputSwitchStatusLiveFormat, Self.keyTitle(key, s), "F\(functionKey.rawValue)")
            symbol = "checkmark.circle.fill"
            color = .green
        case .preparing:
            text = s.inputSwitchStatusPreparing
            symbol = "hourglass"
            color = .secondary
        case .away:
            text = s.inputSwitchStatusAway
            symbol = "pause.circle"
            color = .secondary
        case .restoring:
            text = s.inputSwitchStatusRestoring
            symbol = "arrow.uturn.backward.circle"
            color = .secondary
        case .inert(.developerBuild):
            text = s.inputSwitchStatusDeveloperInert
            symbol = "hammer"
            color = .secondary
        case .inert(.ownedBy(let holder)):
            text = String(format: s.inputSwitchStatusOwnedByFormat, holder)
            symbol = "person.2"
            color = .secondary
        case .inert(.journalUnreadable):
            text = s.inputSwitchStatusJournalUnreadable
            symbol = "exclamationmark.octagon"
            color = .orange
        }
    }

    static func problemText(_ report: InputSwitchReport, strings s: Strings) -> String? {
        switch report.problem {
        case nil: return nil
        case .noFreeFunctionKey: return s.inputSwitchProblemNoFreeFunctionKey
        case .hotkeyWriteFailed: return s.inputSwitchProblemHotkeyFailed
        case .activationFailed: return s.inputSwitchProblemActivationFailed
        case .hotkeyChangedInSystemSettings: return s.inputSwitchProblemHotkeyChanged
        case .keyboardsPending(let count): return String(format: s.inputSwitchProblemKeyboardsPendingFormat, count)
        case .otherSwitcherRunning(let name): return String(format: s.inputSwitchProblemOtherSwitcherFormat, name)
        }
    }

    static func keyTitle(_ key: SwitchKey, _ s: Strings) -> String {
        switch key {
        case .capsLock: return s.inputSwitchKeyCapsLock
        case .rightCommand: return s.inputSwitchKeyRightCommand
        case .rightOption: return s.inputSwitchKeyRightOption
        case .rightControl: return s.inputSwitchKeyRightControl
        }
    }
}
