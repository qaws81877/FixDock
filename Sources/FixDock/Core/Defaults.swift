// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Preference keys for the shell. Feature availability keeps the upstream
/// `featureAvailable.<id>` form so a later module can read the same choice.
enum DefaultsKey {
    static let language = "appLanguage"
    static let onboardingComplete = "onboardingComplete"
    static let launchAtLoginWanted = "launchAtLoginWanted"
    static let panelShortcut = "panelShortcut"
    static let urlCleanerEnabled = "urlCleanerEnabled"
    static let urlCleanerCustomParameters = "urlCleanerCustomParameters"
    static let urlCleanerSiteParameters = "urlCleanerSiteParameters"
    static let urlCleanerDisabledParameters = "urlCleanerDisabledParameters"
    static let quitProtectionQuitEnabled = "quitProtectionQuitEnabled"
    static let quitProtectionQuitMode = "quitProtectionQuitMode"
    static let quitProtectionQuitHoldDurationMs = "quitProtectionQuitHoldDurationMs"
    static let quitProtectionQuitDoubleIntervalMs = "quitProtectionQuitDoubleIntervalMs"
    static let quitProtectionQuitExtraModifier = "quitProtectionQuitExtraModifier"
    static let quitProtectionQuitScope = "quitProtectionQuitScope"
    static let quitProtectionQuitExceptions = "quitProtectionQuitExceptions"
    static let quitProtectionQuitShowFeedback = "quitProtectionQuitShowFeedback"
    static let quitProtectionCloseEnabled = "quitProtectionCloseEnabled"
    static let quitProtectionCloseMode = "quitProtectionCloseMode"
    static let quitProtectionCloseHoldDurationMs = "quitProtectionCloseHoldDurationMs"
    static let quitProtectionCloseDoubleIntervalMs = "quitProtectionCloseDoubleIntervalMs"
    static let quitProtectionCloseExtraModifier = "quitProtectionCloseExtraModifier"
    static let quitProtectionCloseScope = "quitProtectionCloseScope"
    static let quitProtectionCloseExceptions = "quitProtectionCloseExceptions"
    static let quitProtectionCloseShowFeedback = "quitProtectionCloseShowFeedback"
    static let cleaningModeKeepScreenVisible = "cleaningModeKeepScreenVisible"
    static let cleaningModeClickPolicy = "cleaningModeClickPolicy"
    static let textSnippetsEnabled = "textSnippetsEnabled"
    static let textSnippets = "textSnippets"
    static let mediaImagePreset = "mediaImagePreset"
    static let mediaOutputMode = "mediaOutputMode"
    static let mediaTool = "mediaTool"
    static let mediaVideoSizing = "mediaVideoSizing"
    static let mediaVideoPreset = "mediaVideoPreset"
    static let mediaVideoTargetMegabytes = "mediaVideoTargetMegabytes"
    static let airdropAutoZipEnabled = "airdropAutoZipEnabled"
    static let airdropAutoZipPreset = "airdropAutoZipPreset"
    /// Developer runs only: watch this folder instead of Downloads.
    static let airdropAutoZipFolderOverride = "airdropAutoZipFolderOverride"
    static let mediaImageFormat = "mediaImageFormat"
    static let mediaImageMaxDimension = "mediaImageMaxDimension"
    static let mediaImageMetadata = "mediaImageMetadata"

    static func featureAvailable(_ id: String) -> String { "featureAvailable.\(id)" }
}

enum Defaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            DefaultsKey.onboardingComplete: false,
            DefaultsKey.launchAtLoginWanted: false,
            // The service reads these with bool(forKey:) and double(forKey:),
            // which see registered values but not @AppStorage defaults. The
            // two Enabled keys stay unregistered so enableOnFirstInstall can
            // tell a first install from a saved Off.
            DefaultsKey.quitProtectionQuitShowFeedback: true,
            DefaultsKey.quitProtectionCloseShowFeedback: true,
            DefaultsKey.quitProtectionQuitHoldDurationMs: QuitProtectionSupport.defaultHoldDurationMilliseconds,
            DefaultsKey.quitProtectionCloseHoldDurationMs: QuitProtectionSupport.defaultHoldDurationMilliseconds,
            DefaultsKey.quitProtectionQuitDoubleIntervalMs: QuitProtectionSupport.defaultDoublePressIntervalMilliseconds,
            DefaultsKey.quitProtectionCloseDoubleIntervalMs: QuitProtectionSupport.defaultDoublePressIntervalMilliseconds,
        ])
    }
}
