// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The "Screen capture" page: a Screenshot tab and, once the recorder is
/// installed, a Screen recording tab. One page for both tools, as the owner
/// chose; the hub still installs them separately. New in FixDock.
struct ScreenCaptureSettingsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var runtime = FeatureRuntime.shared
    @State private var tab: ScreenCaptureTool = .screenshot

    var body: some View {
        let s = l10n.s
        let tools = ScreenCaptureTool.shown()
        VStack(spacing: 0) {
            if tools.count > 1 {
                Picker("", selection: $tab) {
                    ForEach(tools) { tool in
                        Text(tool == .screenshot ? s.screenshotToolScreenshot : s.screenshotToolRecording)
                            .tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 12)
            }
            switch tools.contains(tab) ? tab : .screenshot {
            case .screenshot:
                ScreenshotSettingsTab()
            case .recording:
                Form {
                    Section {
                        Label(s.screenshotRecordingLater, systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}

private struct ScreenshotSettingsTab: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.screenshotSaveToFile) private var saveToFile = true
    @AppStorage(DefaultsKey.screenshotCopyToClipboard) private var copyToClipboard = true
    @AppStorage(DefaultsKey.screenshotSaveFolder) private var saveFolder = ""
    @AppStorage(DefaultsKey.screenshotShowPreview) private var showPreview = true
    @AppStorage(DefaultsKey.screenshotPreviewCloseSeconds) private var closeSeconds = 0
    @AppStorage(DefaultsKey.screenshotPreviewPosition) private var position =
        ScreenshotSupport.PreviewPosition.bottomRight.rawValue
    private var s: Strings { l10n.s }

    var body: some View {
        Form {
            if !permissions.screenRecording {
                Section {
                    Label(s.screenshotNeedsPermission, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button(s.screenshotGrantPermission) { Permissions.shared.request(.screenRecording) }
                }
            }

            Section(s.screenshotShortcutsTitle) {
                ShortcutRecorderRow(role: .captureOverlay, title: s.screenshotShortcutOverlay,
                                    enabledKey: DefaultsKey.screenshotOverlayShortcutEnabled)
                ShortcutRecorderRow(role: .captureFullScreen, title: s.screenshotShortcutFullScreen,
                                    enabledKey: DefaultsKey.screenshotFullScreenShortcutEnabled)
            }

            Section(s.screenshotAfterTitle) {
                Toggle(s.screenshotShowPreview, isOn: $showPreview)
                if showPreview {
                    Text(s.screenshotPreviewSavesOnly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(s.screenshotPreviewPositionTitle, selection: $position) {
                        ForEach(ScreenshotSupport.PreviewPosition.allCases) { choice in
                            Text(positionTitle(choice)).tag(choice.rawValue)
                        }
                    }
                    Picker(s.screenshotPreviewCloseTitle, selection: $closeSeconds) {
                        ForEach(ScreenshotSupport.previewCloseChoices, id: \.self) { seconds in
                            Text(seconds == 0 ? s.screenshotPreviewCloseNever
                                 : String(format: s.screenshotPreviewCloseAfter, seconds))
                                .tag(seconds)
                        }
                    }
                    if closeSeconds > 0 {
                        Text(s.screenshotPreviewCloseWarning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Toggle(s.screenshotSaveToFile, isOn: $saveToFile)
                }
                HStack {
                    Text(s.screenshotFolder)
                    Spacer(minLength: 8)
                    Text(ScreenshotService.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button(s.screenshotChooseFolder, action: chooseFolder)
                    if !saveFolder.isEmpty {
                        Button(s.screenshotUseDesktop) { saveFolder = "" }
                    }
                }
                .disabled(!saveToFile && !showPreview)
                if saveToFile || showPreview, !ScreenshotService.saveFolderIsUsable() {
                    Label(s.screenshotFolderUnavailable, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle(s.screenshotCopyToClipboard, isOn: $copyToClipboard)
                if !showPreview, !saveToFile, !copyToClipboard {
                    Label(s.screenshotNothingHappens, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section(s.screenshotToolKeysTitle) {
                ScreenshotToolOrderControls(showsTitle: false)
            }

            Section(s.screenshotKeysTitle) {
                ForEach(keyRows, id: \.0) { key, text in
                    HStack(spacing: 8) {
                        KeyCap(label: key)
                        Text(text).font(.callout)
                    }
                }
                Text(s.screenshotWindowLimit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    private func positionTitle(_ position: ScreenshotSupport.PreviewPosition) -> String {
        switch position {
        case .automatic: return s.screenshotPreviewPositionAutomatic
        case .bottomRight: return s.screenshotPreviewPositionBottomRight
        case .bottomLeft: return s.screenshotPreviewPositionBottomLeft
        case .topRight: return s.screenshotPreviewPositionTopRight
        case .topLeft: return s.screenshotPreviewPositionTopLeft
        }
    }

    private var keyRows: [(String, String)] {
        [("1", s.screenshotKeyHelpScreenshot), ("2", s.screenshotKeyHelpRecording),
         ("R", s.screenshotKeyHelpRepeat), ("Z", s.screenshotKeyHelpLoupe),
         ("C", s.screenshotKeyHelpColor), ("S", s.screenshotKeyHelpScroll),
         ("↩", s.screenshotKeyHelpFull), ("Space", s.screenshotKeyHelpMove),
         ("esc", s.screenshotKeyCancel)]
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ScreenshotService.saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            saveFolder = url.path
        }
    }
}

/// The menu panel row: the two captures and the last result.
struct PanelScreenshotRow: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = ScreenshotService.shared

    var body: some View {
        let s = l10n.s
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: AppFeature.screenshot.symbolName)
                    .frame(width: 16)
                Text(AppFeature.screenshot.title(s))
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Button {
                    if let page = AppFeature.screenshot.settingsPage {
                        SettingsNavigator.shared.open(.feature(page))
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help(s.menuSettings)
            }
            HStack(spacing: 6) {
                Button(s.screenshotPanelSelect) { service.openOverlay() }
                Button(s.screenshotPanelFullScreen) { service.captureFullScreen() }
            }
            .controlSize(.small)
            .disabled(service.isCapturing)
            .padding(.leading, 24)
            if let outcome = service.lastOutcome {
                Group {
                    switch outcome {
                    case .saved(let url):
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label(String(format: s.screenshotSavedAs, url.lastPathComponent),
                                  systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.green)
                    case .copied:
                        Label(s.screenshotCopied, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .lineLimit(2)
                .padding(.leading, 24)
            }
        }
    }
}
