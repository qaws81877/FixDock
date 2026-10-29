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
/// Step 1 ships no feature module. `hasService` stays false: installing only
/// remembers the choice. Nothing loads, and nothing asks for a permission.
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

    /// True once a later step has added the service and its binding.
    var hasService: Bool { false }

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

/// Hub sections, in display order.
enum FeatureGroup: String, CaseIterable, Identifiable {
    case files, keyboard, tools

    var id: String { rawValue }

    func title(_ strings: Strings) -> String {
        switch self {
        case .files: return strings.groupFiles
        case .keyboard: return strings.groupKeyboard
        case .tools: return strings.groupTools
        }
    }
}
