// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation
import UniformTypeIdentifiers

/// How hard an image is compressed: low keeps the most detail, high makes
/// the smallest file. The numbers are the owner's web compressor's levels
/// (its 90/75/50), so a photo comes out close to the way it did there.
enum CompressionPreset: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    static let defaultPreset = CompressionPreset.medium

    /// ImageIO quality percent.
    var percent: Double {
        switch self {
        case .low: return 90
        case .medium: return 75
        case .high: return 50
        }
    }

    static func from(_ rawValue: String?) -> CompressionPreset {
        rawValue.flatMap(CompressionPreset.init(rawValue:)) ?? defaultPreset
    }
}

/// What a finished job hands back: one zip (default) or the files themselves.
enum MediaOutputMode: String, CaseIterable, Identifiable {
    case zip, files

    var id: String { rawValue }

    static func from(_ rawValue: String?) -> MediaOutputMode {
        rawValue.flatMap(MediaOutputMode.init(rawValue:)) ?? .zip
    }
}

/// The file type an image is written as.
enum ImageOutputFormat: String, CaseIterable, Identifiable {
    case original, jpeg, png, heic

    var id: String { rawValue }

    var fixedType: UTType? {
        switch self {
        case .original: return nil
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        }
    }

    static func from(_ rawValue: String?) -> ImageOutputFormat {
        rawValue.flatMap(ImageOutputFormat.init(rawValue:)) ?? .original
    }
}

/// What happens to EXIF, GPS and the other metadata.
enum ImageMetadataPolicy: String, CaseIterable, Identifiable {
    case keep
    /// Default: capture time and orientation stay, the location goes.
    case removeLocation
    case removeAll

    var id: String { rawValue }

    static func from(_ rawValue: String?) -> ImageMetadataPolicy {
        rawValue.flatMap(ImageMetadataPolicy.init(rawValue:)) ?? .removeLocation
    }
}

/// One compression request, the same for the Media tool and AirDrop auto-zip.
struct ImageCompressionOptions: Equatable {
    var quality: Double
    var format: ImageOutputFormat
    /// Longest edge in pixels; nil keeps the original size.
    var maxDimension: Int?
    var metadata: ImageMetadataPolicy

    static let maxDimensionRange = 320...16_000

    static func sanitizedMaxDimension(_ value: Int) -> Int? {
        guard value > 0 else { return nil }
        return min(max(value, maxDimensionRange.lowerBound), maxDimensionRange.upperBound)
    }
}

/// The pure half of the image engine: decisions that do not touch a file.
enum ImageCompressionSupport {
    /// Upstream's limits: one edge, and the whole decode.
    static let maxEdge = 20_000
    static let maxPixels = 8_192 * 8_192

    /// 0.1…1.0 for ImageIO.
    static func imageIOQuality(percent: Double) -> Double {
        min(max(percent / 100, 0.1), 1.0)
    }

    /// Lossless types ignore the quality setting.
    static func isLossy(_ type: UTType) -> Bool {
        !(type.conforms(to: .png) || type.conforms(to: .tiff) || type.conforms(to: .bmp))
    }

    static func supportsAlpha(_ type: UTType) -> Bool {
        !type.conforms(to: .jpeg)
    }

    /// The pixel size after `maxDimension`, never larger than the original.
    static func targetSize(width: Int, height: Int, maxDimension: Int?) -> (width: Int, height: Int) {
        guard let maxDimension, max(width, height) > maxDimension, width > 0, height > 0 else {
            return (width, height)
        }
        let scale = Double(maxDimension) / Double(max(width, height))
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }

    static func isTooLarge(width: Int, height: Int) -> Bool {
        width > maxEdge || height > maxEdge || width * height > maxPixels
    }

    /// `name-compressed.ext` for the Media tool's output next to the original.
    static func outputBaseName(for original: URL) -> String {
        let base = original.deletingPathExtension().lastPathComponent
        return (base.isEmpty ? "image" : base) + "-compressed"
    }

    /// `name.ext`, then `name 2.ext`, `name 3.ext`… the first that `exists`
    /// says is free. The caller still moves with RENAME_EXCL, so a file that
    /// appears in between is never overwritten.
    static func uniqueName(base: String, extension ext: String, exists: (String) -> Bool) -> String {
        func name(_ index: Int) -> String {
            let stem = index == 1 ? base : "\(base) \(index)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        var index = 1
        while exists(name(index)) { index += 1 }
        return name(index)
    }

    /// `compressed_images_YYYY-MM-DD`, in the local calendar the person sees.
    static func zipBaseName(date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "compressed_images_%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func savedPercent(original: Int64, output: Int64) -> Double {
        guard original > 0 else { return 0 }
        return Double(original - output) / Double(original) * 100
    }
}
