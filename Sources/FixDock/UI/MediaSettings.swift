// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Media tool's workspace: image options, a drop zone and the results.
/// Adapted from upstream's MediaWorkspaceView, image compression only.
struct MediaSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var media = MediaService.shared
    @AppStorage(DefaultsKey.mediaImageFormat) private var format = ImageOutputFormat.original.rawValue
    @AppStorage(DefaultsKey.mediaImageMaxDimension) private var maxDimension = 0
    @AppStorage(DefaultsKey.mediaImageMetadata) private var metadata = ImageMetadataPolicy.removeLocation.rawValue
    private var s: Strings { l10n.s }

    var body: some View {
        Form {
            Section {
                Text(s.mediaIntro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(s.mediaImageSection) {
                MediaPresetBar()
                Picker(s.mediaFormatLabel, selection: $format) {
                    Text(s.mediaFormatOriginal).tag(ImageOutputFormat.original.rawValue)
                    Text("JPEG").tag(ImageOutputFormat.jpeg.rawValue)
                    Text("PNG").tag(ImageOutputFormat.png.rawValue)
                    Text("HEIC").tag(ImageOutputFormat.heic.rawValue)
                }
                Toggle(s.mediaResizeToggle, isOn: Binding(
                    get: { maxDimension > 0 },
                    set: { maxDimension = $0 ? 2048 : 0 }
                ))
                if maxDimension > 0 {
                    Stepper(value: $maxDimension,
                            in: ImageCompressionOptions.maxDimensionRange,
                            step: 256) {
                        Text(String(format: s.mediaPixelsFormat, maxDimension))
                            .monospacedDigit()
                    }
                }
                Picker(s.mediaMetadataLabel, selection: $metadata) {
                    Text(s.mediaMetadataRemoveLocation).tag(ImageMetadataPolicy.removeLocation.rawValue)
                    Text(s.mediaMetadataKeep).tag(ImageMetadataPolicy.keep.rawValue)
                    Text(s.mediaMetadataRemoveAll).tag(ImageMetadataPolicy.removeAll.rawValue)
                }
                MediaOutputPicker()
            }

            Section {
                MediaDropZone(compact: false)
                MediaProgressRow()
            }

            if MediaResultsList.hasContent(media) {
                Section {
                    MediaResultsList(compact: false)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { media.setVisible(true, on: .settings) }
        .onDisappear { media.setVisible(false, on: .settings) }
    }
}

/// The menu panel's Media card: the same engine and saved options, with the
/// level, the output and the drop zone in reach. Format, size and metadata
/// stay on the Settings page.
struct PanelMediaView: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var media = MediaService.shared

    var body: some View {
        let s = l10n.s
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: AppFeature.mediaTools.symbolName)
                    .frame(width: 16)
                Text(AppFeature.mediaTools.title(s))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(s.mediaLocalNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            MediaDropZone(compact: true)
            MediaPresetBar()
            MediaOutputPicker()
            MediaProgressRow()
            if MediaResultsList.hasContent(media) {
                MediaResultsList(compact: true)
            }
            Button(s.mediaMoreOptions) {
                if let page = AppFeature.mediaTools.settingsPage {
                    SettingsNavigator.shared.open(.feature(page))
                }
                appDelegate()?.openSettings()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .settingsCard()
    }
}

/// Low, Medium and High as a segmented bar, with what the level means under it.
struct MediaPresetBar: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.mediaImagePreset) private var preset = CompressionPreset.defaultPreset.rawValue

    var body: some View {
        let s = l10n.s
        VStack(alignment: .leading, spacing: 4) {
            Text(s.mediaPresetLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(s.mediaPresetLabel, selection: $preset) {
                Text(s.mediaPresetLow).tag(CompressionPreset.low.rawValue)
                Text(s.mediaPresetMedium).tag(CompressionPreset.medium.rawValue)
                Text(s.mediaPresetHigh).tag(CompressionPreset.high.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(caption(s))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func caption(_ s: Strings) -> String {
        let level: String
        switch CompressionPreset.from(preset) {
        case .low: level = s.mediaPresetLowCaption
        case .medium: level = s.mediaPresetMediumCaption
        case .high: level = s.mediaPresetHighCaption
        }
        return "\(level) \(s.mediaPresetCaption)"
    }
}

struct MediaOutputPicker: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.mediaOutputMode) private var output = MediaOutputMode.zip.rawValue

    var body: some View {
        let s = l10n.s
        VStack(alignment: .leading, spacing: 4) {
            Text(s.mediaOutputLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(s.mediaOutputLabel, selection: $output) {
                Text(s.mediaOutputZip).tag(MediaOutputMode.zip.rawValue)
                Text(s.mediaOutputFiles).tag(MediaOutputMode.files.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(MediaOutputMode.from(output) == .zip ? s.mediaOutputZipCaption : s.mediaOutputCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Click to choose or drop files. Starts the job straight away.
struct MediaDropZone: View {
    let compact: Bool
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var media = MediaService.shared
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: compact ? 3 : 6) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: compact ? 18 : 26))
                .foregroundStyle(.secondary)
            Text(l10n.s.mediaDropHint)
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 64 : 110)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture { chooseImages() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDropped(providers)
            return true
        }
        .disabled(media.isRunning)
    }

    private func chooseImages() {
        guard !media.isRunning else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let response = compact
            ? (appDelegate()?.hidingPopover { panel.runModal() } ?? panel.runModal())
            : panel.runModal()
        guard response == .OK else { return }
        start(panel.urls)
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collected = DroppedURLs()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collected.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            start(collected.urls)
        }
    }

    private func start(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        media.compressImages(urls, options: MediaImageSettings.options, output: MediaImageSettings.output)
    }
}

struct MediaProgressRow: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var media = MediaService.shared

    var body: some View {
        if media.isRunning {
            HStack {
                ProgressView(value: Double(media.completed), total: Double(max(media.total, 1)))
                Text(String(format: l10n.s.mediaRunningFormat, min(media.completed + 1, media.total), media.total))
                    .font(.caption)
                    .monospacedDigit()
                Button(l10n.s.mediaCancel) { media.cancel() }
                    .controlSize(.small)
            }
        }
    }
}

struct MediaResultsList: View {
    let compact: Bool
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var media = MediaService.shared

    static func hasContent(_ media: MediaService) -> Bool {
        !media.results.isEmpty || media.skippedCount > 0 || media.wasCancelled || media.zip != nil || media.zipFailed
    }

    var body: some View {
        let s = l10n.s
        VStack(alignment: .leading, spacing: 6) {
            if let zip = media.zip {
                row(icon: "doc.zipper", tint: .accentColor, title: zip.url.lastPathComponent,
                    detail: String(format: s.mediaZipResultFormat, zip.count, zip.url.lastPathComponent,
                                   ByteCountFormatter().string(fromByteCount: zip.size)),
                    reveal: zip.url)
            }
            if media.zipFailed {
                Label(s.mediaErrorZip, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if media.skippedCount > 0 {
                Text(String(format: s.mediaSkippedFormat, media.skippedCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if media.wasCancelled {
                Text(s.mediaCancelled)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(compact ? Array(media.results.suffix(3)) : media.results) { result in
                row(icon: result.failure == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: result.failure == nil ? .green : .orange,
                    title: result.source.lastPathComponent,
                    detail: detail(result, s),
                    reveal: result.output)
            }
            if !media.isRunning {
                Button(s.mediaClearResults) { media.clearResults() }
                    .controlSize(.small)
            }
        }
    }

    private func row(icon: String, tint: Color, title: String, detail: String, reveal: URL?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(compact ? .caption : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 2)
            }
            Spacer(minLength: 8)
            if let reveal {
                Button(l10n.s.mediaShowInFinder) {
                    NSWorkspace.shared.activateFileViewerSelecting([reveal])
                }
                .controlSize(.small)
            }
        }
    }

    private func detail(_ result: MediaService.ImageResult, _ s: Strings) -> String {
        switch result.failure {
        case .compression(.unreadable): return s.mediaErrorUnreadable
        case .compression(.unsupported): return s.mediaErrorUnsupported
        case .compression(.tooLarge): return s.mediaErrorTooLarge
        case .compression(.encodeFailed): return s.mediaErrorEncode
        case .compression(.locationRemained): return s.mediaErrorLocation
        case .write: return s.mediaErrorWrite
        case nil: break
        }
        let formatter = ByteCountFormatter()
        let before = formatter.string(fromByteCount: result.originalSize)
        let after = formatter.string(fromByteCount: result.outputSize)
        if result.keptOriginal { return s.mediaResultKeptOriginal }
        if result.outputSize >= result.originalSize {
            return String(format: s.mediaResultGrewFormat, before, after)
        }
        let saved = ImageCompressionSupport.savedPercent(original: result.originalSize, output: result.outputSize)
        return String(format: s.mediaResultSizeFormat, before, after, "\(Int(saved.rounded()))%")
    }
}

/// Drop callbacks arrive on arbitrary queues.
private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []

    var urls: [URL] { lock.withLock { values } }

    func append(_ url: URL) { lock.withLock { values.append(url) } }
}
