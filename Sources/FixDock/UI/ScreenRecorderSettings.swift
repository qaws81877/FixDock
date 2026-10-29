// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// The Screen recording tab of the "Screen capture" page: how a recording
/// starts, what it captures and how the editor starts a new recording.
/// Adapted from upstream's recorder settings: no sharing, no own shortcut,
/// and the save folder is the screenshot tool's.
struct ScreenRecorderSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = ScreenRecorderService.shared
    @ObservedObject private var runtime = FeatureRuntime.shared
    @AppStorage(DefaultsKey.recorderCountdown) private var countdown = ScreenRecorderSupport.defaultCountdown
    @AppStorage(DefaultsKey.recorderQuality) private var qualityRaw = RecorderSupport.Quality.balanced.rawValue
    @AppStorage(DefaultsKey.recorderFrameRate) private var frameRate = 60
    @AppStorage(DefaultsKey.recorderSystemAudio) private var systemAudio = true
    @AppStorage(DefaultsKey.recorderMicrophone) private var microphone = false
    @AppStorage(DefaultsKey.recorderPointerTrack) private var pointerTrack = true
    @AppStorage(DefaultsKey.recorderTypingTrack) private var typingTrack = false
    @AppStorage(DefaultsKey.recorderAutomaticZoom) private var automaticZoom = true
    @AppStorage(DefaultsKey.recorderGIFSize) private var gifSizeRaw = RecorderSupport.GIFSize.medium.rawValue
    @AppStorage(DefaultsKey.recorderGIFFrameRate) private var gifFrameRate = 12
    @AppStorage(DefaultsKey.screenshotSaveFolder) private var saveFolder = ""
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

            Section(s.recorderSectionStart) {
                if service.isRecording {
                    HStack {
                        Label(String(format: s.recorderRecordingFormat,
                                     RecorderSupport.elapsedLabel(seconds: service.elapsedSeconds)),
                              systemImage: "record.circle")
                            .foregroundStyle(.red)
                            .monospacedDigit()
                        Spacer()
                        Button(s.recorderStop) { service.stop() }
                    }
                }
                if runtime.installedFeatures.contains(.screenshot) {
                    Text(s.recorderStartHint)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(s.recorderStopHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(s.recorderNeedsScreenshot, systemImage: "info.circle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker(s.recorderCountdownLabel, selection: $countdown) {
                    ForEach(ScreenRecorderSupport.countdownChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? s.recorderCountdownOff
                             : String(format: s.recorderCountdownSecondsFormat, seconds))
                            .tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
                // `saveFolder` is observed so a change on the Screenshot tab
                // re-renders this row.
                Text(String(format: s.recorderFolderFormat,
                            ScreenshotService.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .id(saveFolder)
                if !ScreenshotService.saveFolderIsUsable() {
                    Label(s.screenshotFolderUnavailable, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section(s.recorderSectionCapture) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(s.recorderSystemAudioToggle, isOn: $systemAudio)
                    Text(s.recorderSystemAudioCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(s.recorderMicrophoneToggle, isOn: $microphone)
                        .onChange(of: microphone) { _, enabled in
                            // Asked only when the option is turned on.
                            if enabled, permissions.microphoneUndetermined {
                                permissions.requestMicrophone()
                            }
                        }
                    Text(s.recorderMicrophoneCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if microphone, !permissions.microphone, !permissions.microphoneUndetermined {
                        permissionButton(.microphone)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(s.recorderPointerToggle, isOn: $pointerTrack)
                    Text(s.recorderPointerCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(s.recorderTypingToggle, isOn: $typingTrack)
                        .onChange(of: typingTrack) { _, enabled in
                            // Accessibility is asked only for this track.
                            if enabled, !permissions.accessibility {
                                permissions.request(.accessibility)
                            }
                        }
                    Text(s.recorderTypingCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if typingTrack, !permissions.accessibility {
                        permissionButton(.accessibility)
                    }
                }
                Picker(s.recorderFrameRateLabel, selection: $frameRate) {
                    ForEach(RecorderSupport.frameRates, id: \.self) { rate in
                        Text(String(format: s.recorderFrameRateFormat, rate)).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 4) {
                    Picker(s.recorderQualityLabel, selection: $qualityRaw) {
                        Text(s.recorderQualitySmall).tag(RecorderSupport.Quality.small.rawValue)
                        Text(s.recorderQualityBalanced).tag(RecorderSupport.Quality.balanced.rawValue)
                        Text(s.recorderQualityHigh).tag(RecorderSupport.Quality.high.rawValue)
                    }
                    Text(s.recorderQualityCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(s.recorderEditorSettingsSection) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(s.recorderEditorSettingsAutomaticZoomToggle, isOn: $automaticZoom)
                    Text(s.recorderEditorSettingsAutomaticZoomCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker(s.recorderEditorSettingsGIFSizeLabel, selection: $gifSizeRaw) {
                    Text(s.recorderEditorSettingsGIFSizeSmall).tag(RecorderSupport.GIFSize.small.rawValue)
                    Text(s.recorderEditorSettingsGIFSizeMedium).tag(RecorderSupport.GIFSize.medium.rawValue)
                    Text(s.recorderEditorSettingsGIFSizeLarge).tag(RecorderSupport.GIFSize.large.rawValue)
                }
                .pickerStyle(.segmented)
                Picker(s.recorderEditorSettingsGIFFrameRateLabel, selection: $gifFrameRate) {
                    ForEach(RecorderSupport.gifFrameRates, id: \.self) { rate in
                        Text(String(format: s.recorderFrameRateFormat, rate)).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    private func permissionButton(_ kind: PermissionKind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(kind.title(s))
                .font(.caption)
            Button(s.permissionRequest) { permissions.request(kind) }
                .controlSize(.small)
        }
    }
}
