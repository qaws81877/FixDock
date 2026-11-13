// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// One searchable label on a Settings page. Selecting it opens `destination`
/// (and `tab` on the Features page).
struct SettingsSearchItem: Hashable {
    enum Label: Hashable {
        /// The page's own title.
        case page
        case text(KeyPath<Strings, String>)
        /// A tool's row in the Features page's hub list.
        case feature(AppFeature)
        case permission(PermissionKind)
    }

    let destination: SettingsDestination
    /// Read only for `.shell(.features)`.
    let tab: FeaturesTab
    let label: Label

    func title(_ strings: Strings) -> String {
        switch label {
        case .page: return destination.title(strings)
        case .text(let keyPath): return strings[keyPath: keyPath]
        case .feature(let feature): return feature.title(strings)
        case .permission(let kind): return kind.title(strings)
        }
    }

    /// The page (and sub-tab) the label lives on, shown under it.
    func location(_ strings: Strings) -> String {
        let page = destination.title(strings)
        guard destination == .shell(.features), tab == .permissions else { return page }
        return "\(page) › \(tab.title(strings))"
    }
}

enum SettingsSearch {
    /// Every label on `destinations`, in their order, page title first.
    static func index(of destinations: [SettingsDestination]) -> [SettingsSearchItem] {
        destinations.flatMap(\.searchItems)
    }

    /// Items whose label contains `query` in the app's language or in English,
    /// so English typing finds Korean labels. Keeps index order and drops a
    /// label shown twice on the same page.
    static func results(for query: String, in index: [SettingsSearchItem], strings: Strings) -> [SettingsSearchItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        struct Shown: Hashable {
            let destination: SettingsDestination
            let tab: FeaturesTab
            let title: String
        }
        var shown = Set<Shown>()
        return index.filter { item in
            let title = item.title(strings)
            guard title.localizedStandardContains(needle)
                    || item.title(.enUS).localizedStandardContains(needle) else { return false }
            return shown.insert(Shown(destination: item.destination, tab: item.tab, title: title)).inserted
        }
    }
}

private extension SettingsDestination {
    var searchItems: [SettingsSearchItem] {
        switch self {
        case .shell(let page):
            return page.searchItems
        case .feature(let page):
            // The Screen capture page carries the recorder's tab too when
            // both capture tools are installed.
            let features: [AppFeature] = page.feature == .screenshot && AppFeature.screenRecorder.isAvailable
                ? [.screenshot, .screenRecorder]
                : [page.feature]
            let labels = [SettingsSearchItem.Label.page] + features.flatMap(\.searchLabels).map { .text($0) }
            return labels.map { SettingsSearchItem(destination: self, tab: .features, label: $0) }
        }
    }
}

private extension ShellPage {
    var searchItems: [SettingsSearchItem] {
        let destination = SettingsDestination.shell(self)
        func items(_ labels: [SettingsSearchItem.Label], tab: FeaturesTab = .features) -> [SettingsSearchItem] {
            labels.map { SettingsSearchItem(destination: destination, tab: tab, label: $0) }
        }
        func texts(_ keyPaths: [KeyPath<Strings, String>]) -> [SettingsSearchItem] {
            items([.page] + keyPaths.map { .text($0) })
        }
        switch self {
        case .general:
            return texts([\.languageTitle, \.launchAtLogin, \.feedbackTitle, \.relaunch])
        case .features:
            return items([.page] + AppFeature.allCases.map { .feature($0) })
                + items([.text(\.tabPermissions)] + PermissionKind.allCases.map { .permission($0) }, tab: .permissions)
        case .shortcut:
            return texts([\.shortcutTitle])
        case .about:
            return texts([\.aboutRepositoryButton, \.aboutUpstreamButton, \.updatesTitle,
                          \.updateAutomaticToggle, \.updateShowNotesToggle])
        case .updateLog:
            return texts([])
        case .advanced:
            return texts([\.backupTitle, \.backupExport, \.backupImport, \.tabPermissions, \.resetPermissionsButton])
        }
    }
}

extension AppFeature {
    /// Headings, section titles and control labels on the tool's Settings
    /// page, not captions. No `default:` arm: a new tool decides here.
    var searchLabels: [KeyPath<Strings, String>] {
        switch self {
        case .urlCleaner:
            return [\.urlCleanerEnable, \.urlCleanerRulesTitle, \.urlCleanerManualTitle]
        case .quitWindowProtection:
            return [\.quitProtectionEnabled, \.quitProtectionMode, \.quitProtectionModifier,
                    \.quitProtectionAppScope, \.quitProtectionExceptions, \.quitProtectionFeedback]
        case .cleaningMode:
            return [\.cleaningModeStartNow, \.cleaningModeClickPolicyTitle, \.cleaningModeKeepScreenVisibleToggle]
        case .textSnippets:
            return [\.snippetsEnable, \.snippetsAddButton]
        case .mediaTools:
            return [\.mediaToolImage, \.mediaToolVideo, \.mediaImageSection, \.mediaVideoSection,
                    \.mediaPresetLabel, \.mediaFormatLabel, \.mediaResizeToggle, \.mediaMetadataLabel,
                    \.mediaSizingLabel, \.mediaOutputLabel]
        case .airdropAutoZip:
            return [\.airdropEnable, \.airdropHowTitle]
        case .cleaner:
            return [\.cleanerScan, \.cleanerSafeSection, \.cleanerReviewSection]
        case .screenshot:
            return [\.screenshotShortcutsTitle, \.screenshotShortcutOverlay, \.screenshotShortcutFullScreen,
                    \.screenshotAfterTitle, \.screenshotShowPreview, \.screenshotSaveToFile, \.screenshotFolder,
                    \.screenshotCopyToClipboard, \.screenshotOverlayTitle, \.screenshotCaptureSounds,
                    \.screenshotSnapToLines, \.screenshotLoupeTitle, \.screenshotLoupeAtStart,
                    \.screenshotColorFormatTitle, \.screenshotToolKeysTitle, \.screenshotKeysTitle]
        case .screenRecorder:
            return [\.recorderSectionStart, \.recorderCountdownLabel, \.recorderSectionCapture,
                    \.recorderSystemAudioToggle, \.recorderMicrophoneToggle, \.recorderPointerToggle,
                    \.recorderTypingToggle, \.recorderFrameRateLabel, \.recorderQualityLabel,
                    \.recorderEditorSettingsSection, \.screenshotPreviewPositionTitle,
                    \.recorderEditorSettingsAutomaticZoomToggle, \.recorderEditorSettingsGIFSizeLabel,
                    \.recorderEditorSettingsGIFFrameRateLabel]
        case .inputSwitch:
            return [\.inputSwitchEnabledLabel, \.inputSwitchKeyLabel, \.inputSwitchLongPressLabel]
        case .clipboardHistory:
            return [\.clipboardHistoryEnable, \.clipboardHistoryShortcut, \.clipboardHistoryRetentionTitle,
                    \.clipboardHistoryRecordsMedia, \.clipboardHistoryImageBudgetTitle,
                    \.clipboardHistoryExcludedTitle]
        case .layoutFix:
            return [\.layoutFixEnable, \.layoutFixExcludedTitle]
        }
    }
}
