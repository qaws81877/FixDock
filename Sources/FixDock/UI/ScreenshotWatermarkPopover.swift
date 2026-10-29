// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// The watermark picker: a line of text in one of the editor's colors or a
/// picture from disk, set on one of nine places with size, opacity and tilt
/// sliders. Everything applies live and is remembered for the next capture,
/// like the backdrop, and a mark worth keeping goes into the presets row.
/// Adapted from upstream's `ScreenshotWatermarkPopover`.
struct ScreenshotWatermarkPopover: View {
    @ObservedObject var decor: ScreenshotEditorDecor
    @ObservedObject private var l10n = L10n.shared
    @FocusState private var textFocused: Bool

    private var s: Strings { l10n.s }

    private var isOn: Bool {
        decor.watermarkStyle.kind != .none
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            kindPicker
            switch decor.watermarkStyle.kind {
            case .none:
                EmptyView()
            case .text:
                textSection
            case .image:
                imageRow
            }
            if isOn || !decor.watermarkPresets.isEmpty {
                presetGrid
            }
            Divider()
            placementSection
        }
        .padding(14)
        .frame(width: 292)
    }

    // MARK: - Content

    private var kindPicker: some View {
        Picker("", selection: kindBinding) {
            Text(s.screenshotEditorBackdropNone).tag(ScreenshotSupport.WatermarkStyle.Kind.none)
            Text(s.screenshotEditorWatermarkText).tag(ScreenshotSupport.WatermarkStyle.Kind.text)
            Text(s.screenshotEditorWatermarkImage).tag(ScreenshotSupport.WatermarkStyle.Kind.image)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel(s.screenshotEditorWatermark)
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField(s.screenshotEditorWatermarkPlaceholder, text: textBinding)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($textFocused)
                .onAppear {
                    // A fresh text mark is there to be typed; an existing
                    // one keeps the keyboard where it was.
                    guard decor.watermarkStyle.text.isEmpty else { return }
                    DispatchQueue.main.async { textFocused = true }
                }
            HStack(spacing: 4) {
                ForEach(ScreenshotSupport.ColorID.allCases, id: \.self) { colorDot($0) }
            }
        }
    }

    private func colorDot(_ colorID: ScreenshotSupport.ColorID) -> some View {
        let selected = ScreenshotSupport.ColorID(rawValue: decor.watermarkStyle.color) == colorID
        return Button {
            decor.watermarkStyle.color = colorID.rawValue
        } label: {
            ZStack {
                Circle()
                    .fill(Color(nsColor: ScreenshotRenderer.nsColor(colorID)))
                    .frame(width: 17, height: 17)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5))
                if selected {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.9), lineWidth: 1.5)
                        .frame(width: 23, height: 23)
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(s.screenshotEditorColor)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var imageRow: some View {
        let path = decor.watermarkStyle.imagePath
        return HStack(spacing: 8) {
            Group {
                if let path, let thumbnail = BackdropPickerAssets.thumbnail(for: URL(fileURLWithPath: path)) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 22)
            Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? s.screenshotEditorBackdropNone)
                .font(.system(size: 12))
                .foregroundStyle(path == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(s.screenshotChooseFolder) { chooseImage() }
                .controlSize(.small)
        }
    }

    // MARK: - Presets

    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(Array(decor.watermarkPresets.enumerated()), id: \.offset) { index, preset in
                presetSwatch(preset, index: index)
            }
            savePresetSwatch
        }
    }

    private func presetSwatch(_ preset: ScreenshotSupport.WatermarkStyle, index: Int) -> some View {
        let selected = decor.watermarkStyle.sanitized() == preset
        let name = preset.kind == .image
            ? URL(fileURLWithPath: preset.imagePath ?? "").lastPathComponent
            : preset.text
        return Button {
            decor.watermarkStyle = preset
        } label: {
            Group {
                if preset.kind == .image, let path = preset.imagePath,
                   let thumbnail = BackdropPickerAssets.thumbnail(for: URL(fileURLWithPath: path)) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Text(preset.text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: ScreenshotRenderer.nsColor(
                            ScreenshotSupport.ColorID.sanitized(preset.color))))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 5)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            // A neutral plate keeps both black and white marks legible.
            .background(Color(white: 0.5).opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                              lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.borderless)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            // Forgets the saved mark only; a picture it points at stays on disk.
            Button(s.screenshotEditorPresetRemove) { decor.removeWatermarkPreset(at: index) }
        }
    }

    private var canSavePreset: Bool {
        let style = decor.watermarkStyle.sanitized()
        return style.kind != .none && !decor.watermarkPresets.contains(style)
    }

    private var savePresetSwatch: some View {
        Button {
            decor.saveCurrentWatermarkAsPreset()
        } label: {
            ZStack {
                Color.primary.opacity(0.06)
                Image(systemName: "plus")
                    .foregroundStyle(.secondary)
            }
            .frame(height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .buttonStyle(.borderless)
        .disabled(!canSavePreset)
        .help(s.screenshotEditorWatermarkSave)
        .accessibilityLabel(s.screenshotEditorWatermarkSave)
    }

    // MARK: - Placement

    private var placementSection: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                sliderLabel(s.screenshotEditorWatermarkPosition)
                anchorGrid
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                sliderLabel(s.screenshotEditorWatermarkSize)
                Slider(value: binding(\.size), in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel(s.screenshotEditorWatermarkSize)
            }
            HStack(spacing: 8) {
                sliderLabel(s.screenshotPinOpacity)
                Slider(value: binding(\.opacity), in: ScreenshotSupport.WatermarkStyle.opacityRange)
                    .controlSize(.small)
                    .accessibilityLabel(s.screenshotPinOpacity)
            }
            HStack(spacing: 8) {
                let degrees = "\(Int(decor.watermarkStyle.rotation.rounded()))°"
                sliderLabel(s.screenshotEditorWatermarkRotation)
                Slider(value: binding(\.rotation), in: ScreenshotSupport.WatermarkStyle.rotationRange, step: 1)
                    .controlSize(.small)
                    .accessibilityLabel(s.screenshotEditorWatermarkRotation)
                    .accessibilityValue(degrees)
                Text(degrees)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .disabled(!isOn)
    }

    private func sliderLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(width: 80, alignment: .leading)
            .foregroundStyle(isOn ? .secondary : .tertiary)
    }

    /// Nine places instead of a drag: it reads at a glance and a corner mark
    /// stays in its corner whatever the capture.
    private var anchorGrid: some View {
        let rows: [[ScreenshotSupport.WatermarkAnchor]] = [
            [.topLeading, .top, .topTrailing],
            [.leading, .center, .trailing],
            [.bottomLeading, .bottom, .bottomTrailing],
        ]
        return VStack(spacing: 3) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(rows[row], id: \.rawValue) { anchor in
                        let selected = decor.watermarkStyle.anchor == anchor
                        Button {
                            decor.watermarkStyle.anchor = anchor
                        } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.10))
                                .frame(width: 22, height: 15)
                        }
                        .buttonStyle(.borderless)
                        .help(anchorName(anchor))
                        .accessibilityLabel(anchorName(anchor))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func anchorName(_ anchor: ScreenshotSupport.WatermarkAnchor) -> String {
        switch anchor {
        case .topLeading: return s.screenshotEditorAnchorTopLeading
        case .top: return s.screenshotEditorAnchorTop
        case .topTrailing: return s.screenshotEditorAnchorTopTrailing
        case .leading: return s.screenshotEditorAnchorLeading
        case .center: return s.screenshotEditorAnchorCenter
        case .trailing: return s.screenshotEditorAnchorTrailing
        case .bottomLeading: return s.screenshotEditorAnchorBottomLeading
        case .bottom: return s.screenshotEditorAnchorBottom
        case .bottomTrailing: return s.screenshotEditorAnchorBottomTrailing
        }
    }

    // MARK: - Bindings

    private var kindBinding: Binding<ScreenshotSupport.WatermarkStyle.Kind> {
        Binding {
            decor.watermarkStyle.kind
        } set: { kind in
            decor.watermarkStyle.kind = kind
            // Choosing a picture mark without a picture yet is asking for one.
            if kind == .image, decor.watermarkStyle.imagePath == nil {
                DispatchQueue.main.async { chooseImage() }
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding {
            decor.watermarkStyle.text
        } set: { text in
            decor.watermarkStyle.text = String(text.prefix(ScreenshotSupport.WatermarkStyle.textLimit))
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ScreenshotSupport.WatermarkStyle, Double>) -> Binding<Double> {
        Binding {
            decor.watermarkStyle[keyPath: keyPath]
        } set: { value in
            decor.watermarkStyle[keyPath: keyPath] = value
        }
    }

    private func chooseImage() {
        if let url = BackdropPickerAssets.chooseImage() {
            decor.watermarkStyle.imagePath = url.path
        }
    }
}
