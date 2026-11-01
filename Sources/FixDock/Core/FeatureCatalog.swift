// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Features the hub can install. Declaration order is the order later steps
/// add the real modules:
/// URL cleaner, quit/close protection, cleaning mode, text snippets, media,
/// AirDrop auto-zip, cleaner, screenshot, screen recorder, fast Korean/English switch.
///
/// Raw values match upstream vorssaint-utils where the feature existed, so a
/// saved availability key still means the same thing when the module returns.
/// `airdropAutoZip` and `inputSwitch` are new and have no upstream module.
/// `inputSwitch` follows gksdud (MIT, credited in NOTICE).
///
/// `urlCleaner`, `quitWindowProtection`, `cleaningMode`, `textSnippets`,
/// `mediaTools`, `airdropAutoZip`, `cleaner`, `screenshot` and
/// `screenRecorder` and `inputSwitch` have modules.
enum AppFeature: String, CaseIterable, Identifiable {
    case urlCleaner
    case quitWindowProtection
    case cleaningMode
    case textSnippets
    case mediaTools
    case airdropAutoZip
    case cleaner
    case screenshot
    case screenRecorder
    case inputSwitch

    var id: String { rawValue }

    /// True once this build contains the service and its binding.
    var hasService: Bool {
        self == .urlCleaner || self == .quitWindowProtection || self == .cleaningMode
            || self == .textSnippets || self == .mediaTools || self == .airdropAutoZip
            || self == .cleaner || self == .screenshot || self == .screenRecorder
            || self == .inputSwitch
    }

    /// Grants the module cannot run without. Installing asks for any missing.
    var requiredPermissions: [PermissionKind] {
        switch self {
        case .quitWindowProtection, .cleaningMode, .textSnippets, .inputSwitch: return [.accessibility]
        case .cleaner: return [.fullDiskAccess]
        case .screenshot, .screenRecorder: return [.screenRecording]
        case .urlCleaner, .mediaTools, .airdropAutoZip:
            return []
        }
    }

    /// The first time a tool is installed, turn on its main switch if the
    /// person has never chosen. A later install keeps the saved choice.
    /// Quit protection starts with ⌘Q only; ⌘W stays a choice.
    func enableOnFirstInstall() {
        let key: String
        switch self {
        case .urlCleaner: key = DefaultsKey.urlCleanerEnabled
        case .quitWindowProtection: key = DefaultsKey.quitProtectionQuitEnabled
        case .textSnippets: key = DefaultsKey.textSnippetsEnabled
        case .airdropAutoZip: key = DefaultsKey.airdropAutoZipEnabled
        case .cleaningMode, .mediaTools, .cleaner,
             .screenshot, .screenRecorder:
            return
        case .inputSwitch:
            // Installing never rewires a key before the person turns it on.
            return
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
        }
    }

    var availabilityKey: String { DefaultsKey.featureAvailable(rawValue) }

    var isAvailable: Bool {
        UserDefaults.standard.bool(forKey: availabilityKey)
    }

    var group: FeatureGroup {
        switch self {
        case .urlCleaner:
            return .files
        case .quitWindowProtection, .textSnippets, .inputSwitch:
            return .keyboard
        case .cleaningMode, .mediaTools, .airdropAutoZip, .cleaner, .screenshot, .screenRecorder:
            return .tools
        }
    }

    var symbolName: String {
        switch self {
        case .urlCleaner: return "link"
        case .quitWindowProtection: return "shield.lefthalf.filled"
        case .cleaningMode: return "bubbles.and.sparkles"
        case .textSnippets: return "text.append"
        case .mediaTools: return "photo.on.rectangle.angled"
        case .airdropAutoZip: return "dot.radiowaves.up.forward"
        case .cleaner: return "sparkles"
        case .screenshot: return "camera.viewfinder"
        case .screenRecorder: return "record.circle"
        case .inputSwitch: return "globe"
        }
    }

    func title(_ strings: Strings) -> String {
        switch self {
        case .urlCleaner: return strings.featureURLCleanerName
        case .quitWindowProtection: return strings.featureQuitProtectionName
        case .cleaningMode: return strings.featureCleaningModeName
        case .textSnippets: return strings.featureSnippetsName
        case .mediaTools: return strings.featureMediaName
        case .airdropAutoZip: return strings.featureAirDropName
        case .cleaner: return strings.featureCleanerName
        case .screenshot: return strings.featureScreenshotName
        case .screenRecorder: return strings.featureRecorderName
        case .inputSwitch: return strings.featureInputSwitchName
        }
    }

    func summary(_ strings: Strings) -> String {
        switch self {
        case .urlCleaner: return strings.featureURLCleanerSummary
        case .quitWindowProtection: return strings.featureQuitProtectionSummary
        case .cleaningMode: return strings.featureCleaningModeSummary
        case .textSnippets: return strings.featureSnippetsSummary
        case .mediaTools: return strings.featureMediaSummary
        case .airdropAutoZip: return strings.featureAirDropSummary
        case .cleaner: return strings.featureCleanerSummary
        case .screenshot: return strings.featureScreenshotSummary
        case .screenRecorder: return strings.featureRecorderSummary
        case .inputSwitch: return strings.featureInputSwitchSummary
        }
    }
}

/// Hub sections and Settings sidebar categories, in display order.
enum FeatureGroup: String, CaseIterable, Identifiable {
    case files, keyboard, tools

    var id: String { rawValue }

    /// Members in catalog declaration order. Shared by the hub and sidebar.
    var features: [AppFeature] {
        AppFeature.allCases.filter { $0.group == self }
    }

    func title(_ strings: Strings) -> String {
        switch self {
        case .files: return strings.groupFiles
        case .keyboard: return strings.groupKeyboard
        case .tools: return strings.groupTools
        }
    }
}
