// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics
import Foundation

/// Which tool the Media page shows.
enum MediaTool: String, CaseIterable, Identifiable {
    case image, video

    var id: String { rawValue }

    static func from(_ rawValue: String?) -> MediaTool {
        rawValue.flatMap(MediaTool.init(rawValue:)) ?? .image
    }
}

/// How a video is shrunk: by picking its resolution, or by picking its size.
enum VideoSizingMode: String, CaseIterable, Identifiable {
    case resolution, fileSize

    var id: String { rawValue }

    static func from(_ rawValue: String?) -> VideoSizingMode {
        rawValue.flatMap(VideoSizingMode.init(rawValue:)) ?? .resolution
    }
}

enum VideoSizing: Equatable {
    case resolution(CompressionPreset)
    case fileSize(bytes: Int64)
}

struct VideoSizePlan: Equatable {
    let size: CGSize
    let videoBitRate: Int
    let audioBitRate: Int
}

/// The pure half of video compression, adapted from upstream's MediaSupport.
enum VideoCompressionSupport {
    static let targetMegabytesRange = 1...512
    static let defaultTargetMegabytes = 25
    static let minimumTargetVideoBitRate = 240_000
    static let maximumTargetPasses = 3
    /// Muxer overhead plus what rate control overshoots by.
    static let targetSizeHeadroom = 0.94
    /// Bits a pixel needs before H.264 starts smearing detail.
    private static let targetBitsPerPixel = 0.07

    /// The `avconvert` preset for a level: low compression keeps up to 1080p,
    /// medium 720p, high 540p. The presets never upscale a smaller source.
    static func avconvertPreset(_ level: CompressionPreset) -> String {
        switch level {
        case .low: return "Preset1920x1080"
        case .medium: return "Preset1280x720"
        case .high: return "Preset960x540"
        }
    }

    static func sanitizedTargetMegabytes(_ value: Int) -> Int {
        min(max(value, targetMegabytesRange.lowerBound), targetMegabytesRange.upperBound)
    }

    /// 1000-based, the way a sharing limit is written and Finder reports size.
    static func targetBytes(megabytes: Int) -> Int64 {
        Int64(sanitizedTargetMegabytes(megabytes)) * 1_000_000
    }

    static func sanitizedFPS(_ value: Double, fallback: Double = 30, maxFPS: Double = 60) -> Double {
        guard value.isFinite, value > 0 else { return fallback }
        return min(maxFPS, max(1, value.rounded()))
    }

    /// A file size is a bitrate times a duration, so a target size is a
    /// bitrate budget, which then decides how many pixels are worth keeping.
    static func sizePlan(targetBytes: Int64, duration: Double, sourceSize: CGSize,
                         frameRate: Double, hasAudio: Bool, scale: Double = 1) -> VideoSizePlan? {
        guard targetBytes > 0, duration.isFinite, duration > 0,
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0,
              scale.isFinite, scale > 0
        else { return nil }

        let fps = sanitizedFPS(frameRate)
        let audio = hasAudio ? audioBitRate(targetBytes: targetBytes, duration: duration) : 0
        let budget = Int((Double(targetBytes) * 8 * targetSizeHeadroom / duration).rounded(.down)) - audio
        let video = Int(Double(budget) * min(1, scale))
        guard video >= minimumTargetVideoBitRate else { return nil }

        let affordablePixels = Double(video) / (fps * targetBitsPerPixel)
        let sourcePixels = Double(sourceSize.width) * Double(sourceSize.height)
        let longestEdge = Double(max(sourceSize.width, sourceSize.height))
        let ratio = min(1, (affordablePixels / sourcePixels).squareRoot())
        // A tiny frame is worse than a soft one: scaling stops at 480.
        let floorRatio = min(1, 480 / longestEdge)
        let maxDimension = Int((longestEdge * max(ratio, floorRatio)).rounded())
        return VideoSizePlan(size: scaledEvenSize(source: sourceSize, maxDimension: maxDimension),
                             videoBitRate: video, audioBitRate: audio)
    }

    static func audioBitRate(targetBytes: Int64, duration: Double) -> Int {
        guard duration.isFinite, duration > 0, targetBytes > 0 else { return 128_000 }
        return Double(targetBytes) * 8 / duration < 1_200_000 ? 64_000 : 128_000
    }

    /// A pass that overshoots derives the next scale from what it produced,
    /// giving up at least a tenth so the passes converge.
    static func retryScale(current: Double, actualBytes: Int64, targetBytes: Int64) -> Double? {
        guard current.isFinite, current > 0, actualBytes > targetBytes, targetBytes > 0 else { return nil }
        let next = current * Double(targetBytes) / Double(actualBytes) * targetSizeHeadroom
        guard next.isFinite, next > 0 else { return nil }
        return min(current * 0.9, next)
    }

    static func scaledEvenSize(source: CGSize, maxDimension: Int) -> CGSize {
        let width = max(1, abs(source.width))
        let height = max(1, abs(source.height))
        let scale = min(1, CGFloat(max(2, maxDimension)) / max(width, height))
        return CGSize(width: CGFloat(even(max(2, Int((width * scale).rounded())))),
                      height: CGFloat(even(max(2, Int((height * scale).rounded())))))
    }

    private static func even(_ value: Int) -> Int { value - value % 2 }

    /// `avconvert` reports no fraction, so the resolution mode estimates one
    /// from the elapsed time and holds short of done.
    static func estimatedProgress(elapsed: TimeInterval, duration: Double) -> Double {
        min(0.95, elapsed / max(1, duration * 0.75))
    }
}
