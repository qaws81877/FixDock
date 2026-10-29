// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import ImageIO

/// The backdrop and watermark of one editor: the styles in use, the saved
/// presets, and the pictures they point at. Styles and presets are
/// remembered between captures under upstream's keys. A picked picture is
/// kept as its path only: nothing is copied, and a file that is gone later
/// quietly draws nothing. The editor model holds one and forwards its
/// changes, so the canvas, the popovers and the exporter share it. Adapted
/// from the backdrop and watermark parts of upstream's editor model.
final class ScreenshotEditorDecor: ObservableObject {
    /// The full backdrop configuration (kind, colors or image, margin,
    /// corner and blur sliders), applied live on the canvas.
    @Published var backdropStyle: ScreenshotSupport.BackdropStyle {
        didSet {
            UserDefaults.standard.set(backdropStyle.encoded(), forKey: DefaultsKey.screenshotBackdropStyle)
            reloadBackdropImageIfNeeded()
            changed?()
        }
    }
    /// Custom backdrops the person chose to keep.
    @Published private(set) var backdropPresets: [ScreenshotSupport.BackdropStyle] {
        didSet {
            UserDefaults.standard.set(ScreenshotSupport.encodedBackdropPresets(backdropPresets),
                                      forKey: DefaultsKey.screenshotBackdropPresets)
        }
    }
    /// Loaded picture for an image backdrop; nil when missing on disk,
    /// which renders as no backdrop.
    @Published private(set) var backdropImage: CGImage?
    /// A mark of your own over the capture, applied live on the canvas.
    @Published var watermarkStyle: ScreenshotSupport.WatermarkStyle {
        didSet {
            UserDefaults.standard.set(watermarkStyle.encoded(), forKey: DefaultsKey.screenshotWatermarkStyle)
            reloadWatermarkImageIfNeeded()
            changed?()
        }
    }
    /// Loaded picture for an image watermark; nil when missing on disk,
    /// which draws nothing.
    @Published private(set) var watermarkImage: CGImage?
    /// Watermarks the person chose to keep.
    @Published private(set) var watermarkPresets: [ScreenshotSupport.WatermarkStyle] {
        didSet {
            UserDefaults.standard.set(ScreenshotSupport.encodedWatermarkPresets(watermarkPresets),
                                      forKey: DefaultsKey.screenshotWatermarkPresets)
        }
    }

    /// Called after a style changes, so the editor can update its unsaved
    /// state.
    var changed: (() -> Void)?
    private var forwarding: AnyCancellable?

    private var cleanBackdropStyle = ScreenshotSupport.BackdropStyle()
    private var cleanWatermarkStyle = ScreenshotSupport.WatermarkStyle()
    private var loadedBackdropPath: String?
    private var loadedWatermarkPath: String?
    /// Read once per picture: a canvas change makes a new one.
    private var measuredCorner: (image: CGImage, radius: CGFloat)?

    init() {
        let defaults = UserDefaults.standard
        backdropStyle = ScreenshotSupport.BackdropStyle.decoded(
            defaults.string(forKey: DefaultsKey.screenshotBackdropStyle))
        backdropPresets = ScreenshotSupport.decodedBackdropPresets(
            defaults.string(forKey: DefaultsKey.screenshotBackdropPresets))
        watermarkStyle = ScreenshotSupport.WatermarkStyle.decoded(
            defaults.string(forKey: DefaultsKey.screenshotWatermarkStyle))
        watermarkPresets = ScreenshotSupport.decodedWatermarkPresets(
            defaults.string(forKey: DefaultsKey.screenshotWatermarkPresets))
        reloadBackdropImageIfNeeded()
        reloadWatermarkImageIfNeeded()
        markClean()
    }

    /// Redraws `owner`'s views whenever the decor changes, so a view that
    /// observes only the editor model still follows it.
    func forwardChanges<Owner: ObservableObject>(to owner: Owner)
        where Owner.ObjectWillChangePublisher == ObservableObjectPublisher {
        forwarding = objectWillChange.sink { [weak owner] _ in owner?.objectWillChange.send() }
    }

    // MARK: - Unsaved state

    func markClean() {
        cleanBackdropStyle = backdropStyle.sanitized()
        cleanWatermarkStyle = watermarkStyle.sanitized()
    }

    /// True when the look changed since the capture last left the editor.
    var differsFromClean: Bool {
        backdropStyle.sanitized() != cleanBackdropStyle || watermarkStyle.sanitized() != cleanWatermarkStyle
    }

    // MARK: - Backdrop

    /// The style resolved into what the renderer paints, shared by the live
    /// canvas and the exporter.
    var backdropFill: ScreenshotRenderer.BackdropFill {
        let style = backdropStyle.sanitized()
        switch style.kind {
        case .none:
            return .none
        case .preset:
            guard let id = style.presetID, let preset = ScreenshotSupport.BackdropID(rawValue: id)
            else { return .none }
            return .colors(preset.stops)
        case .solid, .gradient:
            let colors = (style.colors ?? []).map { (red: $0[0], green: $0[1], blue: $0[2]) }
            return colors.isEmpty ? .none : .colors(colors)
        case .image:
            guard let backdropImage else { return .none }
            return .image(backdropImage)
        }
    }

    /// True when something actually paints behind the capture (an image
    /// backdrop whose file vanished counts as nothing).
    var showsBackdrop: Bool {
        if case .none = backdropFill { return false }
        return true
    }

    /// Backdrop margin in image pixels; zero while the backdrop is off. The
    /// live canvas and the exporter share this.
    func paddingPixels(for imageSize: CGSize) -> CGFloat {
        showsBackdrop
            ? ScreenshotSupport.backdropPadding(for: imageSize, factor: CGFloat(backdropStyle.sanitized().padding))
            : 0
    }

    /// Corner rounding of the capture card in image pixels.
    func cardCornerPixels(for imageSize: CGSize) -> CGFloat {
        ScreenshotSupport.cardCornerRadius(for: imageSize, factor: CGFloat(backdropStyle.sanitized().cornerRadius))
    }

    /// The card's outline, which its shadow follows: a window's own rounded
    /// corners when they are rounder than the person's, as the exporter draws.
    func cardOutlineCornerPixels(for image: CGImage) -> CGFloat {
        let size = CGSize(width: image.width, height: image.height)
        return max(cardCornerPixels(for: size), transparentCorner(of: image))
    }

    private func transparentCorner(of image: CGImage) -> CGFloat {
        if let measuredCorner, measuredCorner.image === image { return measuredCorner.radius }
        let radius = ScreenshotSupport.transparentCornerRadius(of: image)
        measuredCorner = (image, radius)
        return radius
    }

    /// Keeps the current custom backdrop (colors or image) in the presets
    /// row; built-in presets and duplicates are ignored.
    func saveCurrentBackdropAsPreset() {
        let presets = ScreenshotSupport.addingBackdropPreset(backdropStyle, to: backdropPresets)
        if presets != backdropPresets { backdropPresets = presets }
    }

    func removeBackdropPreset(at index: Int) {
        guard backdropPresets.indices.contains(index) else { return }
        backdropPresets.remove(at: index)
    }

    private func reloadBackdropImageIfNeeded() {
        guard backdropStyle.kind == .image, let path = backdropStyle.imagePath else {
            backdropImage = nil
            loadedBackdropPath = nil
            return
        }
        if backdropImage != nil, loadedBackdropPath == path { return }
        loadedBackdropPath = path
        backdropImage = Self.loadImageFile(path)
    }

    // MARK: - Watermark

    /// True when a mark actually draws: text with something typed, or a
    /// picture that loaded.
    var showsWatermark: Bool {
        switch watermarkStyle.sanitized().kind {
        case .none: return false
        case .text: return true
        case .image: return watermarkImage != nil
        }
    }

    /// Keeps the current mark, placement and all, in the presets row;
    /// duplicates are ignored.
    func saveCurrentWatermarkAsPreset() {
        let style = watermarkStyle.sanitized()
        guard style.kind != .none, !watermarkPresets.contains(style) else { return }
        watermarkPresets = Array((watermarkPresets + [style]).suffix(ScreenshotSupport.backdropPresetLimit))
    }

    func removeWatermarkPreset(at index: Int) {
        guard watermarkPresets.indices.contains(index) else { return }
        watermarkPresets.remove(at: index)
    }

    private func reloadWatermarkImageIfNeeded() {
        guard watermarkStyle.kind == .image, let path = watermarkStyle.imagePath else {
            watermarkImage = nil
            loadedWatermarkPath = nil
            return
        }
        if watermarkImage != nil, loadedWatermarkPath == path { return }
        loadedWatermarkPath = path
        watermarkImage = Self.loadImageFile(path)
    }

    /// Loads and caps a backdrop or watermark picture: a desktop picture can
    /// be 6K and neither needs more than the export canvas. Reads only.
    private static func loadImageFile(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Export

    /// Finishes the flattened capture with the watermark, the corners and,
    /// unless `withBackdrop` is false (a pin), the backdrop.
    func finished(_ flattened: ScreenshotRenderer.Export, base: CGImage,
                  withBackdrop: Bool) -> ScreenshotRenderer.Export? {
        ScreenshotRenderer.finishedExport(flattened,
                                          watermark: watermarkStyle,
                                          watermarkImage: watermarkImage,
                                          style: backdropStyle,
                                          fill: withBackdrop ? backdropFill : .none,
                                          outlineCorner: cardOutlineCornerPixels(for: base))
    }
}
