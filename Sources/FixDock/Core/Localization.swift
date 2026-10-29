// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Combine
import Foundation

extension Notification.Name {
    static let fixDockLanguageChanged = Notification.Name("fixDockLanguageChanged")
}

/// Languages the shell ships. English is the fallback. Korean follows the
/// system language on first launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case enUS = "en-US"
    case ko = "ko"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .enUS: return "English"
        case .ko: return "한국어"
        }
    }

    static var systemDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.lowercased().hasPrefix("ko") { return .ko }
        return .enUS
    }
}

final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: DefaultsKey.language)
            NotificationCenter.default.post(name: .fixDockLanguageChanged, object: nil)
        }
    }

    var s: Strings { Strings.localized(language) }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.language),
           let saved = AppLanguage(rawValue: raw) {
            language = saved
        } else {
            language = .systemDefault
        }
    }
}

struct Strings {
    let statusTooltip: String
    let menuSettings: String
    let menuQuit: String
    let menuEdit: String
    let menuUndo: String
    let menuRedo: String
    let menuCut: String
    let menuCopy: String
    let menuPaste: String
    let menuSelectAll: String
    let panelEmptyTitle: String
    let panelEmptyBody: String
    let panelInstalledHeading: String
    let panelNotInBuild: String
    let settingsTitle: String
    let tabGeneral: String
    let tabFeatures: String
    let tabShortcut: String
    let tabPermissions: String
    let tabAbout: String
    let languageTitle: String
    let languageCaption: String
    let launchAtLogin: String
    let launchAtLoginCaption: String
    let launchAtLoginNeedsApplications: String
    let launchAtLoginNeedsApproval: String
    let relaunch: String
    let featuresIntro: String
    let featuresInstall: String
    let featuresRemove: String
    let featuresInstallAll: String
    let featuresRemoveAll: String
    let featuresRestartTitle: String
    let featuresRestartButton: String
    let groupFiles: String
    let groupKeyboard: String
    let groupTools: String
    let featureURLCleanerName: String
    let featureURLCleanerSummary: String
    let featureQuitProtectionName: String
    let featureQuitProtectionSummary: String
    let featureCleaningModeName: String
    let featureCleaningModeSummary: String
    let featureSnippetsName: String
    let featureSnippetsSummary: String
    let featureAirDropName: String
    let featureAirDropSummary: String
    let featureCleanerName: String
    let featureCleanerSummary: String
    let featureScreenshotName: String
    let featureScreenshotSummary: String
    let featureRecorderName: String
    let featureRecorderSummary: String
    let shortcutTitle: String
    let shortcutCaption: String
    let shortcutRecord: String
    let shortcutRecording: String
    let shortcutEscapeHint: String
    let shortcutDeleteHint: String
    let shortcutFailed: String
    let permissionsIntro: String
    let permissionAccessibility: String
    let permissionAccessibilityDetail: String
    let permissionScreenRecording: String
    let permissionScreenRecordingDetail: String
    let permissionNotNeededYet: String
    let permissionRequest: String
    let permissionGranted: String
    let guideTitle: String
    let guideStepOpen: String
    let guideStepToggle: String
    let guideStepReturn: String
    let guideWaiting: String
    let guideGranted: String
    let guideRelaunch: String
    let guideStaleHint: String
    let guideStartOver: String
    let guideClose: String
    let onboardingWelcomeTitle: String
    let onboardingWelcomeBody: String
    let onboardingLanguageTitle: String
    let onboardingFeaturesTitle: String
    let onboardingFeaturesBody: String
    let onboardingPermissionsTitle: String
    let onboardingPermissionsBody: String
    let onboardingFinishTitle: String
    let onboardingFinishBody: String
    let onboardingContinue: String
    let onboardingBack: String
    let onboardingSkip: String
    let onboardingGetStarted: String
    let aboutFork: String
    let aboutLicense: String
    let aboutNoTelemetry: String
    let aboutNoUpdates: String
    let aboutUpstreamButton: String
    let aboutRepositoryButton: String
    let versionFormat: String

    static func localized(_ language: AppLanguage) -> Strings {
        switch language {
        case .enUS: return .enUS
        case .ko: return .ko
        }
    }

    static let enUS = Strings(
        statusTooltip: "FixDock",
        menuSettings: "Settings…",
        menuQuit: "Quit FixDock",
        menuEdit: "Edit",
        menuUndo: "Undo",
        menuRedo: "Redo",
        menuCut: "Cut",
        menuCopy: "Copy",
        menuPaste: "Paste",
        menuSelectAll: "Select All",
        panelEmptyTitle: "Nothing installed yet",
        panelEmptyBody: "Open Settings to choose tools. This build only remembers the choice. The tools themselves are not included yet.",
        panelInstalledHeading: "Chosen for later",
        panelNotInBuild: "Not in this build",
        settingsTitle: "FixDock Settings",
        tabGeneral: "General",
        tabFeatures: "Features",
        tabShortcut: "Shortcut",
        tabPermissions: "Permissions",
        tabAbout: "About",
        languageTitle: "Language",
        languageCaption: "English and Korean are the languages this fork ships.",
        launchAtLogin: "Open at login",
        launchAtLoginCaption: "Available after FixDock is installed in /Applications. A copy in the build folder cannot register a stable login item.",
        launchAtLoginNeedsApplications: "Move FixDock to /Applications, then turn this on again.",
        launchAtLoginNeedsApproval: "macOS is waiting for approval. Turn FixDock on in System Settings → General → Login Items.",
        relaunch: "Relaunch FixDock",
        featuresIntro: "Installing remembers a tool for a later build. Nothing runs in this one, and no permission is requested.",
        featuresInstall: "Install",
        featuresRemove: "Remove",
        featuresInstallAll: "Install all",
        featuresRemoveAll: "Remove all",
        featuresRestartTitle: "Relaunch to finish unloading a tool that was running.",
        featuresRestartButton: "Relaunch",
        groupFiles: "Links and files",
        groupKeyboard: "Keyboard",
        groupTools: "Tools",
        featureURLCleanerName: "URL cleaner",
        featureURLCleanerSummary: "Strip tracking parameters from links you copy.",
        featureQuitProtectionName: "Quit and close protection",
        featureQuitProtectionSummary: "Ask before a shortcut quits an app or closes a window.",
        featureCleaningModeName: "Cleaning mode",
        featureCleaningModeSummary: "Hide the desktop while you show a Mac to a customer.",
        featureSnippetsName: "Text snippets",
        featureSnippetsSummary: "Expand a short abbreviation into text you type often.",
        featureAirDropName: "AirDrop auto-zip",
        featureAirDropSummary: "Zip a folder automatically when you AirDrop it. New in FixDock.",
        featureCleanerName: "Cleaner",
        featureCleanerSummary: "Find leftover junk, caches, and forgotten screenshots.",
        featureScreenshotName: "Screenshot",
        featureScreenshotSummary: "Capture the screen and mark it up.",
        featureRecorderName: "Screen recorder",
        featureRecorderSummary: "Record the screen.",
        shortcutTitle: "Open the panel",
        shortcutCaption: "Works without Accessibility. The default is Control-Option-Command-F.",
        shortcutRecord: "Record shortcut",
        shortcutRecording: "Press the new shortcut.",
        shortcutEscapeHint: "Escape cancels.",
        shortcutDeleteHint: "Delete restores the default.",
        shortcutFailed: "macOS did not accept this shortcut. Try another combination.",
        permissionsIntro: "This build does not need a permission. Later tools will. You can open the system pane and the guide now so the path is familiar.",
        permissionAccessibility: "Accessibility",
        permissionAccessibilityDetail: "Later keyboard and protection tools need this to see shortcuts. The shell does not.",
        permissionScreenRecording: "Screen Recording",
        permissionScreenRecordingDetail: "Later screenshot and recording tools need this. A grant applies only after a relaunch.",
        permissionNotNeededYet: "Not needed in this build.",
        permissionRequest: "Request…",
        permissionGranted: "Granted",
        guideTitle: "Allow access",
        guideStepOpen: "System Settings opens the privacy list.",
        guideStepToggle: "Turn FixDock on. If the switch is already on and nothing happens, start over.",
        guideStepReturn: "Come back here. This card notices the grant.",
        guideWaiting: "Waiting for the grant…",
        guideGranted: "Granted",
        guideRelaunch: "Relaunch",
        guideStaleHint: "A switch left by an older copy stays on while this copy is still blocked.",
        guideStartOver: "Start over",
        guideClose: "Close",
        onboardingWelcomeTitle: "FixDock",
        onboardingWelcomeBody: "A menu bar app for a repair bench. This build is the shell: the icon, settings, the feature list, this introduction, the permission guide, and one global shortcut. The tools are added in later versions. FixDock is a modified unofficial fork of vorssaint-utils. It is not affiliated with the original authors. It is free under GPL-3.0 and does not phone home.",
        onboardingLanguageTitle: "Language",
        onboardingFeaturesTitle: "Tools, later",
        onboardingFeaturesBody: "These eight are the planned tools, in the order they will be added. Choosing one here only saves the choice.",
        onboardingPermissionsTitle: "Permissions",
        onboardingPermissionsBody: "Nothing in this build reads the screen, the keyboard, or your files. When a tool needs a permission, FixDock asks then and shows a small guide beside System Settings.",
        onboardingFinishTitle: "The icon is in the menu bar",
        onboardingFinishBody: "Click it for the panel. Control-Option-Command-F opens it from anywhere. Right-click the icon for Settings and Quit.",
        onboardingContinue: "Continue",
        onboardingBack: "Back",
        onboardingSkip: "Skip",
        onboardingGetStarted: "Get started",
        aboutFork: "FixDock is a modified unofficial fork of vorssaint-utils. The original is GPL-3.0-or-later. Copyright (C) 2026 Vorssaint and the vorssaint-utils contributors. This build removes the original name, icon, signing identity, and update feed. It is not an official release.",
        aboutLicense: "License: GNU General Public License v3.0 or later. See the LICENSE and NOTICE files.",
        aboutNoTelemetry: "No account, no analytics, and no network calls.",
        aboutNoUpdates: "This build does not check for updates.",
        aboutUpstreamButton: "Original project",
        aboutRepositoryButton: "FixDock source",
        versionFormat: "Version %@"
    )
}
