// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics
import Foundation
import ImageIO

/// Turns an overlay's picture into the pixels a frame composites, once.
///
/// The same bargain the caption renderer makes: the file is read and resized
/// while the plan is built, so every frame after that is a composite of a
/// texture already at the size it is drawn. Sizes repeat as soon as anything
/// else about the edit changes, which is what the cache is for; it is held to
/// a budget in pixels rather than in entries, because one mark covering most
/// of a 4K frame is worth as much memory as a hundred captions.
enum RecorderImageRenderer {

    private static let pixelBudget = 24_000_000

    private static var cache: [String: CGImage] = [:]
    private static var cachedPixels = 0
    private static let lock = NSLock()

    static func image(for overlay: RecorderImageOverlay, canvas: CGSize) -> CGImage? {
        let url = URL(fileURLWithPath: overlay.path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey,
                                                             .fileSizeKey,
                                                             .contentModificationDateKey]),
              values.isRegularFile == true,
              let source = RecorderImageFiles.imageDisplaySize(at: url),
              let drawn = RecorderImageOverlay.drawnSize(source: source,
                                                         size: overlay.size,
                                                         canvas: canvas),
              RecorderImageFiles.imageRenderSizeIsSafe(drawn)
        else { return nil }

        // The file's own size and date are part of the key: a logo replaced on
        // disk while the editor is open is a different picture, not the same
        // one at the same size.
        let stamp = "\(values.fileSize ?? 0)|"
            + "\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        let key = "\(overlay.path)|\(Int(drawn.width))x\(Int(drawn.height))|\(stamp)"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let image = render(overlay.path, drawn: drawn) else { return nil }
        lock.lock()
        if cachedPixels > pixelBudget {
            cache.removeAll()
            cachedPixels = 0
        }
        cache[key] = image
        cachedPixels += image.width * image.height
        lock.unlock()
        return image
    }

    /// Decoded no larger than it is drawn, then drawn at exactly that size, so
    /// a photograph never arrives at full resolution and a small logo asked to
    /// fill half the frame is still resampled smoothly instead of blocking up.
    private static func render(_ path: String, drawn: CGSize) -> CGImage? {
        let width = Int(drawn.width)
        let height = Int(drawn.height)
        guard let picture = RecorderImageFiles.imageThumbnail(at: URL(fileURLWithPath: path),
                                                        maxPixel: max(width, height)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(picture, in: CGRect(origin: .zero, size: drawn))
        return context.makeImage()
    }
}

/// Upstream's `MediaSupport` image helpers the renderer uses, kept here
/// because FixDock's media tool has no such type.
enum RecorderImageFiles {
    static let maxImageRenderDimension = 20_000
    static let maxImageRenderPixels = 8_192 * 8_192

    static func imageDisplaySize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return nil }
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0,
              width < Double(Int.max), height < Double(Int.max) else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size = 5...8 ~= orientation
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        return CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
    }

    static func imageThumbnail(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ] as CFDictionary)
    }

    static func imageRenderSizeIsSafe(_ size: CGSize) -> Bool {
        let width = abs(size.width)
        let height = abs(size.height)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= CGFloat(maxImageRenderDimension),
              height <= CGFloat(maxImageRenderDimension) else { return false }
        return width * height <= CGFloat(maxImageRenderPixels)
    }
}
