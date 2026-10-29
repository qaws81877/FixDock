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
    let urlCleanerEnable: String
    let urlCleanerEnableCaption: String
    let urlCleanerLocalNote: String
    let urlCleanerActiveNow: String
    let urlCleanerRulesTitle: String
    let urlCleanerRulesAddSite: String
    let urlCleanerRulesAddButton: String
    let urlCleanerRulesCaption: String
    let urlCleanerRulesCoverageCaption: String
    let urlCleanerRulesParameterPlaceholder: String
    let urlCleanerRulesMatchCaption: String
    let urlCleanerRulesRestoreSiteButton: String
    let urlCleanerRulesRemoveSiteButton: String
    let urlCleanerRulesRemoveButton: String
    let urlCleanerRulesCountSingular: String
    let urlCleanerRulesCountPluralFormat: String
    let urlCleanerRulesAllSites: String
    let urlCleanerManualTitle: String
    let urlCleanerInputPlaceholder: String
    let urlCleanerClearButton: String
    let urlCleanerPasteButton: String
    let urlCleanerCopyButton: String
    let urlCleanerOutputPlaceholder: String
    let urlCleanerCopied: String
    let urlCleanerNoURL: String
    let urlCleanerNoChange: String
    let urlCleanerCleaned: String
    let urlCleanerRemovedFormat: String
    let disclosureExpanded: String
    let disclosureCollapsed: String
    let quitProtectionIntro: String
    let quitProtectionAccessibilityCaption: String
    let quitProtectionNeedsAccessibility: String
    let quitProtectionActiveNow: String
    let quitProtectionEnabled: String
    let quitProtectionEnabledCaption: String
    let quitProtectionMode: String
    let quitProtectionHold: String
    let quitProtectionDoublePress: String
    let quitProtectionExtraModifier: String
    let quitProtectionHoldDuration: String
    let quitProtectionDoublePressInterval: String
    let quitProtectionModifier: String
    let quitProtectionAppScope: String
    let quitProtectionAllApps: String
    let quitProtectionSelectedOnly: String
    let quitProtectionAllExceptSelected: String
    let quitProtectionExceptions: String
    let quitProtectionNoExceptions: String
    let quitProtectionAddApp: String
    let quitProtectionRemoveApp: String
    let quitProtectionFeedback: String
    let quitProtectionHoldQuitHUDFormat: String
    let quitProtectionHoldCloseHUDFormat: String
    let quitProtectionDoubleQuitHUDFormat: String
    let quitProtectionDoubleCloseHUDFormat: String
    let quitProtectionExtraQuitHUDFormat: String
    let quitProtectionExtraCloseHUDFormat: String
    let quitProtectionCancelHint: String
    let quitProtectionShiftKey: String
    let quitProtectionOptionKey: String
    let quitProtectionControlKey: String
    let permissionNeededNow: String
    let cleaningModeStartNow: String
    let cleaningModePanelCaption: String
    let cleaningModeUnlockCaption: String
    let cleaningModeNeedsAccessibility: String
    let cleaningModeOverlayTitle: String
    let cleaningModeOverlaySubtitle: String
    let cleaningModeOverlayUnlock: String
    let cleaningModeOverlayMouseHint: String
    let cleaningModeKeepScreenVisibleToggle: String
    let cleaningModeKeepScreenVisibleCaption: String
    let cleaningModeClickPolicyTitle: String
    let cleaningModeClickPolicyAllow: String
    let cleaningModeClickPolicyHold: String
    let cleaningModeClickPolicyBlock: String
    let cleaningModeClickPolicyCaption: String
    let cleaningModeOverlayHoldUnlock: String
    let cleaningModeOverlayAutoUnlockHint: String
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
        panelEmptyBody: "Open Settings to choose tools. URL cleaner runs in this build. The others are saved for a later build.",
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
        featuresIntro: "Tools marked Not in this build only remember the choice for a later build. Keyboard tools ask for Accessibility when you install them.",
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
        featureCleaningModeSummary: "Locks the keyboard while you clean the screen or keyboard.",
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
        urlCleanerEnable: "Clean links you copy",
        urlCleanerEnableCaption: "When a copied link has tracking parameters, FixDock rewrites the clipboard with the clean link.",
        urlCleanerLocalNote: "Cleaning happens on this Mac. The link is not sent anywhere.",
        urlCleanerActiveNow: "Watching the clipboard",
        urlCleanerRulesTitle: "Cleaning rules",
        urlCleanerRulesAddSite: "Add a site",
        urlCleanerRulesAddButton: "Add",
        urlCleanerRulesCaption: "A site attaches these parameters to its share links to track where the link came from. On, a name is removed. Off, it stays. Names you add can be deleted.",
        urlCleanerRulesCoverageCaption: "The list covers a site’s different share paths, which is why it is long. A real link usually carries only a few of them.",
        urlCleanerRulesParameterPlaceholder: "Parameter name",
        urlCleanerRulesMatchCaption: "Write the name to the left of the =, like utm_source.",
        urlCleanerRulesRestoreSiteButton: "Turn on every rule for this site",
        urlCleanerRulesRemoveSiteButton: "Turn off every rule for this site",
        urlCleanerRulesRemoveButton: "Delete name",
        urlCleanerRulesCountSingular: "1 parameter",
        urlCleanerRulesCountPluralFormat: "%d parameters",
        urlCleanerRulesAllSites: "All sites",
        urlCleanerManualTitle: "Clean a link",
        urlCleanerInputPlaceholder: "Paste a link",
        urlCleanerClearButton: "Clear",
        urlCleanerPasteButton: "Paste",
        urlCleanerCopyButton: "Copy",
        urlCleanerOutputPlaceholder: "The cleaned link appears here",
        urlCleanerCopied: "Copied",
        urlCleanerNoURL: "That is not a web link",
        urlCleanerNoChange: "Nothing to remove",
        urlCleanerCleaned: "Cleaned",
        urlCleanerRemovedFormat: "Removed %@",
        disclosureExpanded: "Expanded",
        disclosureCollapsed: "Collapsed",
        quitProtectionIntro: "Configure each shortcut independently. The original action passes only after the selected confirmation.",
        quitProtectionAccessibilityCaption: "Protection uses Accessibility to observe only ⌘Q and ⌘W globally.",
        quitProtectionNeedsAccessibility: "Protection is off until FixDock has Accessibility.",
        quitProtectionActiveNow: "Protecting",
        quitProtectionEnabled: "Protect this shortcut",
        quitProtectionEnabledCaption: "Other Command shortcuts continue to work normally.",
        quitProtectionMode: "Confirmation mode",
        quitProtectionHold: "Hold to confirm",
        quitProtectionDoublePress: "Double press",
        quitProtectionExtraModifier: "Require extra modifier",
        quitProtectionHoldDuration: "Hold duration",
        quitProtectionDoublePressInterval: "Double press interval",
        quitProtectionModifier: "Extra modifier",
        quitProtectionAppScope: "Applications",
        quitProtectionAllApps: "All applications",
        quitProtectionSelectedOnly: "Selected applications only",
        quitProtectionAllExceptSelected: "All except selected applications",
        quitProtectionExceptions: "Selected applications",
        quitProtectionNoExceptions: "No applications selected",
        quitProtectionAddApp: "Add application…",
        quitProtectionRemoveApp: "Remove",
        quitProtectionFeedback: "Show visual feedback",
        quitProtectionHoldQuitHUDFormat: "Hold %@ to quit",
        quitProtectionHoldCloseHUDFormat: "Hold %@ to close",
        quitProtectionDoubleQuitHUDFormat: "Press %@ again to quit",
        quitProtectionDoubleCloseHUDFormat: "Press %@ again to close",
        quitProtectionExtraQuitHUDFormat: "Use %@ to quit",
        quitProtectionExtraCloseHUDFormat: "Use %@ to close",
        quitProtectionCancelHint: "Esc cancels",
        quitProtectionShiftKey: "Shift",
        quitProtectionOptionKey: "Option",
        quitProtectionControlKey: "Control",
        permissionNeededNow: "An installed tool uses this.",
        cleaningModeStartNow: "Lock keyboard now",
        cleaningModePanelCaption: "Locks the keyboard so you can clean safely.",
        cleaningModeUnlockCaption: "Press Escape 5 times to end it. The setting below decides what the mouse can do.",
        cleaningModeNeedsAccessibility: "Cleaning mode needs Accessibility to lock the keyboard.",
        cleaningModeOverlayTitle: "Keyboard locked for cleaning",
        cleaningModeOverlaySubtitle: "Press Escape 5 times to unlock",
        cleaningModeOverlayUnlock: "Unlock",
        cleaningModeOverlayMouseHint: "Your mouse and trackpad still work",
        cleaningModeKeepScreenVisibleToggle: "Keep screen visible",
        cleaningModeKeepScreenVisibleCaption: "Shows a discreet indicator in the corner of the screen instead of blacking out content.",
        cleaningModeClickPolicyTitle: "Clicks while locked",
        cleaningModeClickPolicyAllow: "Allow clicks; click Unlock to end",
        cleaningModeClickPolicyHold: "Allow clicks; hold Unlock for 2 seconds",
        cleaningModeClickPolicyBlock: "Block clicks; unlock by itself after 3 minutes",
        cleaningModeClickPolicyCaption: "Escape 5 times unlocks in every mode. With clicks blocked the pointer still moves, but nothing on screen can be clicked.",
        cleaningModeOverlayHoldUnlock: "Hold to unlock",
        cleaningModeOverlayAutoUnlockHint: "Clicks are blocked. The lock ends by itself after 3 minutes.",
        shortcutTitle: "Open the panel",
        shortcutCaption: "Works without Accessibility. The default is Control-Option-Command-F.",
        shortcutRecord: "Record shortcut",
        shortcutRecording: "Press the new shortcut.",
        shortcutEscapeHint: "Escape cancels.",
        shortcutDeleteHint: "Delete restores the default.",
        shortcutFailed: "macOS did not accept this shortcut. Try another combination.",
        permissionsIntro: "The keyboard tools need Accessibility: quit and close protection and cleaning mode. Nothing else in this build needs a permission. Later tools will ask for more.",
        permissionAccessibility: "Accessibility",
        permissionAccessibilityDetail: "Quit and close protection uses this to see ⌘Q and ⌘W. Cleaning mode uses it to lock the keyboard.",
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
        onboardingFeaturesBody: "These eight are the planned tools, in the order they are added. URL cleaner works now. Choosing another one only saves the choice.",
        onboardingPermissionsTitle: "Permissions",
        onboardingPermissionsBody: "Only the keyboard tools touch the keyboard: quit and close protection watches ⌘Q and ⌘W, and cleaning mode blocks keys only while it is on. Nothing reads the screen or your files. When a tool needs a permission, FixDock asks then and shows a small guide beside System Settings.",
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
