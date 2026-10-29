// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import CoreImage

/// The passes around the annotations: the watermark, the card's rounded
/// corners and the padded backdrop behind it. Export takes the flattened
/// capture `renderExport` made and finishes it here, at full resolution; the
/// live canvas calls the same watermark pass, so the screen matches the file. Adapted from upstream's renderer export
/// (`renderExport`, `renderBackdrop`, `blurredBackdrop`, `drawFill`,
/// `drawWatermark`).
extension ScreenshotRenderer {
    /// What actually paints behind the capture, resolved by the editor from
    /// the persisted style (image files loaded and cached there).
    enum BackdropFill {
        case none
        /// 1 color = solid, 2 colors = gradient.
        case colors([(red: Double, green: Double, blue: Double)])
        case image(CGImage)
    }

    // MARK: - Watermark

    /// Draws the mark over the finished annotations, so a mark drawn later
    /// can never cover it, and inside the capture, so a backdrop's margin
    /// stays clean. The picture of an image mark is loaded by the editor; nil
    /// draws nothing, the way a vanished backdrop file does.
    static func drawWatermark(_ style: ScreenshotSupport.WatermarkStyle,
                              image: CGImage?,
                              in context: CGContext,
                              imageSize: CGSize,
                              cornerRadius: CGFloat = 0) {
        let style = style.sanitized()
        let contentSize: CGSize
        let draw: (CGRect) -> Void
        switch style.kind {
        case .none:
            return
        case .text:
            let font = NSFont.systemFont(
                ofSize: ScreenshotSupport.watermarkFontSize(for: imageSize, factor: CGFloat(style.size)),
                weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: nsColor(ScreenshotSupport.ColorID.sanitized(style.color)),
            ]
            let measured = style.text.size(withAttributes: attributes)
            contentSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
            draw = { rect in
                // NSAttributedString draws in an unflipped space; flip locally.
                let previous = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                style.text.draw(at: rect.origin, withAttributes: attributes)
                NSGraphicsContext.current = previous
            }
        case .image:
            guard let image, image.width > 0, image.height > 0 else { return }
            let width = ScreenshotSupport.watermarkImageWidth(for: imageSize, factor: CGFloat(style.size))
            contentSize = CGSize(width: width, height: width * CGFloat(image.height) / CGFloat(image.width))
            draw = { rect in
                // CGContext.draw expects an unflipped space; flip around the
                // mark's center, which is the origin by now.
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: rect)
            }
        }
        guard let placement = ScreenshotSupport.watermarkPlacement(contentSize: contentSize,
                                                                   rotation: style.rotation,
                                                                   anchor: style.anchor,
                                                                   in: imageSize,
                                                                   cornerRadius: cornerRadius)
        else { return }

        context.saveGState()
        // One layer for the whole mark: its opacity then applies to the
        // composite rather than to every glyph on its own.
        context.setAlpha(CGFloat(style.opacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.translateBy(x: placement.center.x, y: placement.center.y)
        // The context is flipped, where a positive angle turns clockwise.
        context.rotate(by: -CGFloat(style.rotation) * .pi / 180)
        context.scaleBy(x: placement.fit, y: placement.fit)
        draw(CGRect(x: -contentSize.width / 2, y: -contentSize.height / 2,
                    width: contentSize.width, height: contentSize.height))
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: - Finishing the export

    /// The flattened capture with the watermark drawn on it, its corners
    /// rounded, and the padded backdrop composed behind it when `fill` paints
    /// something. `outlineCorner` is the rounding the card's shadow follows:
    /// a window's own corners when they are rounder than the person's.
    static func finishedExport(_ flattened: Export,
                               watermark: ScreenshotSupport.WatermarkStyle,
                               watermarkImage: CGImage?,
                               style: ScreenshotSupport.BackdropStyle,
                               fill: BackdropFill,
                               outlineCorner: CGFloat) -> Export? {
        let imageSize = CGSize(width: flattened.image.width, height: flattened.image.height)
        let style = style.sanitized()
        let corner = ScreenshotSupport.cardCornerRadius(for: imageSize, factor: CGFloat(style.cornerRadius))
        var result = flattened.image
        if watermark.sanitized().kind != .none {
            guard let context = makeContext(width: flattened.image.width, height: flattened.image.height)
            else { return nil }
            context.draw(result, in: CGRect(origin: .zero, size: imageSize))
            // Flip to the annotations' top-left space.
            context.translateBy(x: 0, y: imageSize.height)
            context.scaleBy(x: 1, y: -1)
            drawWatermark(watermark, image: watermarkImage, in: context, imageSize: imageSize,
                          cornerRadius: corner)
            guard let marked = context.makeImage() else { return nil }
            result = marked
        }
        if case .none = fill {
            // Rounded corners without a backdrop become transparency.
            if corner > 0, let rounded = roundedAlpha(result, corner: corner) {
                result = rounded
            }
        } else if let composed = renderBackdrop(fill, behind: result, imageSize: imageSize,
                                                paddingFactor: CGFloat(style.padding),
                                                corner: corner,
                                                outlineCorner: max(corner, outlineCorner),
                                                blurFactor: CGFloat(style.blur),
                                                scale: flattened.scale) {
            result = composed
        }
        return Export(image: result, scale: flattened.scale)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func roundedAlpha(_ image: CGImage, corner: CGFloat) -> CGImage? {
        guard let context = makeContext(width: image.width, height: image.height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.clip()
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func renderBackdrop(_ fill: BackdropFill,
                                       behind image: CGImage,
                                       imageSize: CGSize,
                                       paddingFactor: CGFloat,
                                       corner: CGFloat,
                                       outlineCorner: CGFloat,
                                       blurFactor: CGFloat,
                                       scale: CGFloat) -> CGImage? {
        let padding = ScreenshotSupport.backdropPadding(for: imageSize, factor: paddingFactor)
        let width = Int(imageSize.width + padding * 2)
        let height = Int(imageSize.height + padding * 2)
        guard let context = makeContext(width: width, height: height) else { return nil }

        drawFill(fill, in: context, size: CGSize(width: width, height: height))
        if blurFactor > 0, let background = context.makeImage() {
            let blurred = blurredBackdrop(background, factor: blurFactor)
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(blurred, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let imageRect = CGRect(x: padding, y: padding, width: imageSize.width, height: imageSize.height)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 22 * scale,
                          color: CGColor(gray: 0, alpha: 0.4))
        // A window brings its own rounded corners, which the shadow follows
        // so no square of it shows past them. The picture is clipped only to
        // the person's corners, so its own edge is never shaved.
        let outline = CGPath(roundedRect: imageRect, cornerWidth: outlineCorner,
                             cornerHeight: outlineCorner, transform: nil)
        let path = CGPath(roundedRect: imageRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        // Keep the shadow outside the card without painting an opaque plate
        // behind translucent captures.
        context.addRect(CGRect(x: 0, y: 0, width: width, height: height))
        context.addPath(outline)
        context.clip(using: .evenOdd)
        context.addPath(outline)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: imageRect)
        context.restoreGState()
        return context.makeImage()
    }

    /// Blurs a finished background plate while extending its edge pixels, so
    /// the effect never creates a transparent seam around the canvas.
    static func blurredBackdrop(_ image: CGImage, factor: CGFloat) -> CGImage {
        let radius = ScreenshotSupport.backdropBlurRadius(for: CGSize(width: image.width, height: image.height),
                                                          factor: factor)
        guard radius > 0 else { return image }
        let input = CIImage(cgImage: image)
        let filtered = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        return blurContext.createCGImage(filtered, from: input.extent) ?? image
    }

    private static func drawFill(_ fill: BackdropFill, in context: CGContext, size: CGSize) {
        switch fill {
        case .none:
            break
        case .colors(let components):
            if components.count == 1, let single = components.first {
                context.setFillColor(CGColor(srgbRed: single.red, green: single.green, blue: single.blue, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
            } else if components.count >= 2 {
                let colors = components.map {
                    CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
                } as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                             colors: colors, locations: [0, 1]) {
                    context.drawLinearGradient(gradient,
                                               start: CGPoint(x: 0, y: size.height),
                                               end: CGPoint(x: size.width, y: 0),
                                               options: [])
                }
            }
        case .image(let backdropImage):
            // Aspect fill, centered, like a picture on a desktop.
            let imageWidth = CGFloat(backdropImage.width)
            let imageHeight = CGFloat(backdropImage.height)
            guard imageWidth > 0, imageHeight > 0 else { break }
            let scale = max(size.width / imageWidth, size.height / imageHeight)
            let drawSize = CGSize(width: imageWidth * scale, height: imageHeight * scale)
            let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            context.saveGState()
            context.clip(to: CGRect(origin: .zero, size: size))
            context.interpolationQuality = .high
            context.draw(backdropImage, in: CGRect(origin: origin, size: drawSize))
            context.restoreGState()
        }
    }
}
