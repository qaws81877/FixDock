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

/// The privacy list names as the running System Settings shows them. Each
/// rename has its own threshold; Screen Recording has none because its
/// current name covers every supported macOS. Decided once per process.
///
/// Every Korean name and grant form ends in a final consonant (사용, 접근,
/// 녹음, 권한), so the particles in the table (을/이/에서) fit both eras. A
/// rename to a vowel-final name must re-check every Korean entry.
struct PermissionListNames {
    let accessibility: String
    let screenRecording: String
    let fullDiskAccess: String
    /// Korean running text names a grant with 권한 exactly once.
    private let grantWord: String?

    var accessibilityGrant: String { grant(accessibility) }
    var screenRecordingGrant: String { grant(screenRecording) }
    var fullDiskAccessGrant: String { grant(fullDiskAccess) }

    private func grant(_ name: String) -> String {
        guard let word = grantWord, !name.hasSuffix(word) else { return name }
        return name + " " + word
    }

    static let en = PermissionListNames(
        accessibility: renamed(since: 27, from: "Accessibility", to: "Device Control and Data Access"),
        screenRecording: "Screen & System Audio Recording",
        fullDiskAccess: "Full Disk Access",
        grantWord: nil)

    static let ko = PermissionListNames(
        accessibility: renamed(since: 27, from: "손쉬운 사용", to: "기기 제어 및 데이터 접근"),
        screenRecording: "화면 및 시스템 오디오 녹음",
        fullDiskAccess: renamed(since: 27, from: "전체 디스크 접근", to: "전체 디스크 접근 권한"),
        grantWord: "권한")

    private static let forcesLegacy = AppInfo.isDeveloperBuild
        && UserDefaults.standard.bool(forKey: DefaultsKey.permissionListNamesLegacy)

    private static func renamed(since major: Int, from old: String, to new: String) -> String {
        let renamed = !forcesLegacy && ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0))
        return renamed ? new : old
    }
}

private let enNames = PermissionListNames.en

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
    let panelNotInBuild: String
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
    let snippetsEnable: String
    let snippetsEnableCaption: String
    let snippetsSecureNote: String
    let snippetsNeedsAccessibility: String
    let snippetsActiveNow: String
    let keyTapSecureInputFormat: String
    let keyTapSecureInputExitedFormat: String
    let keyTapUnknownApp: String
    let keyTapStartFailed: String
    let feedbackButton: String
    let feedbackTitle: String
    let feedbackCaption: String
    let feedbackCommentPrompt: String
    let feedbackPreviewLabel: String
    let feedbackCopyButton: String
    let feedbackCopied: String
    let feedbackClose: String
    let feedbackSectionCaption: String
    let feedbackKindBug: String
    let feedbackKindIdea: String
    let feedbackIdeaPrompt: String
    let feedbackIncludeTechInfo: String
    let feedbackIdeaNotice: String
    let feedbackSendButton: String
    let feedbackSending: String
    let feedbackSent: String
    let feedbackSendFailed: String
    let snippetsUnreadable: String
    let snippetsAddButton: String
    let snippetsNewTitle: String
    let snippetsEditTitle: String
    let snippetsNameLabel: String
    let snippetsNamePlaceholder: String
    let snippetsTriggerLabel: String
    let snippetsTriggerPlaceholder: String
    let snippetsReplacementLabel: String
    let snippetsExpansionLabel: String
    let snippetsExpansionImmediate: String
    let snippetsExpansionDelimiter: String
    let snippetsIgnoreCaseLabel: String
    let snippetsVariablesHint: String
    let snippetsVariablesCaption: String
    let snippetsEmptyList: String
    let snippetsDuplicateTrigger: String
    let snippetsTriggerTooShort: String
    let snippetsDeleteButton: String
    let snippetsSaveButton: String
    let snippetsCancelButton: String
    let snippetsCountFormat: String
    let featureMediaName: String
    let featureMediaSummary: String
    let mediaIntro: String
    let mediaImageSection: String
    let mediaPresetLabel: String
    let mediaPresetLow: String
    let mediaPresetMedium: String
    let mediaPresetHigh: String
    let mediaPresetLowCaption: String
    let mediaPresetMediumCaption: String
    let mediaPresetHighCaption: String
    let mediaOutputLabel: String
    let mediaOutputZip: String
    let mediaOutputFiles: String
    let mediaOutputZipCaption: String
    let mediaZipResultFormat: String
    let mediaErrorZip: String
    let mediaLocalNote: String
    let mediaMoreOptions: String
    let mediaToolImage: String
    let mediaToolVideo: String
    let mediaVideoSection: String
    let mediaSizingLabel: String
    let mediaSizingResolution: String
    let mediaSizingFileSize: String
    let mediaVideoLowCaption: String
    let mediaVideoMediumCaption: String
    let mediaVideoHighCaption: String
    let mediaTargetSizeLabel: String
    let mediaMegabytesUnit: String
    let mediaTargetSizeCaption: String
    let mediaVideoDropHint: String
    let mediaVideoPrivacyNote: String
    let mediaFileProgressFormat: String
    let mediaErrorNoVideo: String
    let mediaErrorTargetTooSmall: String
    let mediaErrorVideoUnsupported: String
    let mediaErrorVideoFailed: String
    let airdropEnable: String
    let airdropWatching: String
    let airdropProcessing: String
    let airdropFolderUnavailable: String
    let airdropHowTitle: String
    let airdropHowCandidates: String
    let airdropHowBatch: String
    let airdropHowZip: String
    let airdropHowOriginals: String
    let airdropHowOthers: String
    let airdropHowLocation: String
    let airdropKeptFormat: String
    let airdropOpenDownloads: String
    let airdropNotifyDoneFormat: String
    let airdropNotifyFailed: String
    let permissionFullDiskAccess: String
    let permissionFullDiskAccessDetail: String
    let cleanerIntro: String
    let cleanerPermanentNote: String
    let cleanerNeedsFullDiskAccess: String
    let cleanerHomeUnusable: String
    let cleanerScan: String
    let cleanerScanning: String
    let cleanerCancel: String
    let cleanerScanAgain: String
    let cleanerSafeSection: String
    let cleanerReviewSection: String
    let cleanerCatCaches: String
    let cleanerCatLogs: String
    let cleanerCatDeveloper: String
    let cleanerCatBrowserCaches: String
    let cleanerCatDownloads: String
    let cleanerCatLeftovers: String
    let cleanerCatLoginItems: String
    let cleanerCatDeviceBackups: String
    let cleanerCatLargeDeveloper: String
    let cleanerCatTrash: String
    let cleanerNothingFound: String
    let cleanerSelectedFormat: String
    let cleanerRemoveButtonFormat: String
    let cleanerLockedHelp: String
    let cleanerExceptionHelp: String
    let cleanerExceptionRemoveHelp: String
    let cleanerRevealHelp: String
    let cleanerConfirmTitleFormat: String
    let cleanerConfirmMessageFormat: String
    let cleanerConfirmButton: String
    let cleanerBackupConfirmTitle: String
    let cleanerBackupConfirmMessageFormat: String
    let cleanerRemoving: String
    let cleanerDoneFormat: String
    let cleanerNotRemovedFormat: String
    let cleanerSkippedLabel: String
    let cleanerFailedLabel: String
    let cleanerOpenButton: String
    let mediaPresetCaption: String
    let mediaFormatLabel: String
    let mediaFormatOriginal: String
    let mediaResizeToggle: String
    let mediaPixelsFormat: String
    let mediaMetadataLabel: String
    let mediaMetadataKeep: String
    let mediaMetadataRemoveLocation: String
    let mediaMetadataRemoveAll: String
    let mediaDropHint: String
    let mediaOutputCaption: String
    let mediaRunningFormat: String
    let mediaCancel: String
    let mediaCancelled: String
    let mediaClearResults: String
    let mediaShowInFinder: String
    let mediaResultSizeFormat: String
    let mediaResultGrewFormat: String
    let mediaResultKeptOriginal: String
    let mediaSkippedFormat: String
    let mediaErrorUnreadable: String
    let mediaErrorUnsupported: String
    let mediaErrorTooLarge: String
    let mediaErrorEncode: String
    let mediaErrorLocation: String
    let mediaErrorWrite: String
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
    let guideDragLead: String
    let guideCaseMissingTitle: String
    let guideCaseMissingAction: String
    let guideCaseOffTitle: String
    let guideCaseOffAction: String
    let guideCaseStuckTitle: String
    let guideCaseStuckAction: String
    let guideDragConfirm: String
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
    let aboutUpstreamButton: String
    let aboutRepositoryButton: String
    let screenCapturePageTitle: String
    let screenshotToolScreenshot: String
    let screenshotToolRecording: String
    let screenshotRecordingLater: String
    let screenshotFilePrefix: String
    let screenshotCaptureFailed: String
    let screenshotFolderUnavailable: String
    let screenshotPanelFullScreen: String
    let screenshotHint: String
    let screenshotHintScrolling: String
    let screenshotKeyRepeat: String
    let screenshotKeyLoupe: String
    let screenshotKeyLoupeLarge: String
    let screenshotKeyColor: String
    let screenshotKeyScroll: String
    let screenshotKeyCancel: String
    let screenshotNoLastRegion: String
    let screenshotColorNeedsLoupe: String
    let screenshotColorCopied: String
    let screenshotScrollingPrompt: String
    let screenshotScrollingHeight: String
    let screenshotScrollingDone: String
    let screenshotScrollingSkipped: String
    let screenshotNeedsPermission: String
    let screenshotGrantPermission: String
    let screenshotShortcutsTitle: String
    let screenshotShortcutOverlay: String
    let screenshotShortcutFullScreen: String
    let screenshotAfterTitle: String
    let screenshotSaveToFile: String
    let screenshotFolder: String
    let screenshotChooseFolder: String
    let screenshotUseDesktop: String
    let screenshotCopyToClipboard: String
    let screenshotNothingHappens: String
    let screenshotKeysTitle: String
    let screenshotKeyHelpScreenshot: String
    let screenshotKeyHelpRecording: String
    let screenshotKeyHelpRepeat: String
    let screenshotKeyHelpLoupe: String
    let screenshotKeyHelpColor: String
    let screenshotKeyHelpScroll: String
    let screenshotKeyHelpFull: String
    let screenshotKeyHelpMove: String
    let screenshotWindowLimit: String
    let shortcutConflict: String
    let screenshotShowPreview: String
    let screenshotPreviewSavesOnly: String
    let screenshotPreviewShare: String
    let screenshotPreviewSave: String
    let screenshotPreviewCopy: String
    let screenshotPreviewEdit: String
    let screenshotPreviewQR: String
    let screenshotPreviewTextCopied: String
    let screenshotToastCopied: String
    let screenshotToastSaved: String
    let screenshotPreviewNoText: String
    let screenshotPreviewDragHint: String
    let screenshotPreviewPositionTitle: String
    let screenshotPreviewPositionAutomatic: String
    let screenshotPreviewPositionBottomRight: String
    let screenshotPreviewPositionBottomLeft: String
    let screenshotPreviewPositionTopRight: String
    let screenshotPreviewPositionTopLeft: String
    let screenshotLoupeTitle: String
    let screenshotLoupeAtStart: String
    let screenshotOverlayTitle: String
    let screenshotCaptureSounds: String
    let screenshotCaptureSoundsNote: String
    let screenshotSnapToLines: String
    let screenshotColorFormatTitle: String
    let screenshotColorFormatHex: String
    let screenshotColorFormatHexPlain: String
    let screenshotColorFormatRGB: String
    let screenshotColorFormatHSL: String
    let screenshotQRTitle: String
    let screenshotQRCopy: String
    let screenshotQROpen: String
    let screenshotPinSaveAs: String
    let screenshotPinOpacity: String
    let screenshotPinClose: String
    let screenshotPinCloseAll: String
    let screenshotPinExtractText: String
    let screenshotPinSettings: String
    let screenshotPinShortcuts: String
    let screenshotPinOpenSettings: String
    let screenshotPinHiddenFormat: String
    let screenshotPinTextTitle: String
    let screenshotPinTextCopyAll: String
    let screenshotEditorTitle: String
    let screenshotEditorToolSelect: String
    let screenshotEditorToolArrow: String
    let screenshotEditorToolText: String
    let screenshotEditorToolRect: String
    let screenshotEditorToolFreehand: String
    let screenshotEditorToolLine: String
    let screenshotEditorToolEllipse: String
    let screenshotEditorColor: String
    let screenshotEditorStroke: String
    let screenshotEditorTextSize: String
    let screenshotEditorBringForward: String
    let screenshotEditorSendBackward: String
    let screenshotEditorTextPlaceholder: String
    let screenshotEditorZoomFit: String
    let screenshotEditorZoomActual: String
    let screenshotEditorZoomHint: String
    let screenshotEditorSaveMenu: String
    let screenshotEditorDone: String
    let screenshotEditorDiscardTitle: String
    let screenshotEditorDiscardMessage: String
    let screenshotEditorDiscard: String
    let screenshotEditorCancel: String
    let screenshotEditorToolBlur: String
    let screenshotEditorToolCrop: String
    let screenshotEditorToolSticker: String
    let screenshotEditorToolHighlight: String
    let screenshotEditorToolCounter: String
    let screenshotEditorToolRedact: String
    let screenshotEditorToolSpotlight: String
    let screenshotEditorMoreTools: String
    let screenshotEditorArrowStyle: String
    let screenshotEditorArrowFilled: String
    let screenshotEditorArrowOutline: String
    let screenshotEditorArrowOpen: String
    let screenshotEditorArrowDoubleEnded: String
    let screenshotEditorArrowScribbly: String
    let screenshotEditorBlurStyle: String
    let screenshotEditorBlurPixelate: String
    let screenshotEditorBlurErase: String
    let screenshotEditorBlurTextOnly: String
    let screenshotEditorBlurStrength: String
    let screenshotEditorSpotlightDim: String
    let screenshotEditorShadows: String
    let screenshotEditorCropApply: String
    let screenshotEditorToolExpandCanvas: String
    let screenshotEditorPastedImage: String
    let screenshotEditorCanvasFill: String
    let screenshotEditorCanvasFillWhite: String
    let screenshotEditorCanvasFillClear: String
    let screenshotEditorCanvasFillCustom: String
    let screenshotEditorCanvasHint: String
    let screenshotEditorBackdrop: String
    let screenshotEditorBackdropNone: String
    let screenshotEditorBackdropPreset: String
    let screenshotEditorBackdropSaved: String
    let screenshotEditorBackdropWallpaper: String
    let screenshotEditorBackdropChooseImage: String
    let screenshotEditorBackdropSolid: String
    let screenshotEditorBackdropGradient: String
    let screenshotEditorBackdropSave: String
    let screenshotEditorPresetRemove: String
    let screenshotEditorBackdropPadding: String
    let screenshotEditorBackdropCorners: String
    let screenshotEditorBackdropBlur: String
    let screenshotEditorWatermark: String
    let screenshotEditorWatermarkText: String
    let screenshotEditorWatermarkImage: String
    let screenshotEditorWatermarkPlaceholder: String
    let screenshotEditorWatermarkSave: String
    let screenshotEditorWatermarkPosition: String
    let screenshotEditorWatermarkSize: String
    let screenshotEditorWatermarkRotation: String
    let screenshotEditorAnchorTopLeading: String
    let screenshotEditorAnchorTop: String
    let screenshotEditorAnchorTopTrailing: String
    let screenshotEditorAnchorLeading: String
    let screenshotEditorAnchorCenter: String
    let screenshotEditorAnchorTrailing: String
    let screenshotEditorAnchorBottomLeading: String
    let screenshotEditorAnchorBottom: String
    let screenshotEditorAnchorBottomTrailing: String
    let screenshotEditorToolOrder: String
    let screenshotToolKeysTitle: String
    let screenshotToolKeysToggle: String
    let screenshotToolKeysCaption: String
    let screenshotToolKeyNone: String
    let screenshotToolMoveUp: String
    let screenshotToolMoveDown: String
    let screenshotToolOrderReset: String
    let screenshotToolKeyPress: String
    let screenshotToolKeyRecordingHint: String
    let screenshotToolKeyReserved: String
    let screenshotToolKeyTaken: String
    let screenshotToolKeyRemove: String
    // Screen recorder (7.7 A+B): add strings below this line.
    let recorderPermissionMicrophone: String
    let recorderPermissionMicrophoneDetail: String
    let recorderPermissionAudioCapture: String
    let recorderPermissionAudioCaptureDetail: String
    let recorderFilePrefix: String
    let recorderRecordFailed: String
    let recorderMicrophoneUnavailable: String
    let recorderStoppedNoSpace: String
    let recorderNoSpaceTitle: String
    let recorderNoSpaceMessage: String
    let recorderIndicatorTooltip: String
    let recorderPause: String
    let recorderResume: String
    let recorderStop: String
    let recorderSavedFormat: String
    let recorderFolderUnavailable: String
    let recorderSaveElsewhereMessage: String
    let recorderCountdownLabel: String
    let recorderCountdownOff: String
    let recorderCountdownSecondsFormat: String
    let recorderQualityLabel: String
    let recorderQualitySmall: String
    let recorderQualityBalanced: String
    let recorderQualityHigh: String
    let recorderQualityCaption: String
    let recorderFrameRateLabel: String
    let recorderFrameRateFormat: String
    let recorderSystemAudioToggle: String
    let recorderSystemAudioCaption: String
    let recorderMicrophoneToggle: String
    let recorderMicrophoneCaption: String
    let recorderPointerToggle: String
    let recorderPointerCaption: String
    let recorderTypingToggle: String
    let recorderTypingCaption: String
    let recorderStartHint: String
    let recorderStopHint: String
    let recorderNeedsScreenshot: String
    let recorderFolderFormat: String
    let recorderRecordingFormat: String
    let recorderSectionStart: String
    let recorderSectionCapture: String
    let recorderPreviewShowInFinder: String
    let recorderPreviewShare: String
    let recorderPreviewEdit: String
    let recorderPreviewClose: String
    let recorderPreviewDragHint: String
    // These two lines keep the blocks apart so the A+B and C
    // branches merge without touching each other.
    // Screen recorder editor (7.7 C): add strings below this line.
    let recorderEditorAddBlurButton: String
    let recorderEditorAddImageButton: String
    let recorderEditorAddTextButton: String
    let recorderEditorAddZoomButton: String
    let recorderEditorAudioVolumeLabel: String
    let recorderEditorBackgroundSectionLabel: String
    let recorderEditorBackToOptions: String
    let recorderEditorBlurCaption: String
    let recorderEditorBlurLaneEmptyHint: String
    let recorderEditorBlurLaneLabel: String
    let recorderEditorBlurPickArea: String
    let recorderEditorBlurPickAreaHint: String
    let recorderEditorCancelButton: String
    let recorderEditorClickRingToggle: String
    let recorderEditorCopiedHUD: String
    let recorderEditorCopyAndDeleteButton: String
    let recorderEditorCopyButton: String
    let recorderEditorCopyGIFButton: String
    let recorderEditorCreateAutomaticZooms: String
    let recorderEditorCutOutButton: String
    let recorderEditorDiscardButton: String
    let recorderEditorDiscardMessage: String
    let recorderEditorDiscardSavedMessage: String
    let recorderEditorDiscardTitle: String
    let recorderEditorEditorTitle: String
    let recorderEditorExportCustom: String
    let recorderEditorExportDuration: String
    let recorderEditorExportFailed: String
    let recorderEditorExportingLabel: String
    let recorderEditorExportPreviewNote: String
    let recorderEditorExportSpeed: String
    let recorderEditorFolderLabel: String
    let recorderEditorImageImportFailed: String
    let recorderEditorImageLaneEmptyHint: String
    let recorderEditorImageLaneLabel: String
    let recorderEditorImageOpacityLabel: String
    let recorderEditorImagePositionLabel: String
    let recorderEditorImageSizeLabel: String
    let recorderEditorLookClean: String
    let recorderEditorLookLabel: String
    let recorderEditorLookRaw: String
    let recorderEditorLookStudio: String
    let recorderEditorMicrophoneTrackLabel: String
    let recorderEditorNoPointerNote: String
    let recorderEditorPointerSectionLabel: String
    let recorderEditorPointerShowToggle: String
    let recorderEditorPointerSizeLabel: String
    let recorderEditorPointerSmoothingCinematic: String
    let recorderEditorPointerSmoothingLabel: String
    let recorderEditorPointerSmoothingLight: String
    let recorderEditorPointerSmoothingOff: String
    let recorderEditorPointerSmoothingSmooth: String
    let recorderEditorPresetNamePlaceholder: String
    let recorderEditorPresetsButton: String
    let recorderEditorQualityBalanced: String
    let recorderEditorQualityHigh: String
    let recorderEditorQualityLabel: String
    let recorderEditorQualitySmall: String
    let recorderEditorRegenerateZooms: String
    let recorderEditorRemoveAudio: String
    let recorderEditorRemovePreset: String
    let recorderEditorRemoveText: String
    let recorderEditorRemoveZoom: String
    let recorderEditorRestoreAudio: String
    let recorderEditorSaveAsButton: String
    let recorderEditorSaveButton: String
    let recorderEditorSavedHUDFormat: String
    let recorderEditorSaveGIFButton: String
    let recorderEditorSavePreset: String
    let recorderEditorSaveVideoButton: String
    let recorderEditorShapeLabel: String
    let recorderEditorShapeOriginal: String
    let recorderEditorShapeSquare: String
    let recorderEditorShapeVertical: String
    let recorderEditorShapeWide: String
    let recorderEditorSystemAudioTrackLabel: String
    let recorderEditorTextColorLabel: String
    let recorderEditorTextContentLabel: String
    let recorderEditorTextLaneEmptyHint: String
    let recorderEditorTextPlaceholder: String
    let recorderEditorTextPositionLabel: String
    let recorderEditorTextSizeLabel: String
    let recorderEditorThisBlurLabel: String
    let recorderEditorThisImageLabel: String
    let recorderEditorThisTextLabel: String
    let recorderEditorThisZoomLabel: String
    let recorderEditorTypingZoomCaption: String
    let recorderEditorTypingZoomToggle: String
    let recorderEditorZoomAmountLabel: String
    let recorderEditorZoomEmptyCaption: String
    let recorderEditorZoomEmptyTitle: String
    let recorderEditorZoomFollowsPointer: String
    let recorderEditorZoomLaneEmptyHint: String
    let recorderEditorZoomPickSpot: String
    let recorderEditorZoomPickSpotHint: String
    let recorderEditorZoomSectionLabel: String
    let recorderEditorZoomToggle: String
    let recorderEditorZoomWhereLabel: String
    let recorderEditorSettingsSection: String
    let recorderEditorSettingsAutomaticZoomToggle: String
    let recorderEditorSettingsAutomaticZoomCaption: String
    let recorderEditorSettingsGIFSizeLabel: String
    let recorderEditorSettingsGIFSizeSmall: String
    let recorderEditorSettingsGIFSizeMedium: String
    let recorderEditorSettingsGIFSizeLarge: String
    let recorderEditorSettingsGIFFrameRateLabel: String
    // Menu bar panel redesign.
    let panelQuickActionsTitle: String
    let panelOnOffTitle: String
    let panelEditCard: String
    let panelEditDone: String
    let panelResetCard: String
    let panelHideItem: String
    let panelShowItem: String
    let panelHiddenItem: String
    let panelDragHint: String
    let panelBack: String
    let panelPermissionMissingFormat: String
    let updatesTitle: String
    let updateAutomaticToggle: String
    let updateShowNotesToggle: String
    let updateCheckNow: String
    let updateCheckingStatus: String
    let updateUpToDateStatus: String
    let updateAvailableFormat: String
    let updateInstallButton: String
    let updateOpenReleasePage: String
    let updateDownloadingFormat: String
    let updateDownloadingStatus: String
    let updateVerifyingStatus: String
    let updateRestartingStatus: String
    let updateCheckFailedFormat: String
    let updateInstallFailedFormat: String
    let updateLastCheckedFormat: String
    let updateInertCaption: String
    let updateManualTranslocated: String
    let updateManualOutsideApplications: String
    let updateManualNotWritable: String
    let updateManualOtherVolume: String
    let updateBannerTitle: String
    let updateBannerAction: String
    let updatePreviewTitleFormat: String
    let updatePreviewCurrentFormat: String
    let updatePreviewSkipNotes: String
    let updatePreviewCancel: String
    let menuCheckForUpdates: String
    let updateUpdatedNoticeFormat: String
    let updateRolledBackNoticeFormat: String
    let updateNotAppliedNoticeFormat: String
    let updateRestoreFailedNotice: String
    let updateFailureUnreachable: String
    let updateFailureRateLimited: String
    let updateFailureServer: String
    let updateFailureUnreadable: String
    let updateFailureReleaseIncomplete: String
    let updateFailureBusyRecording: String
    let updateFailureBusyMedia: String
    let updateFailureBusyCleaning: String
    let updateFailureDownload: String
    let updateFailureDigest: String
    let updateFailureArchive: String
    let updateFailureSignature: String
    let updateFailureDisk: String
    let updateFailureHandoff: String
    let featureInputSwitchName: String
    let featureInputSwitchSummary: String
    let inputSwitchIntro: String
    let inputSwitchEnabledLabel: String
    let inputSwitchKeyLabel: String
    let inputSwitchKeyCapsLock: String
    let inputSwitchKeyRightCommand: String
    let inputSwitchKeyRightOption: String
    let inputSwitchKeyRightControl: String
    let inputSwitchCapsLockWarning: String
    let inputSwitchShortcutCaption: String
    let inputSwitchNeedsAccessibility: String
    let inputSwitchActiveNow: String
    let inputSwitchStatusLiveFormat: String
    let inputSwitchStatusPreparing: String
    let inputSwitchStatusAway: String
    let inputSwitchStatusRestoring: String
    let inputSwitchStatusDeveloperInert: String
    let inputSwitchStatusOwnedByFormat: String
    let inputSwitchStatusJournalUnreadable: String
    let inputSwitchProblemNoFreeFunctionKey: String
    let inputSwitchProblemHotkeyFailed: String
    let inputSwitchProblemActivationFailed: String
    let inputSwitchProblemHotkeyChanged: String
    let inputSwitchProblemKeyboardsPendingFormat: String
    let inputSwitchProblemOtherSwitcherFormat: String
    let inputSwitchRestoredToDefault: String
    let inputSwitchLongPressLabel: String
    let inputSwitchLongPressCaption: String
    let featureClipboardHistoryName: String
    let featureClipboardHistorySummary: String
    let clipboardHistoryEnable: String
    let clipboardHistoryEnableCaption: String
    let clipboardHistoryShortcut: String
    let clipboardHistoryShortcutCaption: String
    let clipboardHistoryAccessibilityGranted: String
    let clipboardHistoryAccessibilityMissing: String
    let clipboardHistoryRetentionTitle: String
    let clipboardHistoryRetentionOneDay: String
    let clipboardHistoryRetentionDaysFormat: String
    let clipboardHistoryRetentionForever: String
    let clipboardHistoryRetentionCaption: String
    let clipboardHistoryExcludedTitle: String
    let clipboardHistoryExcludedCaption: String
    let clipboardHistoryExcludedNone: String
    let clipboardHistoryExcludedAdd: String
    let clipboardHistoryExcludedRemove: String
    let clipboardHistoryClearUnpinned: String
    let clipboardHistoryClearConfirmFormat: String
    let clipboardHistoryClearConfirm: String
    let clipboardHistoryStoreProblemTitle: String
    let clipboardHistoryProblemNoContainer: String
    let clipboardHistoryProblemUnreadableFormat: String
    let clipboardHistoryProblemNotAFile: String
    let clipboardHistoryProblemTooLarge: String
    let clipboardHistoryProblemNewerFormat: String
    let clipboardHistoryProblemDamaged: String
    let clipboardHistoryProblemImagesWithoutHistory: String
    let clipboardHistoryProblemImageFolderNotAFolder: String
    let clipboardHistoryRevealFile: String
    let clipboardHistorySearchPlaceholder: String
    let clipboardHistoryEmpty: String
    let clipboardHistoryNoMatches: String
    let clipboardHistoryPinnedSection: String
    let clipboardHistoryPaste: String
    let clipboardHistoryCopy: String
    let clipboardHistorySwapLayout: String
    let clipboardHistoryPin: String
    let clipboardHistoryUnpin: String
    let clipboardHistoryDelete: String
    let clipboardHistoryToastCopied: String
    let clipboardHistoryToastNeedsAccessibility: String
    let clipboardHistoryToastUnavailable: String
    let clipboardHistoryAllTypes: String
    let clipboardHistoryKindImage: String
    let clipboardHistoryKindText: String
    let clipboardHistoryKindLink: String
    let clipboardHistoryKindColor: String
    let clipboardHistoryKindFile: String
    let clipboardHistoryKindEmail: String
    let clipboardHistoryEmptyImages: String
    let clipboardHistoryEmptyText: String
    let clipboardHistoryEmptyLinks: String
    let clipboardHistoryEmptyColors: String
    let clipboardHistoryEmptyFiles: String
    let clipboardHistoryEmptyEmails: String
    let clipboardHistoryTodaySection: String
    let clipboardHistoryYesterdaySection: String
    let clipboardHistoryThisWeekSection: String
    let clipboardHistoryEarlierSection: String
    let clipboardHistoryInfoTitle: String
    let clipboardHistoryInfoSource: String
    let clipboardHistoryInfoKind: String
    let clipboardHistoryInfoCharacters: String
    let clipboardHistoryInfoWords: String
    let clipboardHistoryInfoDimensions: String
    let clipboardHistoryInfoSize: String
    let clipboardHistoryInfoPath: String
    let clipboardHistoryInfoCopied: String
    let clipboardHistoryPasteToFormat: String
    let clipboardHistoryActions: String
    let clipboardHistoryRecordsMedia: String
    let clipboardHistoryRecordsMediaCaption: String
    let clipboardHistoryImageBudgetTitle: String
    let clipboardHistoryImageBudgetUnlimited: String
    let clipboardHistoryImageBudgetCaptionFormat: String
    let installMoveTitle: String
    let installMoveMessage: String
    let installMoveMessageReplacing: String
    let installMoveConfirm: String
    let installMoveLater: String
    let installMoveNewerTitle: String
    let installMoveNewerMessageFormat: String
    let installMoveOpenInstalled: String
    let installMoveNotWritableTitle: String
    let installMoveNotWritableMessage: String
    let installMoveFailedTitle: String
    let installMoveFailedMessageFormat: String
    let installMoveChangedMessageFormat: String
    let installMoveOpenFailedTitle: String
    let installMoveOpenFailedMessageFormat: String
    let installMoveStillRunning: String
    let installMoveOK: String
    let groupApp: String
    let featuresInstalledCountFormat: String
    let tabUpdateLog: String
    let tabAdvanced: String
    let advancedCancel: String
    let backupTitle: String
    let backupCaption: String
    let backupExport: String
    let backupImport: String
    let backupExportFailed: String
    let backupImportInvalid: String
    let backupImportConfirmTitle: String
    let backupImportConfirmMessageFormat: String
    let backupImportConfirm: String
    let backupSafetyFailed: String
    let resetPermissionsCaption: String
    let resetPermissionsButton: String
    let resetPermissionsConfirmTitle: String
    let resetPermissionsConfirmMessage: String
    let resetPermissionsConfirm: String
    let resetPermissionsFailed: String
    let settingsSearchPrompt: String
    let settingsSearchNoResultsFormat: String
    let settingsBack: String
    let settingsForward: String
    let settingsShowSidebar: String
    let settingsHideSidebar: String
    let featureLayoutFixName: String
    let featureLayoutFixSummary: String
    let layoutFixEnable: String
    let layoutFixEnableCaption: String
    let layoutFixLimitsCaption: String
    let layoutFixActiveNow: String
    let layoutFixNeedsAccessibility: String
    let layoutFixRestOtherFixerFormat: String
    let layoutFixRestDeveloperBuild: String
    let layoutFixRestUnknownLayout: String
    let layoutFixRestListsMissing: String
    let layoutFixRestListsLoading: String
    let layoutFixExcludedTitle: String
    let layoutFixExcludedNone: String
    let layoutFixExcludedAdd: String
    let layoutFixExcludedRemove: String
    let layoutFixExcludedCaption: String
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
        panelNotInBuild: "Not in this build",
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
        featuresIntro: "Install only the tools you want. A tool asks for its permission when you install it: \(enNames.accessibility) for the keyboard tools, \(enNames.fullDiskAccess) for the cleaner, \(enNames.screenRecording) for screenshot and the recorder.",
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
        featureAirDropSummary: "Zip and compress photos as soon as they arrive by AirDrop.",
        featureCleanerName: "Cleaner",
        featureCleanerSummary: "Find caches, logs, leftovers and backups, and remove what you check.",
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
        quitProtectionAccessibilityCaption: "Protection uses \(enNames.accessibility) to observe only ⌘Q and ⌘W globally.",
        quitProtectionNeedsAccessibility: "Protection is off until FixDock has \(enNames.accessibility).",
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
        cleaningModeNeedsAccessibility: "Cleaning mode needs \(enNames.accessibility) to lock the keyboard.",
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
        snippetsEnable: "Expand snippets while typing",
        snippetsEnableCaption: "Type a trigger anywhere and it becomes its text. Everything stays on this Mac.",
        snippetsSecureNote: "Password fields are left alone. Text with a line break is pasted, and the clipboard is put back right after.",
        snippetsNeedsAccessibility: "Snippets do not expand until FixDock has \(enNames.accessibility).",
        snippetsActiveNow: "Active",
        keyTapSecureInputFormat: "Secure input is on (macOS names %@). While it is on, macOS shows typing to no other app, so this feature does not see keys. It comes back when that app turns it off: close its password or sign-in field, or quit it.",
        keyTapSecureInputExitedFormat: "Secure input is still on, but %@, the app macOS names for it, has quit. If it does not clear, log out and back in.",
        keyTapUnknownApp: "an unknown app",
        keyTapStartFailed: "macOS refused FixDock's keyboard monitor although \(enNames.accessibility) is on. FixDock retries every few seconds. If this stays, remove FixDock in System Settings › Privacy & Security › \(enNames.accessibility) and add it again.",
        feedbackButton: "Send Feedback…",
        feedbackTitle: "Feedback",
        feedbackCaption: "The copy holds your note, app and macOS versions, Mac model, language, which tools are on, and recent keyboard monitor events (secure input, taps that stopped). It has no typed text and no snippet contents. Send delivers exactly this to the FixDock developer's Discord through FixDock's own relay; Copy keeps it on this Mac.",
        feedbackCommentPrompt: "What went wrong?",
        feedbackPreviewLabel: "What will be sent",
        feedbackCopyButton: "Copy",
        feedbackCopied: "Copied",
        feedbackClose: "Close",
        feedbackSectionCaption: "Report a bug or share an idea.",
        feedbackKindBug: "Bug",
        feedbackKindIdea: "Features & Ideas",
        feedbackIdeaPrompt: "What would you like to share?",
        feedbackIncludeTechInfo: "Include technical info (app and macOS versions, Mac model, language)",
        feedbackIdeaNotice: "Send delivers your text to the FixDock developer's Discord through FixDock's own relay. Technical info is added only when the box is checked. Nothing else is collected. Every idea is read, but not every one can be built.",
        feedbackSendButton: "Send",
        feedbackSending: "Sending…",
        feedbackSent: "Sent. Thank you!",
        feedbackSendFailed: "Could not send. Copy it and open an issue on GitHub.",
        snippetsUnreadable: "The saved snippets could not be read, so editing is off to keep them from being overwritten.",
        snippetsAddButton: "Add snippet",
        snippetsNewTitle: "New snippet",
        snippetsEditTitle: "Edit snippet",
        snippetsNameLabel: "Name",
        snippetsNamePlaceholder: "Personal email",
        snippetsTriggerLabel: "Trigger",
        snippetsTriggerPlaceholder: ";email",
        snippetsReplacementLabel: "Text",
        snippetsExpansionLabel: "Expand",
        snippetsExpansionImmediate: "Right away",
        snippetsExpansionDelimiter: "After space, Tab or Return",
        snippetsIgnoreCaseLabel: "Ignore capitalization",
        snippetsVariablesHint: "Variables: {{date}}, {{time}}, {{datetime}}, {{clipboard}}",
        snippetsVariablesCaption: "They become the date, the time and the copied text at the moment of expansion. A format after a colon picks how they look, like {{date:yyyy-MM-dd}}.",
        snippetsEmptyList: "No snippets yet. Add the first one.",
        snippetsDuplicateTrigger: "Another snippet already uses this trigger.",
        snippetsTriggerTooShort: "The trigger needs at least 2 characters.",
        snippetsDeleteButton: "Delete",
        snippetsSaveButton: "Save",
        snippetsCancelButton: "Cancel",
        snippetsCountFormat: "%d snippets",
        featureMediaName: "Media",
        featureMediaSummary: "Compress images and videos by hand.",
        mediaIntro: "Compress images and videos when you choose to. Everything happens on this Mac, and the originals are never changed.",
        mediaImageSection: "Image",
        mediaPresetLabel: "Compression",
        mediaPresetLow: "Low",
        mediaPresetMedium: "Medium",
        mediaPresetHigh: "High",
        mediaPresetLowCaption: "High quality, larger file.",
        mediaPresetMediumCaption: "Balanced quality and file size.",
        mediaPresetHighCaption: "Smaller file, lower quality.",
        mediaOutputLabel: "Output",
        mediaOutputZip: "One zip",
        mediaOutputFiles: "Separate files",
        mediaOutputZipCaption: "A compressed_images_YYYY-MM-DD zip is saved in the first file's folder.",
        mediaZipResultFormat: "%d files in %@ (%@)",
        mediaErrorZip: "The zip could not be made, so nothing was saved.",
        mediaLocalNote: "Local. No network.",
        mediaMoreOptions: "More options in Settings",
        mediaToolImage: "Image",
        mediaToolVideo: "Video",
        mediaVideoSection: "Video",
        mediaSizingLabel: "Shrink by",
        mediaSizingResolution: "Resolution",
        mediaSizingFileSize: "File size",
        mediaVideoLowCaption: "Up to 1080p. High quality, larger file.",
        mediaVideoMediumCaption: "Up to 720p. Balanced quality and file size.",
        mediaVideoHighCaption: "Up to 540p. Smaller file, lower quality.",
        mediaTargetSizeLabel: "Target size",
        mediaMegabytesUnit: "MB",
        mediaTargetSizeCaption: "The video is encoded to fit under this size, lowering the resolution if it has to. MP4, H.264.",
        mediaVideoDropHint: "Drop videos here, or click to choose.",
        mediaVideoPrivacyNote: "Location and other private metadata are left out of the result.",
        mediaFileProgressFormat: "%d%%",
        mediaErrorNoVideo: "This file has no video.",
        mediaErrorTargetTooSmall: "The target size is too small for this video's length.",
        mediaErrorVideoUnsupported: "macOS cannot convert this video.",
        mediaErrorVideoFailed: "The video could not be compressed.",
        airdropEnable: "Zip photos received by AirDrop",
        airdropWatching: "Watching the Downloads folder",
        airdropProcessing: "Compressing a batch…",
        airdropFolderUnavailable: "FixDock cannot read the Downloads folder. Allow it in System Settings › Privacy & Security › Files and Folders.",
        airdropHowTitle: "What happens",
        airdropHowCandidates: "Only photos received by AirDrop. Images saved from a browser or a messenger are never touched.",
        airdropHowBatch: "Photos that arrive together become one batch, 5 seconds after the last one.",
        airdropHowZip: "Each batch becomes compressed_images_YYYY-MM-DD.zip in Downloads, with the photos named 1, 2, 3… in the order they were taken. Format and resolution stay.",
        airdropHowOriginals: "The originals go to the Trash only after the zip is checked. If anything fails, every original stays.",
        airdropHowOthers: "Videos and other files from the same AirDrop stay where they are.",
        airdropHowLocation: "Location (GPS) is removed from the compressed photos. Nothing leaves this Mac.",
        airdropKeptFormat: "%d originals stayed because they changed or could not go to the Trash.",
        airdropOpenDownloads: "Open Downloads",
        airdropNotifyDoneFormat: "%d photos zipped into %@.",
        airdropNotifyFailed: "The batch could not be zipped. The photos were left in Downloads.",
        permissionFullDiskAccess: enNames.fullDiskAccess,
        permissionFullDiskAccessDetail: "The cleaner uses this to read caches, device backups and the Trash. A grant applies after a relaunch.",
        cleanerIntro: "Find caches, logs and other data you can remove. Nothing is removed until you check it and confirm.",
        cleanerPermanentNote: "Removal is permanent and cannot be undone.",
        cleanerNeedsFullDiskAccess: "The cleaner needs \(enNames.fullDiskAccess) before it can scan.",
        cleanerHomeUnusable: "The home folder could not be read safely, so the scan did not start.",
        cleanerScan: "Scan",
        cleanerScanning: "Scanning…",
        cleanerCancel: "Cancel",
        cleanerScanAgain: "Scan again",
        cleanerSafeSection: "Safe cleanup",
        cleanerReviewSection: "Review first",
        cleanerCatCaches: "App caches",
        cleanerCatLogs: "Logs older than 7 days",
        cleanerCatDeveloper: "Xcode build data",
        cleanerCatBrowserCaches: "Browser caches",
        cleanerCatDownloads: "Unfinished downloads",
        cleanerCatLeftovers: "Leftovers of deleted apps",
        cleanerCatLoginItems: "Login items of deleted apps",
        cleanerCatDeviceBackups: "iPhone and iPad backups",
        cleanerCatLargeDeveloper: "Xcode archives and simulators",
        cleanerCatTrash: "Trash",
        cleanerNothingFound: "Nothing to clean.",
        cleanerSelectedFormat: "%d of %d selected · %@",
        cleanerRemoveButtonFormat: "Remove %@",
        cleanerLockedHelp: "In use by a running app. Quit it to clean this.",
        cleanerExceptionHelp: "Never clean this",
        cleanerExceptionRemoveHelp: "Allow cleaning this again",
        cleanerRevealHelp: "Show in Finder",
        cleanerConfirmTitleFormat: "Remove %d items permanently?",
        cleanerConfirmMessageFormat: "%@ will be removed from: %@. This cannot be undone.",
        cleanerConfirmButton: "Remove permanently",
        cleanerBackupConfirmTitle: "Remove these device backups too?",
        cleanerBackupConfirmMessageFormat: "%@\n\nA removed backup cannot be restored. Make sure the device is backed up elsewhere.",
        cleanerRemoving: "Removing…",
        cleanerDoneFormat: "Removed %d items. %@ freed.",
        cleanerNotRemovedFormat: "%d items were not removed:",
        cleanerSkippedLabel: "skipped: changed since the scan or now in use",
        cleanerFailedLabel: "could not be removed",
        cleanerOpenButton: "Open",
        mediaPresetCaption: "PNG is lossless and ignores the level.",
        mediaFormatLabel: "Format",
        mediaFormatOriginal: "Keep original",
        mediaResizeToggle: "Limit the longest edge",
        mediaPixelsFormat: "%d px",
        mediaMetadataLabel: "Metadata",
        mediaMetadataKeep: "Keep all",
        mediaMetadataRemoveLocation: "Remove location (GPS)",
        mediaMetadataRemoveAll: "Remove all",
        mediaDropHint: "Drop images here, or click to choose.",
        mediaOutputCaption: "Each result is saved next to its original as name-compressed.",
        mediaRunningFormat: "Compressing %d of %d",
        mediaCancel: "Cancel",
        mediaCancelled: "Cancelled. Files already saved stay.",
        mediaClearResults: "Clear",
        mediaShowInFinder: "Show",
        mediaResultSizeFormat: "%@ → %@ (%@ smaller)",
        mediaResultGrewFormat: "%@ → %@ (larger in the new format)",
        mediaResultKeptOriginal: "Could not get smaller, so the original image was saved as is.",
        mediaSkippedFormat: "%d files skipped because they are not the chosen kind.",
        mediaErrorUnreadable: "Could not read this image.",
        mediaErrorUnsupported: "macOS cannot save this format.",
        mediaErrorTooLarge: "Too large to process.",
        mediaErrorEncode: "Could not encode the image.",
        mediaErrorLocation: "The location could not be removed, so nothing was saved.",
        mediaErrorWrite: "Could not save next to the original.",
        shortcutTitle: "Open the panel",
        shortcutCaption: "Works without \(enNames.accessibility). The default is Control-Option-Command-F.",
        shortcutRecord: "Record shortcut",
        shortcutRecording: "Press the new shortcut.",
        shortcutEscapeHint: "Escape cancels.",
        shortcutDeleteHint: "Delete restores the default.",
        shortcutFailed: "macOS did not accept this shortcut. Try another combination.",
        permissionsIntro: "The keyboard tools need \(enNames.accessibility): quit and close protection, cleaning mode, text snippets and the fast Korean/English switch. The cleaner needs \(enNames.fullDiskAccess). Screenshot and the screen recorder need \(enNames.screenRecording). Options that need more (the recorder's microphone and system audio) ask when you turn them on.",
        permissionAccessibility: enNames.accessibility,
        permissionAccessibilityDetail: "Quit and close protection uses this to see ⌘Q and ⌘W, cleaning mode to lock the keyboard, text snippets to see triggers and type their text, and the fast Korean/English switch to see its key.",
        permissionScreenRecording: enNames.screenRecording,
        permissionScreenRecordingDetail: "The screenshot tool and the screen recorder need this. A grant applies only after a relaunch.",
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
        guideDragLead: "Check the list, then follow the line that matches.",
        guideCaseMissingTitle: "Not in the list",
        guideCaseMissingAction: "Drag the FixDock icon onto the list.",
        guideCaseOffTitle: "In the list, switched off",
        guideCaseOffAction: "Turn its switch on.",
        guideCaseStuckTitle: "On, but nothing changes",
        guideCaseStuckAction: "If more than one FixDock is listed, each row belongs to a different copy. Start over removes this copy's entry; then drag the icon in.",
        guideDragConfirm: "Confirm with Touch ID or your password in System Settings.",
        onboardingWelcomeTitle: "FixDock",
        onboardingWelcomeBody: "A small set of menu bar tools for people who use a Mac in Korean. Install only the tools you want from Settings › Features; each asks for a permission only when it needs one. Control-Option-Command-F opens the panel. FixDock is a modified unofficial fork of vorssaint-utils. It is not affiliated with the original authors. It is free under GPL-3.0 and sends no analytics. It uses the network only to check GitHub for FixDock updates, which you can turn off in Settings › About, and to send feedback when you press Send.",
        onboardingLanguageTitle: "Language",
        onboardingFeaturesTitle: "Tools",
        onboardingFeaturesBody: "Install the tools you want now, or later in Settings › Features. A tool does nothing until it is installed.",
        onboardingPermissionsTitle: "Permissions",
        onboardingPermissionsBody: "A tool asks for a permission only when you install it or turn on an option that needs one. The keyboard tools need \(enNames.accessibility): quit and close protection watches ⌘Q and ⌘W, cleaning mode blocks keys only while it is on, text snippets look for your triggers, and the fast Korean/English switch watches for its key. The cleaner needs \(enNames.fullDiskAccess) to list caches and logs and removes only what you check. Screenshot and the screen recorder need \(enNames.screenRecording) and read the screen only while you capture or record; the microphone and system audio are used only when you turn them on. Nothing leaves your Mac. For these three, FixDock opens the list in System Settings and shows a card with its icon: drag the icon into the list, or turn its switch on if it is already there.",
        onboardingFinishTitle: "The icon is in the menu bar",
        onboardingFinishBody: "Click it for the panel. Control-Option-Command-F opens it from anywhere. Right-click the icon for Settings and Quit.",
        onboardingContinue: "Continue",
        onboardingBack: "Back",
        onboardingSkip: "Skip",
        onboardingGetStarted: "Get started",
        aboutFork: "FixDock is a modified unofficial fork of vorssaint-utils. The original is GPL-3.0-or-later. Copyright (C) 2026 Vorssaint and the vorssaint-utils contributors. This build removes the original name, icon, signing identity, and update feed, and checks FixDock's own releases for updates. It is not an official release.",
        aboutLicense: "License: GNU General Public License v3.0 or later. See the LICENSE and NOTICE files.",
        aboutNoTelemetry: "No account and no analytics. FixDock uses the network only for the update check below and for feedback you choose to send.",
        aboutUpstreamButton: "Original project",
        aboutRepositoryButton: "FixDock source",
        screenCapturePageTitle: "Screen capture",
        screenshotToolScreenshot: "Screenshot",
        screenshotToolRecording: "Screen recording",
        screenshotRecordingLater: "Screen recording comes in a later update.",
        screenshotFilePrefix: "Screenshot",
        screenshotCaptureFailed: "The capture failed.",
        screenshotFolderUnavailable: "The save folder is missing or read-only, so the capture was not saved as a file.",
        screenshotPanelFullScreen: "Full screen",
        screenshotHint: "Drag for an area · click a window · Return for the whole screen",
        screenshotHintScrolling: "Scrolling capture: drag the area to scroll",
        screenshotKeyRepeat: "Last area",
        screenshotKeyLoupe: "Loupe",
        screenshotKeyLoupeLarge: "Loupe (large)",
        screenshotKeyColor: "Copy colour",
        screenshotKeyScroll: "Scrolling",
        screenshotKeyCancel: "Cancel",
        screenshotNoLastRegion: "No earlier area on this display.",
        screenshotColorNeedsLoupe: "Turn on the loupe (Z) to pick a colour.",
        screenshotColorCopied: "Copied %@",
        screenshotScrollingPrompt: "Scroll the area, then press Done.",
        screenshotScrollingHeight: "%ld px so far",
        screenshotScrollingDone: "Done",
        screenshotScrollingSkipped: "%ld frames did not line up and were skipped. Scroll more slowly.",
        screenshotNeedsPermission: "Screenshots need the \(enNames.screenRecording) permission.",
        screenshotGrantPermission: "Allow \(enNames.screenRecording)…",
        screenshotShortcutsTitle: "Shortcuts",
        screenshotShortcutOverlay: "Capture overlay",
        screenshotShortcutFullScreen: "Full screen at once",
        screenshotAfterTitle: "After a capture",
        screenshotSaveToFile: "Save as a PNG file",
        screenshotFolder: "Folder",
        screenshotChooseFolder: "Choose…",
        screenshotUseDesktop: "Use Desktop",
        screenshotCopyToClipboard: "Copy to the clipboard",
        screenshotNothingHappens: "With both off, a capture goes nowhere.",
        screenshotKeysTitle: "In the overlay",
        screenshotKeyHelpScreenshot: "Screenshot",
        screenshotKeyHelpRecording: "Screen recording",
        screenshotKeyHelpRepeat: "Capture the last area on this display again",
        screenshotKeyHelpLoupe: "Loupe: off, regular, large (Shift goes back); arrow keys move one pixel, Shift ten",
        screenshotKeyHelpColor: "Copy the colour under the loupe in the chosen format",
        screenshotKeyHelpScroll: "Scrolling capture of the next area",
        screenshotKeyHelpFull: "Whole display under the pointer",
        screenshotKeyHelpMove: "Hold while dragging to move the area",
        screenshotWindowLimit: "A window is captured on its own, without its shadow. Sheets and dialogs attached to it are not included.",
        shortcutConflict: "Another FixDock shortcut already uses that combination.",
        screenshotShowPreview: "Pin the capture on screen",
        screenshotPreviewSavesOnly: "Save on the pin writes a file to the folder. \"Save as a PNG file\" also saves every capture as it is taken.",
        screenshotPreviewShare: "Share",
        screenshotPreviewSave: "Save",
        screenshotPreviewCopy: "Copy",
        screenshotPreviewEdit: "Edit",
        screenshotPreviewQR: "Show the QR code's content",
        screenshotPreviewTextCopied: "Text copied",
        screenshotToastCopied: "Copied!",
        screenshotToastSaved: "Saved!",
        screenshotPreviewNoText: "No text found",
        screenshotPreviewDragHint: "Drag into Finder or another app",
        screenshotPreviewPositionTitle: "Preview position",
        screenshotPreviewPositionAutomatic: "Beside the capture",
        screenshotPreviewPositionBottomRight: "Bottom right",
        screenshotPreviewPositionBottomLeft: "Bottom left",
        screenshotPreviewPositionTopRight: "Top right",
        screenshotPreviewPositionTopLeft: "Top left",
        screenshotLoupeTitle: "Loupe",
        screenshotLoupeAtStart: "Turn on the loupe when the overlay opens",
        screenshotOverlayTitle: "Capture overlay",
        screenshotCaptureSounds: "Play sounds when capturing",
        screenshotCaptureSoundsNote: "A beep when a drag starts and a shutter when the capture is taken, at the alert volume and on the sound effects output chosen in Sound settings.",
        screenshotSnapToLines: "Snap the selection to horizontal and vertical lines",
        screenshotColorFormatTitle: "Colour format",
        screenshotColorFormatHex: "HEX",
        screenshotColorFormatHexPlain: "HEX without #",
        screenshotColorFormatRGB: "RGB",
        screenshotColorFormatHSL: "HSL",
        screenshotQRTitle: "QR code",
        screenshotQRCopy: "Copy",
        screenshotQROpen: "Open link",
        screenshotPinSaveAs: "Save As…",
        screenshotPinOpacity: "Opacity",
        screenshotPinClose: "Close",
        screenshotPinCloseAll: "Close all pins",
        screenshotPinExtractText: "Extract Text",
        screenshotPinSettings: "Settings",
        screenshotPinShortcuts: "Keyboard Shortcuts",
        screenshotPinOpenSettings: "Screenshot Settings…",
        screenshotPinHiddenFormat: "%d hidden pins",
        screenshotPinTextTitle: "Text in the capture",
        screenshotPinTextCopyAll: "Copy All",
        screenshotEditorTitle: "Edit capture",
        screenshotEditorToolSelect: "Select",
        screenshotEditorToolArrow: "Arrow",
        screenshotEditorToolText: "Text",
        screenshotEditorToolRect: "Rectangle",
        screenshotEditorToolFreehand: "Pen",
        screenshotEditorToolLine: "Line",
        screenshotEditorToolEllipse: "Ellipse",
        screenshotEditorColor: "Colour",
        screenshotEditorStroke: "Line width",
        screenshotEditorTextSize: "Text size",
        screenshotEditorBringForward: "Bring forward",
        screenshotEditorSendBackward: "Send backward",
        screenshotEditorTextPlaceholder: "Type text",
        screenshotEditorZoomFit: "Fit to window",
        screenshotEditorZoomActual: "Actual size",
        screenshotEditorZoomHint: "Pinch, or scroll with Control held, to zoom",
        screenshotEditorSaveMenu: "Save options",
        screenshotEditorDone: "Done",
        screenshotEditorDiscardTitle: "Discard your edits?",
        screenshotEditorDiscardMessage: "The edited capture has not been saved, copied or kept with Done.",
        screenshotEditorDiscard: "Discard",
        screenshotEditorCancel: "Cancel",
        screenshotEditorToolBlur: "Blur",
        screenshotEditorToolCrop: "Crop",
        screenshotEditorToolSticker: "Sticker",
        screenshotEditorToolHighlight: "Highlighter",
        screenshotEditorToolCounter: "Number",
        screenshotEditorToolRedact: "Solid block",
        screenshotEditorToolSpotlight: "Spotlight",
        screenshotEditorMoreTools: "More tools",
        screenshotEditorArrowStyle: "Arrow style",
        screenshotEditorArrowFilled: "Solid",
        screenshotEditorArrowOutline: "Outline",
        screenshotEditorArrowOpen: "Open",
        screenshotEditorArrowDoubleEnded: "Double-ended",
        screenshotEditorArrowScribbly: "Scribbly",
        screenshotEditorBlurStyle: "Blur style",
        screenshotEditorBlurPixelate: "Pixelate",
        screenshotEditorBlurErase: "Erase",
        screenshotEditorBlurTextOnly: "Text only",
        screenshotEditorBlurStrength: "Blur strength",
        screenshotEditorSpotlightDim: "Dim outside",
        screenshotEditorShadows: "Shadows",
        screenshotEditorCropApply: "Crop",
        screenshotEditorToolExpandCanvas: "Expand canvas",
        screenshotEditorPastedImage: "Pasted image",
        screenshotEditorCanvasFill: "Fill",
        screenshotEditorCanvasFillWhite: "White",
        screenshotEditorCanvasFillClear: "Transparent",
        screenshotEditorCanvasFillCustom: "Custom",
        screenshotEditorCanvasHint: "Drag a handle on the edge to add space",
        screenshotEditorBackdrop: "Backdrop",
        screenshotEditorBackdropNone: "None",
        screenshotEditorBackdropPreset: "Gradient preset",
        screenshotEditorBackdropSaved: "Saved backdrop",
        screenshotEditorBackdropWallpaper: "Current desktop picture",
        screenshotEditorBackdropChooseImage: "Choose an image…",
        screenshotEditorBackdropSolid: "Solid",
        screenshotEditorBackdropGradient: "Gradient",
        screenshotEditorBackdropSave: "Save this backdrop",
        screenshotEditorPresetRemove: "Remove",
        screenshotEditorBackdropPadding: "Margin",
        screenshotEditorBackdropCorners: "Corners",
        screenshotEditorBackdropBlur: "Blur",
        screenshotEditorWatermark: "Watermark",
        screenshotEditorWatermarkText: "Text",
        screenshotEditorWatermarkImage: "Image",
        screenshotEditorWatermarkPlaceholder: "Watermark text",
        screenshotEditorWatermarkSave: "Save this watermark",
        screenshotEditorWatermarkPosition: "Position",
        screenshotEditorWatermarkSize: "Size",
        screenshotEditorWatermarkRotation: "Rotation",
        screenshotEditorAnchorTopLeading: "Top left",
        screenshotEditorAnchorTop: "Top",
        screenshotEditorAnchorTopTrailing: "Top right",
        screenshotEditorAnchorLeading: "Left",
        screenshotEditorAnchorCenter: "Centre",
        screenshotEditorAnchorTrailing: "Right",
        screenshotEditorAnchorBottomLeading: "Bottom left",
        screenshotEditorAnchorBottom: "Bottom",
        screenshotEditorAnchorBottomTrailing: "Bottom right",
        screenshotEditorToolOrder: "Tool order and keys",
        screenshotToolKeysTitle: "Editor tools",
        screenshotToolKeysToggle: "Keys pick tools",
        screenshotToolKeysCaption: "The first nine tools in the editor's rail get keys 1 to 9. Click a tool's key to give it another number, which moves it into that place, or a single key of its own.",
        screenshotToolKeyNone: "No key",
        screenshotToolMoveUp: "Move up",
        screenshotToolMoveDown: "Move down",
        screenshotToolOrderReset: "Reset order",
        screenshotToolKeyPress: "Press a key",
        screenshotToolKeyRecordingHint: "A digit moves the tool into that place; any other key becomes its own. Delete clears, Escape cancels.",
        screenshotToolKeyReserved: "The editor uses this key itself.",
        screenshotToolKeyTaken: "%@ already uses this key.",
        screenshotToolKeyRemove: "Remove its own key",
        // Screen recorder (7.7 A+B): add strings below this line.
        recorderPermissionMicrophone: "Microphone",
        recorderPermissionMicrophoneDetail: "Lets a screen recording include your voice when you turn the microphone on for it.",
        recorderPermissionAudioCapture: "System audio recording",
        recorderPermissionAudioCaptureDetail: "Lets a screen recording include the Mac's sound on macOS 14.4 and later. macOS asks the first time a recording with sound starts; FixDock can only tell it was granted after a recording heard sound.",
        recorderFilePrefix: "Screen Recording",
        recorderRecordFailed: "The screen could not be recorded",
        recorderMicrophoneUnavailable: "Microphone unavailable, recording without it",
        recorderStoppedNoSpace: "Recording stopped, the disk is almost full",
        recorderNoSpaceTitle: "Not enough space to record",
        recorderNoSpaceMessage: "Free up some space on the disk and try again.",
        recorderIndicatorTooltip: "Recording controls",
        recorderPause: "Pause recording",
        recorderResume: "Resume recording",
        recorderStop: "Stop recording",
        recorderSavedFormat: "Saved as %@",
        recorderFolderUnavailable: "The recording was not saved: the save folder is missing or not writable.",
        recorderSaveElsewhereMessage: "The save folder is missing or not writable. Choose where to save the recording.",
        recorderCountdownLabel: "Countdown",
        recorderCountdownOff: "Off",
        recorderCountdownSecondsFormat: "%d s",
        recorderQualityLabel: "Export quality",
        recorderQualitySmall: "Small file",
        recorderQualityBalanced: "Balanced",
        recorderQualityHigh: "High",
        recorderQualityCaption: "Used when the editor exports. The recording itself is always kept at high quality.",
        recorderFrameRateLabel: "Frames per second",
        recorderFrameRateFormat: "%d fps",
        recorderSystemAudioToggle: "Record the sound of the Mac",
        recorderSystemAudioCaption: "Goes into its own track. On macOS 14.4 and later macOS asks for system audio recording the first time.",
        recorderMicrophoneToggle: "Record the microphone",
        recorderMicrophoneCaption: "Your voice goes into its own track.",
        recorderPointerToggle: "Record the pointer and clicks",
        recorderPointerCaption: "Kept beside the recording for the editor to draw. Off: the system pointer is recorded into the movie instead.",
        recorderTypingToggle: "Record when you type",
        recorderTypingCaption: "Only the moments keys were pressed, never which keys. Needs \(enNames.accessibility).",
        recorderStartHint: "Press Control-Option-Command-4, then 2. Drag an area, click a window or press Return for the whole screen.",
        recorderStopHint: "Stop with the indicator at the top of the screen or Control-Option-Command-4.",
        recorderNeedsScreenshot: "Recording starts from the capture overlay, which comes with the Screenshot tool. Install Screenshot in Features to record.",
        recorderFolderFormat: "Saved in the screenshot folder: %@",
        recorderRecordingFormat: "Recording %@",
        recorderSectionStart: "Start",
        recorderSectionCapture: "What is recorded",
        recorderPreviewShowInFinder: "Show in Finder",
        recorderPreviewShare: "Share",
        recorderPreviewEdit: "Edit",
        recorderPreviewClose: "Close",
        recorderPreviewDragHint: "Drag the movie into Finder or another app",
        // These two lines keep the blocks apart so the A+B and C
        // branches merge without touching each other.
        // Screen recorder editor (7.7 C): add strings below this line.
        recorderEditorAddBlurButton: "Blur an area",
        recorderEditorAddImageButton: "Add image",
        recorderEditorAddTextButton: "Add text",
        recorderEditorAddZoomButton: "Add a zoom",
        recorderEditorAudioVolumeLabel: "Volume",
        recorderEditorBackgroundSectionLabel: "Background",
        recorderEditorBackToOptions: "All options",
        recorderEditorBlurCaption: "Hidden for as long as its block lasts on the timeline.",
        recorderEditorBlurLaneEmptyHint: "Click here to add a blur",
        recorderEditorBlurLaneLabel: "Blur",
        recorderEditorBlurPickArea: "Choose the area",
        recorderEditorBlurPickAreaHint: "Drag over what should stay hidden",
        recorderEditorCancelButton: "Cancel",
        recorderEditorClickRingToggle: "Mark where you click",
        recorderEditorCopiedHUD: "Recording copied",
        recorderEditorCopyAndDeleteButton: "Copy and delete",
        recorderEditorCopyButton: "Copy",
        recorderEditorCopyGIFButton: "Copy as GIF",
        recorderEditorCreateAutomaticZooms: "Create automatic zooms",
        recorderEditorCutOutButton: "Cut out",
        recorderEditorDiscardButton: "Delete",
        recorderEditorDiscardMessage: "It has not been saved anywhere yet.",
        recorderEditorDiscardSavedMessage: "Saved and copied files will stay where they are.",
        recorderEditorDiscardTitle: "Delete this recording?",
        recorderEditorEditorTitle: "Recording",
        recorderEditorExportCustom: "Custom speed",
        recorderEditorExportDuration: "Export duration",
        recorderEditorExportFailed: "The recording could not be saved",
        recorderEditorExportingLabel: "Saving…",
        recorderEditorExportPreviewNote: "Applies to video and GIF. The editing preview stays at 1×; the original recording is unchanged.",
        recorderEditorExportSpeed: "Export speed",
        recorderEditorFolderLabel: "Save to",
        recorderEditorImageImportFailed: "Couldn’t add this image.",
        recorderEditorImageLaneEmptyHint: "Click here to add an image",
        recorderEditorImageLaneLabel: "Image",
        recorderEditorImageOpacityLabel: "Opacity",
        recorderEditorImagePositionLabel: "Position",
        recorderEditorImageSizeLabel: "Size",
        recorderEditorLookClean: "Smooth",
        recorderEditorLookLabel: "Look",
        recorderEditorLookRaw: "Original",
        recorderEditorLookStudio: "Studio",
        recorderEditorMicrophoneTrackLabel: "Microphone",
        recorderEditorNoPointerNote: "This recording has no pointer track, so there is nothing to smooth. Zooms placed by hand still work.",
        recorderEditorPointerSectionLabel: "Pointer",
        recorderEditorPointerShowToggle: "Draw the pointer",
        recorderEditorPointerSizeLabel: "Size",
        recorderEditorPointerSmoothingCinematic: "Cinematic",
        recorderEditorPointerSmoothingLabel: "Smoothing",
        recorderEditorPointerSmoothingLight: "Light",
        recorderEditorPointerSmoothingOff: "None",
        recorderEditorPointerSmoothingSmooth: "Smooth",
        recorderEditorPresetNamePlaceholder: "Preset name",
        recorderEditorPresetsButton: "Presets",
        recorderEditorQualityBalanced: "Balanced",
        recorderEditorQualityHigh: "High",
        recorderEditorQualityLabel: "Quality",
        recorderEditorQualitySmall: "Small file",
        recorderEditorRegenerateZooms: "Back to one per click",
        recorderEditorRemoveAudio: "Remove",
        recorderEditorRemovePreset: "Remove preset",
        recorderEditorRemoveText: "Remove",
        recorderEditorRemoveZoom: "Remove",
        recorderEditorRestoreAudio: "Restore",
        recorderEditorSaveAsButton: "Save as…",
        recorderEditorSaveButton: "Save",
        recorderEditorSavedHUDFormat: "Saved to %@",
        recorderEditorSaveGIFButton: "Save as GIF",
        recorderEditorSavePreset: "Save current preset…",
        recorderEditorSaveVideoButton: "Save",
        recorderEditorShapeLabel: "Shape",
        recorderEditorShapeOriginal: "Original",
        recorderEditorShapeSquare: "Square",
        recorderEditorShapeVertical: "Tall",
        recorderEditorShapeWide: "Wide",
        recorderEditorSystemAudioTrackLabel: "Mac sound",
        recorderEditorTextColorLabel: "Colour",
        recorderEditorTextContentLabel: "Text",
        recorderEditorTextLaneEmptyHint: "Click here to add text",
        recorderEditorTextPlaceholder: "Your text here",
        recorderEditorTextPositionLabel: "Position",
        recorderEditorTextSizeLabel: "Size",
        recorderEditorThisBlurLabel: "This blur",
        recorderEditorThisImageLabel: "This image",
        recorderEditorThisTextLabel: "This text",
        recorderEditorThisZoomLabel: "This zoom",
        recorderEditorTypingZoomCaption: "After a click, typing keeps the automatic zoom on that spot.",
        recorderEditorTypingZoomToggle: "Keep zoomed in while typing",
        recorderEditorZoomAmountLabel: "How close",
        recorderEditorZoomEmptyCaption: "Create them from your clicks or add one on the timeline.",
        recorderEditorZoomEmptyTitle: "No zooms yet",
        recorderEditorZoomFollowsPointer: "Follows the pointer",
        recorderEditorZoomLaneEmptyHint: "Click here to add a zoom",
        recorderEditorZoomPickSpot: "Pick a spot",
        recorderEditorZoomPickSpotHint: "Click the picture to aim it",
        recorderEditorZoomSectionLabel: "Zoom",
        recorderEditorZoomToggle: "Zoom in on every click",
        recorderEditorZoomWhereLabel: "Where it looks",
        recorderEditorSettingsSection: "Editor",
        recorderEditorSettingsAutomaticZoomToggle: "Add zooms automatically",
        recorderEditorSettingsAutomaticZoomCaption: "Turn this off to start new recordings without zooms. You can still add them in the editor.",
        recorderEditorSettingsGIFSizeLabel: "GIF size",
        recorderEditorSettingsGIFSizeSmall: "Small",
        recorderEditorSettingsGIFSizeMedium: "Medium",
        recorderEditorSettingsGIFSizeLarge: "Large",
        recorderEditorSettingsGIFFrameRateLabel: "GIF smoothness",
        panelQuickActionsTitle: "Quick actions",
        panelOnOffTitle: "On and off",
        panelEditCard: "Edit this card",
        panelEditDone: "Done",
        panelResetCard: "Reset order and shown rows",
        panelHideItem: "Hide from the panel",
        panelShowItem: "Show in the panel",
        panelHiddenItem: "Hidden",
        panelDragHint: "Drag to reorder",
        panelBack: "Back",
        panelPermissionMissingFormat: "Needs %@",
        updatesTitle: "Updates",
        updateAutomaticToggle: "Check for updates automatically",
        updateShowNotesToggle: "Show release notes before updating",
        updateCheckNow: "Check now",
        updateCheckingStatus: "Checking…",
        updateUpToDateStatus: "You're on the latest version.",
        updateAvailableFormat: "Update available: v%@",
        updateInstallButton: "Download and install",
        updateOpenReleasePage: "Open release page",
        updateDownloadingFormat: "Downloading update… %d%%",
        updateDownloadingStatus: "Downloading update…",
        updateVerifyingStatus: "Checking the download…",
        updateRestartingStatus: "Installing and restarting…",
        updateCheckFailedFormat: "Couldn't check: %@",
        updateInstallFailedFormat: "Couldn't install: %@",
        updateLastCheckedFormat: "Last checked: %@",
        updateInertCaption: "This build doesn't update itself.",
        updateManualTranslocated: "Move FixDock to /Applications to update it here.",
        updateManualOutsideApplications: "FixDock updates itself only in /Applications.",
        updateManualNotWritable: "You can't change this copy. Download the update from the release page.",
        updateManualOtherVolume: "This copy is on another disk. Download the update from the release page.",
        updateBannerTitle: "Update available",
        updateBannerAction: "Update",
        updatePreviewTitleFormat: "FixDock v%@ is available",
        updatePreviewCurrentFormat: "You have v%@.",
        updatePreviewSkipNotes: "Don't show release notes before updating",
        updatePreviewCancel: "Cancel",
        menuCheckForUpdates: "Check for Updates…",
        updateUpdatedNoticeFormat: "Updated to v%@.",
        updateRolledBackNoticeFormat: "v%1$@ didn't start, so v%2$@ was kept.",
        updateNotAppliedNoticeFormat: "The update to v%@ wasn't applied.",
        updateRestoreFailedNotice: "The update failed and the previous copy couldn't be put back. Download FixDock from the release page.",
        updateFailureUnreachable: "GitHub can't be reached.",
        updateFailureRateLimited: "GitHub asked to wait. Try again later.",
        updateFailureServer: "GitHub answered with an error.",
        updateFailureUnreadable: "The release information couldn't be read.",
        updateFailureReleaseIncomplete: "The newest release isn't complete yet.",
        updateFailureBusyRecording: "Finish the recording first.",
        updateFailureBusyMedia: "Wait for the media job to finish.",
        updateFailureBusyCleaning: "Turn off cleaning mode first.",
        updateFailureDownload: "The download didn't finish.",
        updateFailureDigest: "The download doesn't match the release.",
        updateFailureArchive: "The download isn't the FixDock release that was offered.",
        updateFailureSignature: "The new version isn't signed by FixDock's developer and notarized by Apple.",
        updateFailureDisk: "The download couldn't be saved.",
        updateFailureHandoff: "The installer couldn't start.",
        featureInputSwitchName: "Fast Korean/English switch",
        featureInputSwitchSummary: "Switch input source the moment you press the key, without a wrong first letter.",
        inputSwitchIntro: "The chosen key switches to your previous input source as soon as you press it, not when you let go. Adapted from gksdud.",
        inputSwitchEnabledLabel: "Use fast switch",
        inputSwitchKeyLabel: "Switch key",
        inputSwitchKeyCapsLock: "Caps Lock ⇪",
        inputSwitchKeyRightCommand: "Right Command ⌘",
        inputSwitchKeyRightOption: "Right Option ⌥",
        inputSwitchKeyRightControl: "Right Control ⌃",
        inputSwitchCapsLockWarning: "While this is on, Caps Lock no longer locks capitals. Type capitals with Shift.",
        inputSwitchShortcutCaption: "While this is on, the key sends an F-key and macOS's \"Select the previous input source\" shortcut is set to that F-key. Turning it off, quitting or uninstalling FixDock puts both back.",
        inputSwitchNeedsAccessibility: "Allow \(enNames.accessibility) so FixDock can switch on press.",
        inputSwitchActiveNow: "Switching on press",
        inputSwitchStatusLiveFormat: "On: %@ switches through %@.",
        inputSwitchStatusPreparing: "Getting ready…",
        inputSwitchStatusAway: "Paused while the screen is locked or another user is active.",
        inputSwitchStatusRestoring: "Putting your keyboard settings back…",
        inputSwitchStatusDeveloperInert: "The Developer build leaves this to the installed FixDock.",
        inputSwitchStatusOwnedByFormat: "%@ is using the switch right now.",
        inputSwitchStatusJournalUnreadable: "FixDock can't read its record of what it changed, so it changes nothing.",
        inputSwitchProblemNoFreeFunctionKey: "No free key among F13–F19: other shortcuts use them all.",
        inputSwitchProblemHotkeyFailed: "Couldn't change the input source shortcut. FixDock will try again.",
        inputSwitchProblemActivationFailed: "macOS hasn't applied the shortcut change yet. FixDock will try again.",
        inputSwitchProblemHotkeyChanged: "\"Select the previous input source\" was changed in System Settings, so FixDock stopped. Turn the switch off and on to use it again.",
        inputSwitchProblemKeyboardsPendingFormat: "%d keyboard(s) not set yet. FixDock will try again.",
        inputSwitchProblemOtherSwitcherFormat: "%@ is running. Quit it to use FixDock's switch.",
        inputSwitchRestoredToDefault: "The original shortcut was unknown, so it was set back to macOS's default, Control-Space.",
        inputSwitchLongPressLabel: "Hold for Caps Lock",
        inputSwitchLongPressCaption: "Hold the switch key for half a second to switch to English and turn Caps Lock on or off. A short press still just switches.",
        featureClipboardHistoryName: "Clipboard history",
        featureClipboardHistorySummary: "Press ⇧⌘V to find something you copied earlier and paste it again.",
        clipboardHistoryEnable: "Record clipboard history",
        clipboardHistoryEnableCaption: "What you copy is kept on this Mac only. Copies an app marks as secret or temporary are never saved. While the URL cleaner is on, links are saved cleaned.",
        clipboardHistoryShortcut: "Open clipboard history",
        clipboardHistoryShortcutCaption: "While this is on, the shortcut opens the history in every app, so ⇧⌘V no longer pastes and matches style.",
        clipboardHistoryAccessibilityGranted: "Return pastes into the app you were using.",
        clipboardHistoryAccessibilityMissing: "Without \(enNames.accessibility), Return only copies. Allow it so FixDock can paste for you.",
        clipboardHistoryRetentionTitle: "Keep items for",
        clipboardHistoryRetentionOneDay: "1 day",
        clipboardHistoryRetentionDaysFormat: "%d days",
        clipboardHistoryRetentionForever: "Forever",
        clipboardHistoryRetentionCaption: "Pinned items are always kept. Up to 1,000 other items are kept, oldest removed first.",
        clipboardHistoryExcludedTitle: "Apps to skip",
        clipboardHistoryExcludedCaption: "Nothing you copy while one of these apps is in front is saved to the history.",
        clipboardHistoryExcludedNone: "No apps yet.",
        clipboardHistoryExcludedAdd: "Add an app…",
        clipboardHistoryExcludedRemove: "Remove",
        clipboardHistoryClearUnpinned: "Clear Unpinned Items…",
        clipboardHistoryClearConfirmFormat: "Remove %d unpinned items? Pinned items stay.",
        clipboardHistoryClearConfirm: "Clear",
        clipboardHistoryStoreProblemTitle: "The saved history can't be used, so nothing is recorded. FixDock will not change the file.",
        clipboardHistoryProblemNoContainer: "FixDock has no Application Support folder to keep the history in.",
        clipboardHistoryProblemUnreadableFormat: "The history file can't be read: %@",
        clipboardHistoryProblemNotAFile: "Something other than a plain file is where the history file belongs.",
        clipboardHistoryProblemTooLarge: "The history file is larger than FixDock reads.",
        clipboardHistoryProblemNewerFormat: "A newer version of FixDock wrote the history file.",
        clipboardHistoryProblemDamaged: "The history file is damaged.",
        clipboardHistoryProblemImagesWithoutHistory: "Saved history images are there, but the history file is missing.",
        clipboardHistoryProblemImageFolderNotAFolder: "Something other than a plain folder is where the history's image folder belongs.",
        clipboardHistoryRevealFile: "Show in Finder",
        clipboardHistorySearchPlaceholder: "Search",
        clipboardHistoryEmpty: "Nothing copied yet",
        clipboardHistoryNoMatches: "No matches",
        clipboardHistoryPinnedSection: "Pinned",
        clipboardHistoryPaste: "Paste",
        clipboardHistoryCopy: "Copy",
        clipboardHistorySwapLayout: "Paste with Korean/English Keys Swapped",
        clipboardHistoryPin: "Pin",
        clipboardHistoryUnpin: "Unpin",
        clipboardHistoryDelete: "Delete",
        clipboardHistoryToastCopied: "Copied",
        clipboardHistoryToastNeedsAccessibility: "Copied. FixDock needs \(enNames.accessibility) to paste for you.",
        clipboardHistoryToastUnavailable: "No longer available",
        clipboardHistoryAllTypes: "All types",
        clipboardHistoryKindImage: "Image",
        clipboardHistoryKindText: "Text",
        clipboardHistoryKindLink: "Link",
        clipboardHistoryKindColor: "Color",
        clipboardHistoryKindFile: "File",
        clipboardHistoryKindEmail: "Email",
        clipboardHistoryEmptyImages: "No images in history",
        clipboardHistoryEmptyText: "No text in history",
        clipboardHistoryEmptyLinks: "No links in history",
        clipboardHistoryEmptyColors: "No colors in history",
        clipboardHistoryEmptyFiles: "No files in history",
        clipboardHistoryEmptyEmails: "No email addresses in history",
        clipboardHistoryTodaySection: "Today",
        clipboardHistoryYesterdaySection: "Yesterday",
        clipboardHistoryThisWeekSection: "This week",
        clipboardHistoryEarlierSection: "Earlier",
        clipboardHistoryInfoTitle: "Info",
        clipboardHistoryInfoSource: "Source",
        clipboardHistoryInfoKind: "Kind",
        clipboardHistoryInfoCharacters: "Characters",
        clipboardHistoryInfoWords: "Words",
        clipboardHistoryInfoDimensions: "Dimensions",
        clipboardHistoryInfoSize: "Size",
        clipboardHistoryInfoPath: "Path",
        clipboardHistoryInfoCopied: "Copied",
        clipboardHistoryPasteToFormat: "Paste to %@",
        clipboardHistoryActions: "Actions",
        clipboardHistoryRecordsMedia: "Record images and files",
        clipboardHistoryRecordsMediaCaption: "Copied images are saved on this Mac beside the history. Copied files are saved by their location only.",
        clipboardHistoryImageBudgetTitle: "Space for images",
        clipboardHistoryImageBudgetUnlimited: "Unlimited",
        clipboardHistoryImageBudgetCaptionFormat: "Pinned images are always kept. Past this, the oldest unpinned images are removed first. Unpinned images now use %@.",
        installMoveTitle: "Move FixDock to Applications?",
        installMoveMessage: "FixDock is running from the disk image. In the Applications folder it updates itself and can open at login.",
        installMoveMessageReplacing: "FixDock is running from the disk image. The copy already in the Applications folder is moved to the Trash and replaced with this one, which then updates itself and can open at login.",
        installMoveConfirm: "Move to Applications",
        installMoveLater: "Not Now",
        installMoveNewerTitle: "A newer FixDock is installed",
        installMoveNewerMessageFormat: "The Applications folder already has FixDock %@. Open that copy instead?",
        installMoveOpenInstalled: "Open Installed Copy",
        installMoveNotWritableTitle: "FixDock can't write to Applications",
        installMoveNotWritableMessage: "This account can't add apps to the Applications folder. Drag FixDock onto the Applications folder in the disk image window and enter an administrator's name and password, or ask your administrator.",
        installMoveFailedTitle: "FixDock couldn't be moved",
        installMoveFailedMessageFormat: "Nothing in the Applications folder was lost. Drag FixDock onto the Applications folder in the disk image window instead. (%@)",
        installMoveChangedMessageFormat: "The Applications folder may have changed. If FixDock was there before, that copy is in the Trash. Put it back from there, or drag FixDock onto the Applications folder in the disk image window. (%@)",
        installMoveOpenFailedTitle: "FixDock couldn't be opened",
        installMoveOpenFailedMessageFormat: "FixDock is in the Applications folder but didn't open. Open it from there. (%@)",
        installMoveStillRunning: "the installed FixDock did not quit",
        installMoveOK: "OK",
        groupApp: "App",
        featuresInstalledCountFormat: "Installed tools %d / %d",
        tabUpdateLog: "Update log",
        tabAdvanced: "Advanced",
        advancedCancel: "Cancel",
        backupTitle: "Settings backup",
        backupCaption: "Save FixDock's settings to a file, or bring them back from one: installed tools, each tool's options, snippets and shortcuts. Window positions, update checks and this Mac's permissions stay out.",
        backupExport: "Export…",
        backupImport: "Import…",
        backupExportFailed: "The settings file could not be saved.",
        backupImportInvalid: "This file is not a FixDock settings backup, or a newer FixDock made it. Nothing was changed.",
        backupImportConfirmTitle: "Import settings from this file?",
        backupImportConfirmMessageFormat: "The settings in the file overwrite the current ones, and FixDock relaunches. The current settings are saved first in %@.",
        backupImportConfirm: "Import and Relaunch",
        backupSafetyFailed: "The current settings could not be saved first, so nothing was imported.",
        resetPermissionsCaption: "Reset every permission macOS has given FixDock, for example after a grant stopped working. Each tool asks again when it needs one.",
        resetPermissionsButton: "Remove All Permissions…",
        resetPermissionsConfirmTitle: "Remove all of FixDock's permissions?",
        resetPermissionsConfirmMessage: "FixDock's \(enNames.accessibility), \(enNames.screenRecording), \(enNames.fullDiskAccess), Microphone and system audio recording grants are reset, and FixDock relaunches. Tools that need them stop working until you allow them again.",
        resetPermissionsConfirm: "Remove and Relaunch",
        resetPermissionsFailed: "FixDock's permissions could not be reset.",
        settingsSearchPrompt: "Search Settings",
        settingsSearchNoResultsFormat: "No Results for “%@”",
        settingsBack: "Back",
        settingsForward: "Forward",
        settingsShowSidebar: "Show Sidebar",
        settingsHideSidebar: "Hide Sidebar",
        featureLayoutFixName: "Korean/English auto-fix",
        featureLayoutFixSummary: "A word typed on the wrong layout is retyped in the right one when you finish it.",
        layoutFixEnable: "Fix words typed on the wrong layout",
        layoutFixEnableCaption: "When you press Space, Tab or Return after a word that only makes sense on the other layout, FixDock erases it and types it in that layout. Keys are judged in memory on this Mac; nothing you type is stored or sent.",
        layoutFixLimitsCaption: "Left as typed: words with digits, addresses, all-capital words, and a word you moved into with the arrow keys or edited after a shortcut. The input source itself is not switched.",
        layoutFixActiveNow: "Active",
        layoutFixNeedsAccessibility: "Accessibility permission is needed to see what you type.",
        layoutFixRestOtherFixerFormat: "Resting while %@ is running.",
        layoutFixRestDeveloperBuild: "Off in the developer build, so two FixDock copies never fix the same word.",
        layoutFixRestUnknownLayout: "Resting: the current input source is neither ABC nor Korean 2-Set.",
        layoutFixRestListsMissing: "Off: the word lists are missing from this copy of FixDock.",
        layoutFixRestListsLoading: "Loading the word lists…",
        layoutFixExcludedTitle: "Excluded apps",
        layoutFixExcludedNone: "No app is excluded.",
        layoutFixExcludedAdd: "Add app",
        layoutFixExcludedRemove: "Remove",
        layoutFixExcludedCaption: "Nothing is fixed while one of these apps is in front.",
        versionFormat: "Version %@"
    )
}
