// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics
import Foundation

/// Pure model and geometry for the editor's backdrop and watermark: the
/// styles as persisted JSON, their saved presets, and the sizes and places
/// the renderer turns them into. No AppKit, so a harness compiles it on its
/// own. Adapted from upstream's "Backdrop" and "Watermark" sections.
extension ScreenshotSupport {

    // MARK: - Backdrop

    /// Padded background, corner rounding and shadow applied during export.
    enum BackdropID: String, CaseIterable {
        case none, ocean, sunset, forest, candy, graphite

        /// Gradient stops as sRGB components, top-left to bottom-right.
        var stops: [(red: Double, green: Double, blue: Double)] {
            switch self {
            case .none: return []
            case .ocean: return [(0.20, 0.47, 0.96), (0.45, 0.83, 0.98)]
            case .sunset: return [(0.99, 0.36, 0.42), (1.00, 0.75, 0.35)]
            case .forest: return [(0.07, 0.56, 0.43), (0.62, 0.87, 0.50)]
            case .candy: return [(0.66, 0.32, 0.95), (0.99, 0.56, 0.65)]
            case .graphite: return [(0.23, 0.25, 0.31), (0.55, 0.60, 0.70)]
            }
        }
    }

    /// Padding around the image for a backdrop. `factor` is the margin
    /// slider (0…1); even 0 keeps a small frame so the gradient always shows,
    /// and a floor keeps a visible margin around small captures.
    static func backdropPadding(for imageSize: CGSize, factor: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, factor))
        let side = min(imageSize.width, imageSize.height)
        let proportional = side * (0.035 + 0.14 * clamped)
        return max(24, proportional).rounded()
    }

    /// Corner rounding of the capture card in image pixels. Factor 0 keeps
    /// the capture square; 1 is a generous fifth of the short side.
    static func cardCornerRadius(for imageSize: CGSize, factor: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, factor))
        return (clamped * min(imageSize.width, imageSize.height) * 0.2).rounded()
    }

    /// The rounding a picture already carries in its alpha, such as a window
    /// captured with its own corners, in image pixels: how far transparency
    /// reaches in along each corner's diagonal, read as the radius of the arc
    /// that meets the diagonal there. The least rounded corner wins, so a
    /// mark drawn into one corner cannot round the card past the picture. An
    /// opaque picture reads 0.
    static func transparentCornerRadius(of image: CGImage) -> CGFloat {
        let side = min(image.width, image.height, 512) / 2
        guard side >= 2 else { return 0 }
        let corners = [(x: 0, y: 0, stepX: 1, stepY: 1),
                       (x: image.width - side, y: 0, stepX: -1, stepY: 1),
                       (x: 0, y: image.height - side, stepX: 1, stepY: -1),
                       (x: image.width - side, y: image.height - side, stepX: -1, stepY: -1)]
        var reach = Int.max
        for corner in corners {
            guard let crop = image.cropping(to: CGRect(x: corner.x, y: corner.y, width: side, height: side)),
                  let context = CGContext(data: nil, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let pixels = context.data
            else { return 0 }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
            // Rows run top down in the buffer, as in the picture.
            let startX = corner.stepX > 0 ? 0 : side - 1
            let startY = corner.stepY > 0 ? 0 : side - 1
            guard let opaqueAt = (0..<side).first(where: { step in
                let x = startX + step * corner.stepX
                let y = startY + step * corner.stepY
                return pixels.load(fromByteOffset: (y * side + x) * 4 + 3, as: UInt8.self) > 127
            }) else { return 0 }
            reach = min(reach, opaqueAt)
        }
        // The arc crosses the diagonal at r · (1 − 1/√2) from the corner.
        return (CGFloat(reach) / (1 - 1 / 2.0.squareRoot())).rounded()
    }

    /// Gaussian blur radius in output pixels. Keeping it proportional makes
    /// the same slider look the same on small and very large captures.
    static func backdropBlurRadius(for size: CGSize, factor: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, factor))
        return clamped * min(size.width, size.height) * 0.035
    }

    /// The full backdrop configuration behind a capture, persisted as JSON
    /// (one style in use, plus the saved presets). Colors are sRGB
    /// components so the codec stays pure and testable.
    struct BackdropStyle: Codable, Equatable {
        enum Kind: String, Codable {
            case none, preset, solid, gradient, image
        }

        var kind: Kind
        /// BackdropID raw value when kind == .preset.
        var presetID: String?
        /// 1 color (solid) or 2 colors (gradient), each [r, g, b] in 0…1.
        var colors: [[Double]]?
        /// Absolute path when kind == .image (a picked image or a desktop
        /// picture). Only the path is kept; the file is never copied.
        var imagePath: String?
        var padding: Double
        var cornerRadius: Double
        var blur: Double

        init(kind: Kind = .none,
             presetID: String? = nil,
             colors: [[Double]]? = nil,
             imagePath: String? = nil,
             padding: Double = 0.5,
             cornerRadius: Double = 0,
             blur: Double = 0) {
            self.kind = kind
            self.presetID = presetID
            self.colors = colors
            self.imagePath = imagePath
            self.padding = padding
            self.cornerRadius = cornerRadius
            self.blur = blur
        }

        private enum CodingKeys: String, CodingKey {
            case kind, presetID, colors, imagePath, padding, cornerRadius, blur
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = try values.decode(Kind.self, forKey: .kind)
            presetID = try values.decodeIfPresent(String.self, forKey: .presetID)
            colors = try values.decodeIfPresent([[Double]].self, forKey: .colors)
            imagePath = try values.decodeIfPresent(String.self, forKey: .imagePath)
            padding = try values.decode(Double.self, forKey: .padding)
            cornerRadius = try values.decode(Double.self, forKey: .cornerRadius)
            blur = try values.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(kind, forKey: .kind)
            try values.encodeIfPresent(presetID, forKey: .presetID)
            try values.encodeIfPresent(colors, forKey: .colors)
            try values.encodeIfPresent(imagePath, forKey: .imagePath)
            try values.encode(padding, forKey: .padding)
            try values.encode(cornerRadius, forKey: .cornerRadius)
            try values.encode(blur, forKey: .blur)
        }

        /// Clamps sliders, validates colors and drops broken configurations
        /// back to .none, so a damaged persisted value can never wedge the
        /// editor.
        func sanitized() -> BackdropStyle {
            var style = self
            style.padding = style.padding.isFinite ? max(0, min(1, style.padding)) : 0.5
            style.cornerRadius = style.cornerRadius.isFinite
                ? max(0, min(1, style.cornerRadius)) : 0.1
            style.blur = style.blur.isFinite ? max(0, min(1, style.blur)) : 0
            switch style.kind {
            case .none:
                break
            case .preset:
                guard let id = style.presetID, let preset = BackdropID(rawValue: id), preset != .none
                else { return style.demoted() }
            case .solid:
                guard let colors = style.colors, colors.count == 1,
                      colors.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) })
                else { return style.demoted() }
                style.colors = colors.map { $0.map { max(0, min(1, $0)) } }
            case .gradient:
                guard let colors = style.colors, colors.count == 2,
                      colors.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) })
                else { return style.demoted() }
                style.colors = colors.map { $0.map { max(0, min(1, $0)) } }
            case .image:
                guard let path = style.imagePath, !path.isEmpty
                else { return style.demoted() }
            }
            return style
        }

        private func demoted() -> BackdropStyle {
            var style = self
            style.kind = .none
            style.presetID = nil
            style.colors = nil
            style.imagePath = nil
            return style
        }

        /// The look without this capture's sliders, which a saved preset
        /// and a swatch's selection ring compare by.
        var look: BackdropStyle {
            var style = sanitized()
            style.padding = 0.5
            style.cornerRadius = 0.1
            style.blur = 0
            return style
        }

        func encoded() -> String {
            guard let data = try? JSONEncoder().encode(self) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }

        static func decoded(_ raw: String?) -> BackdropStyle {
            guard let raw, !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let style = try? JSONDecoder().decode(BackdropStyle.self, from: data)
            else { return BackdropStyle() }
            return style.sanitized()
        }
    }

    /// Saved custom backdrops, capped at the configured limit.
    static let backdropPresetLimit = 12

    static func decodedBackdropPresets(_ raw: String?) -> [BackdropStyle] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let presets = try? JSONDecoder().decode([BackdropStyle].self, from: data)
        else { return [] }
        return presets.map { $0.sanitized() }
            .filter { $0.kind != .none }
            .suffix(backdropPresetLimit)
            .map { $0 }
    }

    static func encodedBackdropPresets(_ presets: [BackdropStyle]) -> String {
        guard let data = try? JSONEncoder().encode(Array(presets.suffix(backdropPresetLimit)))
        else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// The presets with the current custom look added at the end: never a
    /// built-in preset or nothing, never twice, and at most the limit, the
    /// oldest dropping first.
    static func addingBackdropPreset(_ style: BackdropStyle, to presets: [BackdropStyle]) -> [BackdropStyle] {
        let look = style.look
        guard look.kind != .none, look.kind != .preset,
              !presets.contains(where: { $0.look == look })
        else { return presets }
        return Array((presets + [look]).suffix(backdropPresetLimit))
    }

    // MARK: - Watermark

    /// The nine places a watermark can sit. Upstream shares this grid with
    /// its recorder captions; FixDock has no recorder yet, so it lives here.
    enum WatermarkAnchor: String, Codable, CaseIterable {
        case topLeading, top, topTrailing
        case leading, center, trailing
        case bottomLeading, bottom, bottomTrailing

        /// Where the mark sits, 0…1 with a top-left origin, before the
        /// margin is taken off.
        var unitPoint: CGPoint {
            switch self {
            case .topLeading: return CGPoint(x: 0, y: 0)
            case .top: return CGPoint(x: 0.5, y: 0)
            case .topTrailing: return CGPoint(x: 1, y: 0)
            case .leading: return CGPoint(x: 0, y: 0.5)
            case .center: return CGPoint(x: 0.5, y: 0.5)
            case .trailing: return CGPoint(x: 1, y: 0.5)
            case .bottomLeading: return CGPoint(x: 0, y: 1)
            case .bottom: return CGPoint(x: 0.5, y: 1)
            case .bottomTrailing: return CGPoint(x: 1, y: 1)
            }
        }
    }

    /// A mark of your own on every capture that leaves the editor: a line of
    /// text or a picture from disk, faded, tilted if you like and set on one
    /// of nine places. Persisted as JSON like the backdrop, so the next
    /// capture opens with it already on.
    struct WatermarkStyle: Codable, Equatable {
        enum Kind: String, Codable {
            case none, text, image
        }

        typealias Anchor = WatermarkAnchor

        var kind: Kind
        var text: String
        /// Absolute path when kind == .image; the file is never copied.
        var imagePath: String?
        /// ColorID raw value the text is drawn in.
        var color: String
        var anchor: Anchor
        /// Sliders 0…1; `watermarkFontSize` and `watermarkImageWidth` turn
        /// them into pixels for a given capture.
        var size: Double
        var opacity: Double
        /// Degrees, -90…90: positive tilts the mark up to the right, the way
        /// a diagonal document watermark runs.
        var rotation: Double

        init(kind: Kind = .none,
             text: String = "",
             imagePath: String? = nil,
             color: String = ColorID.white.rawValue,
             anchor: Anchor = .bottomTrailing,
             size: Double = 0.3,
             opacity: Double = 0.4,
             rotation: Double = 0) {
            self.kind = kind
            self.text = text
            self.imagePath = imagePath
            self.color = color
            self.anchor = anchor
            self.size = size
            self.opacity = opacity
            self.rotation = rotation
        }

        static let opacityRange: ClosedRange<Double> = 0.05...1
        static let rotationRange: ClosedRange<Double> = -90...90
        static let textLimit = 120

        /// Clamps the sliders, trims the text and drops a configuration
        /// missing its content back to .none, so a damaged persisted value
        /// can never wedge the editor.
        func sanitized() -> WatermarkStyle {
            var style = self
            style.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.textLimit))
            style.color = ColorID(rawValue: color)?.rawValue ?? ColorID.white.rawValue
            style.size = size.isFinite ? max(0, min(1, size)) : 0.3
            style.opacity = opacity.isFinite
                ? max(Self.opacityRange.lowerBound, min(Self.opacityRange.upperBound, opacity))
                : 0.4
            style.rotation = rotation.isFinite
                ? max(Self.rotationRange.lowerBound, min(Self.rotationRange.upperBound, rotation))
                : 0
            switch style.kind {
            case .none:
                break
            case .text:
                guard !style.text.isEmpty else { return style.demoted() }
            case .image:
                guard let path = style.imagePath, !path.isEmpty else { return style.demoted() }
            }
            return style
        }

        private func demoted() -> WatermarkStyle {
            var style = self
            style.kind = .none
            return style
        }

        func encoded() -> String {
            guard let data = try? JSONEncoder().encode(self) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }

        static func decoded(_ raw: String?) -> WatermarkStyle {
            guard let raw, !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let style = try? JSONDecoder().decode(WatermarkStyle.self, from: data)
            else { return WatermarkStyle() }
            return style.sanitized()
        }
    }

    /// Saved watermarks, capped like the backdrops.
    static func decodedWatermarkPresets(_ raw: String?) -> [WatermarkStyle] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let presets = try? JSONDecoder().decode([WatermarkStyle].self, from: data)
        else { return [] }
        return presets.map { $0.sanitized() }
            .filter { $0.kind != .none }
            .suffix(backdropPresetLimit)
            .map { $0 }
    }

    static func encodedWatermarkPresets(_ presets: [WatermarkStyle]) -> String {
        guard let data = try? JSONEncoder().encode(Array(presets.suffix(backdropPresetLimit)))
        else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Point size of watermark text in image pixels: factor 0 is a discreet
    /// 2% of the short side, 1 a bold 16%.
    static func watermarkFontSize(for imageSize: CGSize, factor: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, factor))
        return max(8, (min(imageSize.width, imageSize.height) * (0.02 + 0.14 * clamped)).rounded())
    }

    /// Width of a watermark picture in image pixels, from a corner mark of
    /// 5% of the capture's width up to half of it. The picture's own
    /// proportions decide the height.
    static func watermarkImageWidth(for imageSize: CGSize, factor: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, factor))
        return max(1, (imageSize.width * (0.05 + 0.45 * clamped)).rounded())
    }

    struct WatermarkPlacement {
        /// Where the mark's center goes, in image pixels with a top-left origin.
        let center: CGPoint
        /// How much the content shrinks so its tilted bounds stay inside the
        /// margins; 1 when it already fits.
        let fit: CGFloat
    }

    /// Where a mark of `contentSize`, turned by `rotation` degrees, sits on a
    /// capture: its tilted bounding box is what the nine places position, so
    /// a diagonal mark in a corner touches the margin instead of leaving it.
    /// The margin is 5% of the short side, more inside rounded corners.
    static func watermarkPlacement(contentSize: CGSize,
                                   rotation: Double,
                                   anchor: WatermarkAnchor,
                                   in imageSize: CGSize,
                                   cornerRadius: CGFloat = 0) -> WatermarkPlacement? {
        guard contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0,
              imageSize.width > 0, imageSize.height > 0, rotation.isFinite
        else { return nil }
        let radians = rotation * .pi / 180
        let bounds = CGSize(
            width: abs(contentSize.width * cos(radians)) + abs(contentSize.height * sin(radians)),
            height: abs(contentSize.width * sin(radians)) + abs(contentSize.height * cos(radians)))
        let shortSide = min(imageSize.width, imageSize.height)
        // The inset rectangle must lie entirely inside the rounded capture.
        // At the diagonal of a quarter circle the inset is r * (1 - sqrt(0.5)).
        // A pixel of breathing room avoids clipping antialiased edges. Keep
        // positive space even on a capture only a few pixels across.
        let radius = cornerRadius.isFinite ? max(0, min(shortSide / 2, cornerRadius)) : 0
        let roundedInset = radius > 0 ? ceil(radius * (1 - sqrt(0.5))) + 1 : 0
        let margin = min(shortSide * 0.45, max(shortSide * 0.05, roundedInset))
        let available = CGSize(width: imageSize.width - margin * 2,
                               height: imageSize.height - margin * 2)
        let fit = min(1, min(available.width / bounds.width, available.height / bounds.height))
        let fitted = CGSize(width: bounds.width * fit, height: bounds.height * fit)
        let point = anchor.unitPoint
        return WatermarkPlacement(
            center: CGPoint(x: margin + (available.width - fitted.width) * point.x + fitted.width / 2,
                            y: margin + (available.height - fitted.height) * point.y + fitted.height / 2),
            fit: fit)
    }
}
