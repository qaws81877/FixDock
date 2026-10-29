// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Draws annotations into a CGContext. The editor canvas and the exporter
/// share this code, so what is on screen is exactly what leaves the app.
/// All geometry is in image pixels with a top-left origin; `scale` is the
/// capture's pixels per point, keeping stroke weights and text sizes visually
/// constant across 1x and Retina captures. Adapted from the upstream
/// renderer, without the blur, backdrop and watermark passes of later stages.
enum ScreenshotRenderer {
    static func color(_ id: ScreenshotSupport.ColorID, alpha: CGFloat = 1) -> CGColor {
        let c = id.components
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: alpha)
    }

    static func nsColor(_ id: ScreenshotSupport.ColorID) -> NSColor {
        let c = id.components
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    static func fontSize(for textSize: Int, scale: CGFloat) -> CGFloat {
        CGFloat(textSize) * scale
    }

    /// Measures a text annotation's box for hit-testing and the inline editor.
    static func textBounds(_ text: String, at origin: CGPoint, textSize: Int, scale: CGFloat) -> CGRect {
        let font = NSFont.systemFont(ofSize: fontSize(for: textSize, scale: scale), weight: .semibold)
        let measured = (text.isEmpty ? " " : text).size(withAttributes: [.font: font])
        return CGRect(origin: origin,
                      size: CGSize(width: ceil(measured.width) + 4, height: ceil(measured.height)))
    }

    // MARK: - Annotation pass

    /// Draws every annotation over the base content, in array order. Text
    /// being edited inline is skipped so the live field is the only visible
    /// copy.
    static func drawAnnotations(_ annotations: [ScreenshotSupport.Annotation],
                                in context: CGContext,
                                scale: CGFloat,
                                skippingText editingID: UUID? = nil) {
        for annotation in annotations {
            switch annotation.tool {
            case .rect:
                strokeShape(in: context, annotation: annotation, scale: scale) {
                    context.stroke(annotation.rect)
                }
            case .ellipse:
                strokeShape(in: context, annotation: annotation, scale: scale) {
                    context.strokeEllipse(in: annotation.rect)
                }
            case .line:
                drawLine(annotation, in: context, scale: scale)
            case .arrow:
                drawArrow(annotation, in: context, scale: scale)
            case .freehand:
                drawFreehand(annotation, in: context, scale: scale)
            case .text:
                if annotation.id != editingID {
                    drawText(annotation, in: context, scale: scale)
                }
            case .select:
                break
            }
        }
    }

    private static func strokeShape(in context: CGContext,
                                    annotation: ScreenshotSupport.Annotation,
                                    scale: CGFloat,
                                    stroke: () -> Void) {
        context.saveGState()
        context.setStrokeColor(color(annotation.color))
        context.setLineWidth(annotation.stroke.width * scale)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        stroke()
        context.restoreGState()
    }

    private static func drawLine(_ annotation: ScreenshotSupport.Annotation,
                                 in context: CGContext, scale: CGFloat) {
        guard annotation.points.count >= 2 else { return }
        context.saveGState()
        context.setStrokeColor(color(annotation.color))
        context.setLineWidth(annotation.stroke.width * scale)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: annotation.points[0])
        context.addLine(to: annotation.points[1])
        context.strokePath()
        context.restoreGState()
    }

    /// The filled arrow: one silhouette for shaft, round tail and head.
    private static func drawArrow(_ annotation: ScreenshotSupport.Annotation,
                                  in context: CGContext, scale: CGFloat) {
        guard annotation.points.count >= 2 else { return }
        context.saveGState()
        context.setFillColor(color(annotation.color))
        context.addPath(ScreenshotSupport.arrowSilhouette(from: annotation.points[0],
                                                          to: annotation.points[1],
                                                          strokeWidth: annotation.stroke.width * scale))
        context.fillPath()
        context.restoreGState()
    }

    private static func drawFreehand(_ annotation: ScreenshotSupport.Annotation,
                                     in context: CGContext, scale: CGFloat) {
        guard annotation.points.count > 1 else { return }
        context.saveGState()
        context.setStrokeColor(color(annotation.color))
        context.setLineWidth(annotation.stroke.width * scale)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: annotation.points[0])
        // Quadratic curves through midpoints smooth hand jitter without
        // drifting from the stroke.
        for index in 1..<annotation.points.count {
            let current = annotation.points[index]
            let previous = annotation.points[index - 1]
            let mid = CGPoint(x: (current.x + previous.x) / 2, y: (current.y + previous.y) / 2)
            context.addQuadCurve(to: mid, control: previous)
        }
        if let last = annotation.points.last {
            context.addLine(to: last)
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func drawText(_ annotation: ScreenshotSupport.Annotation,
                                 in context: CGContext, scale: CGFloat) {
        guard !annotation.text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: fontSize(for: annotation.textSize, scale: scale),
                                     weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: nsColor(annotation.color),
        ]
        context.saveGState()
        // NSAttributedString draws in an unflipped space; flip locally.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        annotation.text.draw(at: CGPoint(x: annotation.rect.minX + 2, y: annotation.rect.minY),
                             withAttributes: attributes)
        NSGraphicsContext.current = previous
        context.restoreGState()
    }

    // MARK: - Export

    /// A finished picture together with the pixels per point it was rendered
    /// at, so every file and pasteboard item it becomes can say how big it is
    /// on screen: a Retina capture then opens at its own size in Preview.
    struct Export {
        let image: CGImage
        let scale: CGFloat
    }

    /// The base image with the annotations flattened on top, at the capture's
    /// full resolution.
    static func renderExport(baseImage: CGImage,
                             annotations: [ScreenshotSupport.Annotation],
                             scale: CGFloat) -> Export? {
        let width = baseImage.width
        let height = baseImage.height
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)
                                          ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Flip to the annotations' top-left space.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        drawAnnotations(annotations, in: context, scale: scale)
        guard let image = context.makeImage() else { return nil }
        return Export(image: image, scale: scale)
    }

    // MARK: - Encoding

    /// PNG carrying the picture's pixels per point as standard DPI, the same
    /// convention the system screenshot tool writes.
    static func pngData(from image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        let properties = [
            kCGImagePropertyDPIWidth: Double(scale) * 72,
            kCGImagePropertyDPIHeight: Double(scale) * 72,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
