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
    /// Standardized paths the cleaner never removes.
    static let cleanerExceptions = "cleanerExceptions"
    static let mediaImageFormat = "mediaImageFormat"
    static let mediaImageMaxDimension = "mediaImageMaxDimension"
    static let mediaImageMetadata = "mediaImageMetadata"
    static let screenshotOverlayShortcut = "screenshotOverlayShortcut"
    static let screenshotOverlayShortcutEnabled = "screenshotOverlayShortcutEnabled"
    static let screenshotFullScreenShortcut = "screenshotFullScreenShortcut"
    static let screenshotFullScreenShortcutEnabled = "screenshotFullScreenShortcutEnabled"
    /// Folder path for saved captures; empty means the Desktop.
    static let screenshotSaveFolder = "screenshotSaveFolder"
    static let screenshotSaveToFile = "screenshotSaveToFile"
    static let screenshotCopyToClipboard = "screenshotCopyToClipboard"
    /// After a capture, a preview offers Save; the file is written only then.
    static let screenshotShowPreview = "screenshotShowPreview"
    /// Seconds before an untouched preview closes; 0 keeps it open.
    static let screenshotPreviewCloseSeconds = "screenshotPreviewCloseSeconds"
    static let screenshotPreviewPosition = "screenshotPreviewPosition"
    /// Last region per display, `[displayID: "x,y,w,h"]` in display points.
    static let screenshotLastRegions = "screenshotLastRegions"
    /// The editor's rail order (comma-separated tool ids), each tool's own
    /// key (`tool=<shortcut>` pairs) and whether keys pick tools at all.
    static let screenshotToolOrder = "screenshotToolOrder"
    static let screenshotToolShortcuts = "screenshotToolShortcuts"
    static let screenshotToolShortcutsEnabled = "screenshotToolShortcutsEnabled"
    /// The editor's backdrop and watermark in use, and the saved presets of
    /// each, as JSON. Picked pictures are stored as paths only.
    static let screenshotBackdropStyle = "screenshotBackdropStyle"
    static let screenshotBackdropPresets = "screenshotBackdropPresets"
    static let screenshotWatermarkStyle = "screenshotWatermarkStyle"
    static let screenshotWatermarkPresets = "screenshotWatermarkPresets"
    /// The editor's last tool, colour, line width and text size, so the next
    /// capture opens with them. Read through the sanitizers.
    static let screenshotEditorTool = "screenshotEditorTool"
    static let screenshotEditorColor = "screenshotEditorColor"
    static let screenshotEditorStroke = "screenshotEditorStroke"
    static let screenshotEditorTextSize = "screenshotEditorTextSize"
    /// The blur area's last level, style and text only choice, the
    /// spotlight dim, arrow style, sticker and annotation shadows. Level and
    /// dim are registered below, because 0 from double(forKey:) is a valid
    /// dim and would hide the 0.5 default.
    static let screenshotEditorBlurLevel = "screenshotEditorBlurLevel"
    static let screenshotEditorBlurStyle = "screenshotEditorBlurStyle"
    static let screenshotEditorBlurTextOnly = "screenshotEditorBlurTextOnly"
    static let screenshotEditorSpotlightDim = "screenshotEditorSpotlightDim"
    static let screenshotEditorArrowStyle = "screenshotEditorArrowStyle"
    static let screenshotEditorSticker = "screenshotEditorSticker"
    static let screenshotEditorAnnotationShadows = "screenshotEditorAnnotationShadows"

    // Screen recorder (7.7 A+B). Names as upstream where upstream had them.
    static let recorderCountdown = "recorderCountdown"
    /// The editor's export quality; the take master is always `.high`.
    static let recorderQuality = "recorderQuality"
    static let recorderFrameRate = "recorderFrameRate"
    static let recorderSystemAudio = "recorderSystemAudio"
    static let recorderMicrophone = "recorderMicrophone"
    /// Set once the process tap has heard sound through a whole recording,
    /// so the tap's sound is written instead of the stream's.
    static let recorderSystemAudioTapVerified = "recorderSystemAudioTapVerified"
    static let recorderPointerTrack = "recorderPointerTrack"
    static let recorderTypingTrack = "recorderTypingTrack"

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
            DefaultsKey.screenshotOverlayShortcutEnabled: true,
            DefaultsKey.screenshotFullScreenShortcutEnabled: true,
            DefaultsKey.screenshotSaveToFile: true,
            DefaultsKey.screenshotCopyToClipboard: true,
            DefaultsKey.screenshotShowPreview: true,
            DefaultsKey.screenshotPreviewCloseSeconds: 0,
            DefaultsKey.screenshotPreviewPosition: ScreenshotSupport.PreviewPosition.bottomRight.rawValue,
            DefaultsKey.screenshotEditorBlurLevel: ScreenshotSupport.BlurStrength.defaultLevel,
            DefaultsKey.screenshotEditorSpotlightDim: Double(ScreenshotSupport.defaultSpotlightDim),
            // The editor reads these through UserDefaults as well as @AppStorage.
            DefaultsKey.screenshotToolOrder: ScreenshotSupport.Tool.defaultOrderStorage,
            DefaultsKey.screenshotToolShortcutsEnabled: true,
            DefaultsKey.screenshotToolShortcuts: "",
            DefaultsKey.screenshotBackdropStyle: "",
            DefaultsKey.screenshotBackdropPresets: "[]",
            DefaultsKey.screenshotWatermarkStyle: "",
            DefaultsKey.screenshotWatermarkPresets: "[]",
            // Screen recorder (7.7 A+B).
            DefaultsKey.recorderCountdown: ScreenRecorderSupport.defaultCountdown,
            DefaultsKey.recorderQuality: RecorderSupport.Quality.balanced.rawValue,
            DefaultsKey.recorderFrameRate: 60,
            DefaultsKey.recorderSystemAudio: true,
            DefaultsKey.recorderMicrophone: false,
            DefaultsKey.recorderPointerTrack: true,
            DefaultsKey.recorderTypingTrack: false,
        ])
    }
}
