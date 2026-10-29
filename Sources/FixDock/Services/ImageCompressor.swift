// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageCompressionError: Error, Equatable {
    case unreadable
    case unsupported
    case tooLarge
    case encodeFailed
    /// GPS was asked to go and the written file still has it. Fails closed.
    case locationRemained
}

struct ImageCompressionResult {
    let data: Data
    let type: UTType
    /// The extension to save under: the original's when the type is unchanged.
    let fileExtension: String
    let originalSize: Int64
    /// True when re-encoding did not help and the original pixels went out.
    let keptOriginal: Bool
}

/// The image engine shared by the Media tool and AirDrop auto-zip. Upstream's
/// decode, orientation and size limits, with the never-larger rule and the
/// GPS-only removal added. Blocking; callers run it off the main thread.
enum ImageCompressor {
    static func compress(_ url: URL, options: ImageCompressionOptions) throws -> ImageCompressionResult {
        let originalSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let sourceTypeID = CGImageSourceGetType(source),
              let sourceType = UTType(sourceTypeID as String),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ImageCompressionError.unreadable }
        guard !ImageCompressionSupport.isTooLarge(width: width, height: height) else {
            throw ImageCompressionError.tooLarge
        }

        let outputType = options.format.fixedType ?? sourceType
        let fileExtension = outputType == sourceType
            ? url.pathExtension
            : (outputType.preferredFilenameExtension ?? url.pathExtension)
        let target = ImageCompressionSupport.targetSize(width: width, height: height,
                                                        maxDimension: options.maxDimension)
        let unchangedGeometry = target.width == width && target.height == height

        // An animation would come out as its first frame. Unchanged, it goes
        // out as it came in.
        if CGImageSourceGetCount(source) > 1, outputType == sourceType, unchangedGeometry {
            return try passThrough(url, source: source, type: sourceType, fileExtension: fileExtension,
                                   originalSize: originalSize, options: options)
        }
        guard Self.canWrite(outputType) else { throw ImageCompressionError.unsupported }

        let quality = ImageCompressionSupport.imageIOQuality(percent: options.quality)
        let encoded: Data
        if outputType == sourceType, unchangedGeometry, options.metadata != .removeAll {
            encoded = try reencode(source: source, type: outputType, quality: quality,
                                   removeLocation: options.metadata == .removeLocation)
        } else {
            encoded = try redraw(source: source, properties: properties, type: outputType,
                                 target: target, quality: quality, metadata: options.metadata)
        }
        if options.metadata != .keep, hasLocation(encoded) {
            throw ImageCompressionError.locationRemained
        }

        // Never larger, when the person did not ask for another format.
        if outputType == sourceType, Int64(encoded.count) >= originalSize, options.metadata != .removeAll {
            return try passThrough(url, source: source, type: sourceType, fileExtension: fileExtension,
                                   originalSize: originalSize, options: options, fallback: encoded)
        }
        return ImageCompressionResult(data: encoded, type: outputType, fileExtension: fileExtension,
                                      originalSize: originalSize, keptOriginal: false)
    }

    private static func canWrite(_ type: UTType) -> Bool {
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return writable.contains(type.identifier)
    }

    /// Same type, same size: ImageIO re-encodes from the source, so the
    /// colour space, depth and orientation tag stay as they were.
    private static func reencode(source: CGImageSource, type: UTType, quality: Double,
                                 removeLocation: Bool) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { throw ImageCompressionError.encodeFailed }
        var options: [CFString: Any] = [:]
        if ImageCompressionSupport.isLossy(type) {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if removeLocation {
            options[kCGImagePropertyGPSDictionary] = kCFNull
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageCompressionError.encodeFailed }
        return data as Data
    }

    /// Resizing, converting or dropping all metadata decodes the pixels with
    /// the orientation applied, so the tag is reset to up.
    private static func redraw(source: CGImageSource, properties: [CFString: Any], type: UTType,
                               target: (width: Int, height: Int), quality: Double,
                               metadata: ImageMetadataPolicy) throws -> Data {
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height),
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary)
        else { throw ImageCompressionError.unreadable }
        if !ImageCompressionSupport.supportsAlpha(type), hasAlpha(image) {
            image = try flattenedOnWhite(image)
        }

        var output: [CFString: Any] = [:]
        if metadata != .removeAll {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyGPSDictionary] {
                if let value = properties[key] { output[key] = value }
            }
            if metadata == .removeLocation { output[kCGImagePropertyGPSDictionary] = nil }
            if var exif = output[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                output[kCGImagePropertyExifDictionary] = exif
            }
            if var tiff = output[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                output[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        output[kCGImagePropertyOrientation] = 1
        if ImageCompressionSupport.isLossy(type) {
            output[kCGImageDestinationLossyCompressionQuality] = quality
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { throw ImageCompressionError.encodeFailed }
        CGImageDestinationAddImage(destination, image, output as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageCompressionError.encodeFailed }
        return data as Data
    }

    /// The original pixels. With the location to remove, a lossless copy
    /// that leaves GPS out; failing that, `fallback` (re-encoded, larger,
    /// but without the location). Never the raw original when GPS must go.
    private static func passThrough(_ url: URL, source: CGImageSource, type: UTType, fileExtension: String,
                                    originalSize: Int64, options: ImageCompressionOptions,
                                    fallback: Data? = nil) throws -> ImageCompressionResult {
        func result(_ data: Data, kept: Bool) -> ImageCompressionResult {
            ImageCompressionResult(data: data, type: type, fileExtension: fileExtension,
                                   originalSize: originalSize, keptOriginal: kept)
        }
        switch options.metadata {
        case .keep:
            return result(try Data(contentsOf: url), kept: true)
        case .removeLocation:
            let original = try Data(contentsOf: url)
            if !hasLocation(original) { return result(original, kept: true) }
            if let copy = losslessCopyWithoutLocation(source: source, type: type), !hasLocation(copy) {
                return result(copy, kept: true)
            }
            if let fallback { return result(fallback, kept: false) }
            throw ImageCompressionError.locationRemained
        case .removeAll:
            if let fallback { return result(fallback, kept: false) }
            throw ImageCompressionError.unsupported
        }
    }

    private static func losslessCopyWithoutLocation(source: CGImageSource, type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        // Without the source's own metadata merged back in, the copy keeps
        // none of it: GPS would go, and the capture time with it.
        var copyOptions: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            copyOptions[kCGImageDestinationMetadata] = metadata
            copyOptions[kCGImageDestinationMergeMetadata] = true
        }
        let options = copyOptions as CFDictionary
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options, &error) else {
            error?.release()
            return nil
        }
        return data as Data
    }

    /// GPS in the property dictionary or as an XMP tag.
    static func hasLocation(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        for index in 0..<CGImageSourceGetCount(source) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
               let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty {
                return true
            }
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
               CGImageMetadataCopyTagMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary,
                                                           kCGImagePropertyGPSLatitude) != nil {
                return true
            }
        }
        return false
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func flattenedOnWhite(_ image: CGImage) throws -> CGImage {
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ImageCompressionError.encodeFailed }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flattened = context.makeImage() else { throw ImageCompressionError.encodeFailed }
        return flattened
    }
}

/// Writes a result without ever replacing a file: staged in a replacement
/// directory on the same volume, then moved with RENAME_EXCL, retrying the
/// next free name if one appears in between.
enum ImageOutputWriter {
    static func write(_ data: Data, into directory: URL, baseName: String, fileExtension: String) throws -> URL {
        let fileManager = FileManager.default
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: directory, create: true)
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("output")
        try data.write(to: staged)

        for _ in 0..<1_000 {
            let name = ImageCompressionSupport.uniqueName(base: baseName, extension: fileExtension) {
                fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
            let destination = directory.appendingPathComponent(name)
            let moved = staged.withUnsafeFileSystemRepresentation { from in
                destination.withUnsafeFileSystemRepresentation { to in
                    guard let from, let to else { return false }
                    return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0
                }
            }
            if moved { return destination }
            guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown) }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
