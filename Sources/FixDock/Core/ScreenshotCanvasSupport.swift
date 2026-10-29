// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics
import Foundation

/// Pure geometry for growing the canvas and for pasted image layers: the
/// grown canvas rectangle, the bitmap it becomes, where marks land on it,
/// and how a layer is placed, picked up and resized. No AppKit. Adapted from
/// upstream's `ScreenshotCanvasSupport`.
enum ScreenshotCanvasSupport {
    /// What fills the space a canvas expansion adds.
    enum Fill: Equatable {
        case transparent
        case color(red: Double, green: Double, blue: Double)
        static let white = Fill.color(red: 1, green: 1, blue: 1)

        var cgColor: CGColor {
            switch self {
            case .transparent: return CGColor(gray: 0, alpha: 0)
            case let .color(red, green, blue):
                return CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            }
        }
    }

    /// The largest canvas, in pixels, an expansion or a pasted image may
    /// make: upstream's scrolling-capture ceiling.
    static let maximumPixels: CGFloat = 60_000_000

    static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width >= 1 && size.height >= 1
            && size.width == size.width.rounded() && size.height == size.height.rounded()
            && size.width <= maximumPixels && size.height <= maximumPixels
            && size.width <= maximumPixels / size.height
    }

    /// The grown canvas after dragging `handle` to `point`, in the old
    /// canvas's pixels: it only ever grows, by whole pixels, and contains the
    /// old canvas. Nil past the size limit.
    static func expandedRect(size: CGSize, handle: ScreenshotSupport.Handle,
                             point: CGPoint) -> CGRect? {
        guard validSize(size), point.x.isFinite, point.y.isFinite else { return nil }
        var x: CGFloat = 0, y: CGFloat = 0
        var right = size.width, bottom = size.height
        switch handle {
        case .topLeft: x = min(0, point.x.rounded()); y = min(0, point.y.rounded())
        case .top: y = min(0, point.y.rounded())
        case .topRight: right = max(right, point.x.rounded()); y = min(0, point.y.rounded())
        case .right: right = max(right, point.x.rounded())
        case .bottomRight: right = max(right, point.x.rounded()); bottom = max(bottom, point.y.rounded())
        case .bottom: bottom = max(bottom, point.y.rounded())
        case .bottomLeft: x = min(0, point.x.rounded()); bottom = max(bottom, point.y.rounded())
        case .left: x = min(0, point.x.rounded())
        }
        let rect = CGRect(x: x, y: y, width: right - x, height: bottom - y)
        return validSize(rect.size) ? rect : nil
    }

    /// The capture copied pixel for pixel into the grown canvas, the new
    /// space filled with `fill`.
    static func expandedImage(_ image: CGImage, to rect: CGRect, fill: Fill) -> CGImage? {
        let old = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard validSize(rect.size), rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.minX == rect.minX.rounded(), rect.minY == rect.minY.rounded(),
              rect.contains(old),
              let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(fill.cgColor)
        context.fill(CGRect(origin: .zero, size: rect.size))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        let destination = CGRect(x: -rect.minX, y: rect.height + rect.minY - old.height,
                                 width: old.width, height: old.height)
        context.draw(image, in: destination)
        return context.makeImage()
    }

    /// Marks keep their place on the capture when the canvas grows: the
    /// grown canvas's origin is `rect.origin` in the old space, so every mark
    /// moves by its negative. A spotlight region lights only its part on the
    /// old capture: past the old edge it would light the new margin, and one
    /// with nothing on the capture goes. Counters and blur areas keep the
    /// size they were drawn for, so a badge or a mosaic does not grow with
    /// the canvas. Adapted from upstream's `commitCanvasExpansion`.
    static func shifted(_ annotations: [ScreenshotSupport.Annotation],
                        into rect: CGRect, from oldSize: CGSize) -> [ScreenshotSupport.Annotation] {
        let oldBounds = CGRect(origin: .zero, size: oldSize)
        return annotations.compactMap { annotation in
            var moved = annotation
            if moved.tool == .spotlight {
                let lit = moved.rect.standardized.intersection(oldBounds)
                guard !lit.isEmpty else { return nil }
                moved.rect = lit
            }
            moved.rect = moved.rect.offsetBy(dx: -rect.minX, dy: -rect.minY)
            moved.points = moved.points.map { CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY) }
            if moved.tool == .counter || moved.tool == .pixelate {
                moved.renderReferenceSize = moved.renderReferenceSize ?? oldSize
            }
            return moved
        }
    }

    /// How close to an expansion grip, in points on screen, a press picks it
    /// up. The grips sit centered on the capture's edge, so the editor takes
    /// presses this far outside the canvas too.
    static let expansionGripReach: CGFloat = 10

    static func expansionHandle(at point: CGPoint, rect: CGRect,
                                tolerance: CGFloat) -> ScreenshotSupport.Handle? {
        nearestHandle(at: point, rect: rect, tolerance: tolerance)
    }

    // MARK: - Image layers

    /// Centered on whole pixels: a layer drawn off the pixel grid is
    /// resampled, and a pasted screenshot's text would export blurred. A
    /// picture larger than the canvas shrinks to fit it.
    static func fittedImageRect(_ image: CGImage, canvas: CGSize) -> CGRect {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let factor = min(1, min(canvas.width / width, canvas.height / height))
        let size = CGSize(width: width * factor, height: height * factor)
        return CGRect(x: ((canvas.width - size.width) / 2).rounded(.down),
                      y: ((canvas.height - size.height) / 2).rounded(.down),
                      width: size.width, height: size.height)
    }

    /// Edge grips stretch one side; corner grips keep the picture's
    /// proportions, anchored at the opposite corner. Never below a pixel.
    static func resizedImageRect(_ rect: CGRect, handle: ScreenshotSupport.Handle,
                                 point: CGPoint) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return rect }
        switch handle {
        case .left:
            return CGRect(x: min(point.x, rect.maxX - 1), y: rect.minY,
                          width: max(1, rect.maxX - point.x), height: rect.height)
        case .right:
            return CGRect(x: rect.minX, y: rect.minY,
                          width: max(1, point.x - rect.minX), height: rect.height)
        case .top:
            return CGRect(x: rect.minX, y: min(point.y, rect.maxY - 1),
                          width: rect.width, height: max(1, rect.maxY - point.y))
        case .bottom:
            return CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width, height: max(1, point.y - rect.minY))
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            break
        }
        let left = handle == .topLeft || handle == .bottomLeft
        let top = handle == .topLeft || handle == .topRight
        let anchor = CGPoint(x: left ? rect.maxX : rect.minX, y: top ? rect.maxY : rect.minY)
        let dx = (left ? -1 : 1) * (point.x - anchor.x)
        let dy = (top ? -1 : 1) * (point.y - anchor.y)
        let ratio = rect.width / rect.height
        let width = max(1, max(dx, dy * ratio))
        let height = width / ratio
        return CGRect(x: left ? anchor.x - width : anchor.x,
                      y: top ? anchor.y - height : anchor.y, width: width, height: height)
    }

    /// The layer moved by `delta`, on whole pixels so it still exports pixel
    /// for pixel.
    static func movedImageRect(_ rect: CGRect, by delta: CGPoint) -> CGRect {
        CGRect(origin: CGPoint(x: (rect.minX + delta.x).rounded(), y: (rect.minY + delta.y).rounded()),
               size: rect.size)
    }

    static func imageHandle(at point: CGPoint, rect: CGRect,
                            tolerance: CGFloat) -> ScreenshotSupport.Handle? {
        nearestHandle(at: point, rect: rect, tolerance: tolerance)
    }

    /// The grip nearest `point` within reach. The reach shrinks on a small
    /// rectangle so its grips never overlap.
    private static func nearestHandle(at point: CGPoint, rect: CGRect,
                                      tolerance: CGFloat) -> ScreenshotSupport.Handle? {
        let radius = min(tolerance, max(2, min(rect.width, rect.height) / 4))
        return ScreenshotSupport.Handle.allCases.filter {
            let position = $0.position(in: rect)
            return abs(position.x - point.x) <= radius && abs(position.y - point.y) <= radius
        }.min {
            let a = $0.position(in: rect), b = $1.position(in: rect)
            return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
        }
    }
}

extension ScreenshotSupport {
    /// Immutable pixels shared by image annotations and undo snapshots;
    /// equal only to itself, so comparing marks never compares pixels.
    final class ImageAsset: Equatable {
        let image: CGImage
        init(image: CGImage) { self.image = image }
        static func == (lhs: ImageAsset, rhs: ImageAsset) -> Bool { lhs === rhs }
    }
}
