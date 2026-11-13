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
    /// Menu bar panel layout: each card's row order (comma-joined tool ids)
    /// and the rows hidden from the panel (one set for both cards).
    static let panelQuickActionsOrder = "panelQuickActionsOrder"
    static let panelOnOffOrder = "panelOnOffOrder"
    static let panelHiddenRows = "panelHiddenRows"
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
    /// Fast Korean/English switch: the main switch and the key (`SwitchKey` raw value).
    static let inputSwitchEnabled = "inputSwitchEnabled"
    static let inputSwitchKey = "inputSwitchKey"
    /// Holding the key 0.5 s ends in English with Caps Lock flipped (on by default).
    static let inputSwitchLongPressCapsLock = "inputSwitchLongPressCapsLock"
    /// Developer runs only (argument domain): let the developer build own
    /// the HID mapping and id 60. Without it that build is inert for the tool.
    static let inputSwitchDeveloperClaim = "inputSwitchDeveloperClaim"
    /// Developer runs only (argument domain): name the permissions as macOS
    /// did before the System Settings rename, to read both eras on one Mac.
    static let permissionListNamesLegacy = "permissionListNamesLegacy"
    /// Clipboard history (upstream names). The main switch stays
    /// unregistered so enableOnFirstInstall can tell a first install from Off.
    static let layoutFixEnabled = "layoutFixEnabled"
    static let layoutFixIgnoredApps = "layoutFixIgnoredApps"
    /// Argument domain only: lets a developer build run the layout fix
    /// beside the installed app, which would otherwise fix a word twice.
    static let layoutFixDeveloperClaim = "layoutFixDeveloperClaim"
    static let clipboardHistoryEnabled = "clipboardHistoryEnabled"
    static let clipboardHistoryShortcut = "clipboardHistoryShortcut"
    static let clipboardHistoryShortcutEnabled = "clipboardHistoryShortcutEnabled"
    /// Days, 0 for forever (`ClipboardHistoryRetention`).
    static let clipboardHistoryRetentionDays = "clipboardHistoryRetentionDays"
    static let clipboardHistoryIgnoredApps = "clipboardHistoryIgnoredApps"
    static let clipboardHistoryImageBudgetMB = "clipboardHistoryImageBudgetMB"
    static let clipboardHistoryRecordsMedia = "clipboardHistoryRecordsMedia"
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
    /// Auto-save: every capture written to the folder as it is taken. Off,
    /// a file is written only from the pin's Save.
    static let screenshotSaveToFile = "screenshotSaveToFile"
    static let screenshotCopyToClipboard = "screenshotCopyToClipboard"
    /// "Pin the capture on screen". The legacy key name is kept so no
    /// defaults migration is needed.
    static let screenshotShowPreview = "screenshotShowPreview"
    /// The recorder preview's corner.
    static let screenshotPreviewPosition = "screenshotPreviewPosition"
    /// `ScreenshotSupport.ColorFormat` raw value for the overlay loupe and C.
    static let screenshotColorFormat = "screenshotColorFormat"
    /// Whether each overlay session starts with the regular loupe on.
    static let screenshotLoupeAtStart = "screenshotLoupeAtStart"
    /// Focus beep when a drag starts and shutter when a capture is taken.
    static let screenshotCaptureSounds = "screenshotCaptureSounds"
    /// Selection corners snap to nearby horizontal and vertical lines.
    static let screenshotSnapToLines = "screenshotSnapToLines"
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

    // Screen recorder editor (7.7 C). Names as upstream.
    static let recorderAutomaticZoom = "recorderAutomaticZoom"
    static let recorderGIFSize = "recorderGIFSize"
    static let recorderGIFFrameRate = "recorderGIFFrameRate"
    static let recorderEditorPresets = "recorderEditorPresets"

    // Self-update. The last two stay unregistered: absent means never.
    static let updateAutomaticChecks = "updateAutomaticChecks"
    static let updateShowNotesBeforeInstall = "updateShowNotesBeforeInstall"
    static let updateLastCheckedAt = "updateLastCheckedAt"
    /// "X.Y.Z" that failed to start here; banner and dot stay off for it.
    static let updateQuietVersion = "updateQuietVersion"

    static func featureAvailable(_ id: String) -> String { "featureAvailable.\(id)" }
}

enum Defaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            DefaultsKey.onboardingComplete: false,
            DefaultsKey.launchAtLoginWanted: false,
            // Empty: the default order, nothing hidden. Read through
            // PanelLayout, which sanitizes whatever is stored.
            DefaultsKey.panelQuickActionsOrder: "",
            DefaultsKey.panelOnOffOrder: "",
            DefaultsKey.panelHiddenRows: "",
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
            DefaultsKey.inputSwitchLongPressCapsLock: true,
            DefaultsKey.clipboardHistoryShortcutEnabled: true,
            DefaultsKey.clipboardHistoryRetentionDays: ClipboardHistoryRetention.default.rawValue,
            DefaultsKey.clipboardHistoryIgnoredApps: [String](),
            DefaultsKey.layoutFixIgnoredApps: [String](),
            DefaultsKey.clipboardHistoryImageBudgetMB: ClipboardHistoryImageBudget.default.rawValue,
            DefaultsKey.clipboardHistoryRecordsMedia: true,
            DefaultsKey.screenshotOverlayShortcutEnabled: true,
            DefaultsKey.screenshotFullScreenShortcutEnabled: true,
            DefaultsKey.screenshotSaveToFile: false,
            DefaultsKey.screenshotCopyToClipboard: true,
            DefaultsKey.screenshotShowPreview: true,
            DefaultsKey.screenshotPreviewPosition: ScreenshotSupport.PreviewPosition.bottomRight.rawValue,
            DefaultsKey.screenshotColorFormat: ScreenshotSupport.ColorFormat.default.rawValue,
            DefaultsKey.screenshotLoupeAtStart: true,
            DefaultsKey.screenshotCaptureSounds: true,
            DefaultsKey.screenshotSnapToLines: true,
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
            // Screen recorder editor (7.7 C).
            DefaultsKey.recorderAutomaticZoom: true,
            DefaultsKey.recorderGIFSize: RecorderSupport.GIFSize.medium.rawValue,
            DefaultsKey.recorderGIFFrameRate: 12,
            DefaultsKey.recorderEditorPresets: Data(),
            DefaultsKey.updateAutomaticChecks: true,
            DefaultsKey.updateShowNotesBeforeInstall: true,
        ])
    }
}
