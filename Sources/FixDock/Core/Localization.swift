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
    let snippetsEnable: String
    let snippetsEnableCaption: String
    let snippetsSecureNote: String
    let snippetsNeedsAccessibility: String
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
    let mediaMegabytesFormat: String
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
    let mediaOpenButton: String
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
    let screenCapturePageTitle: String
    let screenshotToolScreenshot: String
    let screenshotToolRecording: String
    let screenshotRecordingLater: String
    let screenshotFilePrefix: String
    let screenshotCaptureFailed: String
    let screenshotFolderUnavailable: String
    let screenshotSavedAs: String
    let screenshotCopied: String
    let screenshotPanelSelect: String
    let screenshotPanelFullScreen: String
    let screenshotHint: String
    let screenshotHintScrolling: String
    let screenshotKeyRepeat: String
    let screenshotKeyLoupe: String
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
    let screenshotPreviewClose: String
    let screenshotPreviewShare: String
    let screenshotPreviewDiscard: String
    let screenshotPreviewSave: String
    let screenshotPreviewCopy: String
    let screenshotPreviewEdit: String
    let screenshotPreviewPin: String
    let screenshotPreviewQR: String
    let screenshotPreviewCopyText: String
    let screenshotPreviewTextCopied: String
    let screenshotPreviewNoText: String
    let screenshotPreviewDragHint: String
    let screenshotPreviewPositionTitle: String
    let screenshotPreviewPositionAutomatic: String
    let screenshotPreviewPositionBottomRight: String
    let screenshotPreviewPositionBottomLeft: String
    let screenshotPreviewPositionTopRight: String
    let screenshotPreviewPositionTopLeft: String
    let screenshotPreviewCloseTitle: String
    let screenshotPreviewCloseNever: String
    let screenshotPreviewCloseAfter: String
    let screenshotPreviewCloseWarning: String
    let screenshotQRTitle: String
    let screenshotQRCopy: String
    let screenshotQROpen: String
    let screenshotPinSaveAs: String
    let screenshotPinOpacity: String
    let screenshotPinClickThrough: String
    let screenshotPinClose: String
    let screenshotPinCloseAll: String
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
        snippetsEnable: "Expand snippets while typing",
        snippetsEnableCaption: "Type a trigger anywhere and it becomes its text. Everything stays on this Mac.",
        snippetsSecureNote: "Password fields are left alone. Text with a line break is pasted, and the clipboard is put back right after.",
        snippetsNeedsAccessibility: "Snippets do not expand until FixDock has Accessibility.",
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
        mediaMegabytesFormat: "%d MB",
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
        permissionFullDiskAccess: "Full Disk Access",
        permissionFullDiskAccessDetail: "The cleaner uses this to read caches, device backups and the Trash. A grant applies after a relaunch.",
        cleanerIntro: "Find caches, logs and other data you can remove. Nothing is removed until you check it and confirm.",
        cleanerPermanentNote: "Removal is permanent and cannot be undone.",
        cleanerNeedsFullDiskAccess: "The cleaner needs Full Disk Access before it can scan.",
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
        mediaOpenButton: "Open",
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
        shortcutCaption: "Works without Accessibility. The default is Control-Option-Command-F.",
        shortcutRecord: "Record shortcut",
        shortcutRecording: "Press the new shortcut.",
        shortcutEscapeHint: "Escape cancels.",
        shortcutDeleteHint: "Delete restores the default.",
        shortcutFailed: "macOS did not accept this shortcut. Try another combination.",
        permissionsIntro: "The keyboard tools need Accessibility: quit and close protection, cleaning mode and text snippets. The cleaner needs Full Disk Access. Screenshots need Screen Recording. Nothing else in this build needs a permission.",
        permissionAccessibility: "Accessibility",
        permissionAccessibilityDetail: "Quit and close protection uses this to see ⌘Q and ⌘W, cleaning mode to lock the keyboard, and text snippets to see triggers and type their text.",
        permissionScreenRecording: "Screen Recording",
        permissionScreenRecordingDetail: "The screenshot tool needs this. A grant applies only after a relaunch.",
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
        onboardingPermissionsBody: "Only the keyboard tools touch the keyboard: quit and close protection watches ⌘Q and ⌘W, cleaning mode blocks keys only while it is on, and text snippets look for your triggers. Nothing reads the screen or your files. When a tool needs a permission, FixDock asks then and shows a small guide beside System Settings.",
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
        screenCapturePageTitle: "Screen capture",
        screenshotToolScreenshot: "Screenshot",
        screenshotToolRecording: "Screen recording",
        screenshotRecordingLater: "Screen recording comes in a later update.",
        screenshotFilePrefix: "Screenshot",
        screenshotCaptureFailed: "The capture failed.",
        screenshotFolderUnavailable: "The save folder is missing or read-only, so the capture was not saved as a file.",
        screenshotSavedAs: "Saved %@",
        screenshotCopied: "Copied to the clipboard",
        screenshotPanelSelect: "Select…",
        screenshotPanelFullScreen: "Full screen",
        screenshotHint: "Drag for an area · click a window · Return for the whole screen",
        screenshotHintScrolling: "Scrolling capture: drag the area to scroll",
        screenshotKeyRepeat: "Last area",
        screenshotKeyLoupe: "Loupe",
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
        screenshotNeedsPermission: "Screenshots need the Screen Recording permission.",
        screenshotGrantPermission: "Allow Screen Recording…",
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
        screenshotKeyHelpLoupe: "Loupe; arrow keys move one pixel, Shift ten",
        screenshotKeyHelpColor: "Copy the colour under the loupe as hex",
        screenshotKeyHelpScroll: "Scrolling capture of the next area",
        screenshotKeyHelpFull: "Whole display under the pointer",
        screenshotKeyHelpMove: "Hold while dragging to move the area",
        screenshotWindowLimit: "A window is captured on its own, without its shadow. Sheets and dialogs attached to it are not included.",
        shortcutConflict: "Another FixDock shortcut already uses that combination.",
        screenshotShowPreview: "Show a preview after a capture",
        screenshotPreviewSavesOnly: "The copy is automatic. A file is saved only when you press Save in the preview; closing it saves nothing.",
        screenshotPreviewClose: "Close without saving",
        screenshotPreviewShare: "Share",
        screenshotPreviewDiscard: "Discard",
        screenshotPreviewSave: "Save",
        screenshotPreviewCopy: "Copy",
        screenshotPreviewEdit: "Edit",
        screenshotPreviewPin: "Pin above other windows",
        screenshotPreviewQR: "Show the QR code's content",
        screenshotPreviewCopyText: "Copy the text in the capture",
        screenshotPreviewTextCopied: "Text copied",
        screenshotPreviewNoText: "No text found",
        screenshotPreviewDragHint: "Drag into Finder or another app",
        screenshotPreviewPositionTitle: "Preview position",
        screenshotPreviewPositionAutomatic: "Beside the capture",
        screenshotPreviewPositionBottomRight: "Bottom right",
        screenshotPreviewPositionBottomLeft: "Bottom left",
        screenshotPreviewPositionTopRight: "Top right",
        screenshotPreviewPositionTopLeft: "Top left",
        screenshotPreviewCloseTitle: "Close the preview",
        screenshotPreviewCloseNever: "Never",
        screenshotPreviewCloseAfter: "After %ld seconds",
        screenshotPreviewCloseWarning: "A preview that closes by itself saves no file; the capture stays only on the clipboard. Hovering over it keeps it open.",
        screenshotQRTitle: "QR code",
        screenshotQRCopy: "Copy",
        screenshotQROpen: "Open link",
        screenshotPinSaveAs: "Save As…",
        screenshotPinOpacity: "Opacity",
        screenshotPinClickThrough: "Click through (Option-click to undo)",
        screenshotPinClose: "Close",
        screenshotPinCloseAll: "Close all pins",
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
        screenshotEditorDiscardTitle: "Discard your edits?",
        screenshotEditorDiscardMessage: "The edited capture has not been saved, copied or pinned.",
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
        recorderTypingCaption: "Only the moments keys were pressed, never which keys. Needs Accessibility.",
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
        versionFormat: "Version %@"
    )
}
