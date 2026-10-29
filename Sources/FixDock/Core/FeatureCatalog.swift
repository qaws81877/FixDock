// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Features the hub can install. Declaration order is the order later steps
/// add the real modules:
/// URL cleaner, quit/close protection, cleaning mode, text snippets,
/// AirDrop auto-zip, cleaner, screenshot, screen recorder.
///
/// Raw values match upstream vorssaint-utils where the feature existed, so a
/// saved availability key still means the same thing when the module returns.
/// `airdropAutoZip` is new and has no upstream module.
///
/// `urlCleaner` and `quitWindowProtection` have modules. The others still only
/// remember a choice: installing them does not load a service.
enum AppFeature: String, CaseIterable, Identifiable {
    case urlCleaner
    case quitWindowProtection
    case cleaningMode
    case textSnippets
    case airdropAutoZip
    case cleaner
    case screenshot
    case screenRecorder

    var id: String { rawValue }

    /// True once this build contains the service and its binding.
    var hasService: Bool { self == .urlCleaner || self == .quitWindowProtection }

    /// Grants the module cannot run without. Installing asks for any missing.
    var requiredPermissions: [PermissionKind] {
        switch self {
        case .quitWindowProtection: return [.accessibility]
        case .urlCleaner, .cleaningMode, .textSnippets, .airdropAutoZip,
             .cleaner, .screenshot, .screenRecorder:
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
        case .cleaningMode, .textSnippets, .airdropAutoZip, .cleaner,
             .screenshot, .screenRecorder:
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
        case .quitWindowProtection, .textSnippets:
            return .keyboard
        case .cleaningMode, .airdropAutoZip, .cleaner, .screenshot, .screenRecorder:
            return .tools
        }
    }

    var symbolName: String {
        switch self {
        case .urlCleaner: return "link"
        case .quitWindowProtection: return "shield.lefthalf.filled"
        case .cleaningMode: return "bubbles.and.sparkles"
        case .textSnippets: return "text.append"
        case .airdropAutoZip: return "airdrop"
        case .cleaner: return "sparkles"
        case .screenshot: return "camera.viewfinder"
        case .screenRecorder: return "record.circle"
        }
    }

    func title(_ strings: Strings) -> String {
        switch self {
        case .urlCleaner: return strings.featureURLCleanerName
        case .quitWindowProtection: return strings.featureQuitProtectionName
        case .cleaningMode: return strings.featureCleaningModeName
        case .textSnippets: return strings.featureSnippetsName
        case .airdropAutoZip: return strings.featureAirDropName
        case .cleaner: return strings.featureCleanerName
        case .screenshot: return strings.featureScreenshotName
        case .screenRecorder: return strings.featureRecorderName
        }
    }

    func summary(_ strings: Strings) -> String {
        switch self {
        case .urlCleaner: return strings.featureURLCleanerSummary
        case .quitWindowProtection: return strings.featureQuitProtectionSummary
        case .cleaningMode: return strings.featureCleaningModeSummary
        case .textSnippets: return strings.featureSnippetsSummary
        case .airdropAutoZip: return strings.featureAirDropSummary
        case .cleaner: return strings.featureCleanerSummary
        case .screenshot: return strings.featureScreenshotSummary
        case .screenRecorder: return strings.featureRecorderSummary
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
