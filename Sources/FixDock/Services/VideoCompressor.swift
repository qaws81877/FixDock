// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AVFoundation
import CoreMedia
import Foundation

enum VideoCompressionError: Error, Equatable {
    case noVideoTrack
    case unsupported
    case targetTooSmall
    case cancelled
    case failed
}

/// Video compression for the Media tool, adapted from upstream's
/// MediaService and MediaVideoTargetEncoder. The resolution mode drives
/// `/usr/bin/avconvert`, whose metadata filter keeps location and other
/// private metadata out of the result; the file-size mode reads into an
/// AVAssetWriter, which copies no source metadata at all. Both write MP4.
/// Blocking; callers run it off the main thread.
enum VideoCompressor {
    struct Source {
        let asset: AVAsset
        let videoTrack: AVAssetTrack
        let audioTracks: [AVAssetTrack]
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let frameRate: Double
        let duration: Double
    }

    static func compress(_ url: URL, sizing: VideoSizing, to destination: URL,
                         isCancelled: @escaping () -> Bool,
                         progress: @escaping (Double) -> Void) throws {
        let source = try load(url)
        guard source.duration > 0 else { throw VideoCompressionError.unsupported }
        switch sizing {
        case .resolution(let level):
            try runAVConvert(url, preset: VideoCompressionSupport.avconvertPreset(level),
                             duration: source.duration, to: destination,
                             isCancelled: isCancelled, progress: progress)
        case .fileSize(let bytes):
            try encode(source, targetBytes: bytes, to: destination,
                       isCancelled: isCancelled, progress: progress)
        }
    }

    // MARK: - Source

    private static func load(_ url: URL) throws -> Source {
        let asset = AVURLAsset(url: url)
        let result = blocking { () async throws -> Source in
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoCompressionError.noVideoTrack
            }
            return Source(asset: asset,
                          videoTrack: track,
                          audioTracks: try await asset.loadTracks(withMediaType: .audio),
                          naturalSize: try await track.load(.naturalSize),
                          preferredTransform: try await track.load(.preferredTransform),
                          frameRate: Double(try await track.load(.nominalFrameRate)),
                          duration: try await asset.load(.duration).seconds)
        }
        switch result {
        case .success(let source): return source
        case .failure(let error as VideoCompressionError): throw error
        case .failure: throw VideoCompressionError.unsupported
        }
    }

    /// Runs async AVFoundation loading from the media queue.
    private static func blocking<T>(_ work: @escaping () async throws -> T) -> Result<T, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do { box.value = .success(try await work()) } catch { box.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? .failure(VideoCompressionError.failed)
    }

    // MARK: - Resolution mode

    private static func runAVConvert(_ url: URL, preset: String, duration: Double, to destination: URL,
                                     isCancelled: () -> Bool, progress: (Double) -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/avconvert")
        process.arguments = ["--source", url.path, "--preset", preset,
                             "--output", destination.path, "--replace"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw VideoCompressionError.failed }
        let started = Date()
        while process.isRunning {
            if isCancelled() {
                process.terminate()
                process.waitUntilExit()
                try? FileManager.default.removeItem(at: destination)
                throw VideoCompressionError.cancelled
            }
            progress(VideoCompressionSupport.estimatedProgress(elapsed: Date().timeIntervalSince(started),
                                                               duration: duration))
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw VideoCompressionError.failed
        }
    }

    // MARK: - File-size mode

    /// Up to three passes; each one that overshoots hands the next a smaller
    /// scale. Throws `targetTooSmall` rather than leave a file over the size.
    private static func encode(_ source: Source, targetBytes: Int64, to destination: URL,
                               isCancelled: () -> Bool, progress: (Double) -> Void) throws {
        var scale = 1.0
        for pass in 0..<VideoCompressionSupport.maximumTargetPasses {
            guard let plan = VideoCompressionSupport.sizePlan(targetBytes: targetBytes,
                                                              duration: source.duration,
                                                              sourceSize: source.naturalSize,
                                                              frameRate: source.frameRate,
                                                              hasAudio: !source.audioTracks.isEmpty,
                                                              scale: scale)
            else { throw VideoCompressionError.targetTooSmall }
            try runPass(source, plan: plan, to: destination, isCancelled: isCancelled, progress: progress)
            let bytes = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if bytes <= targetBytes { return }
            guard pass + 1 < VideoCompressionSupport.maximumTargetPasses,
                  let next = VideoCompressionSupport.retryScale(current: scale, actualBytes: bytes,
                                                                targetBytes: targetBytes)
            else { break }
            scale = next
        }
        try? FileManager.default.removeItem(at: destination)
        throw VideoCompressionError.targetTooSmall
    }

    private static func runPass(_ source: Source, plan: VideoSizePlan, to destination: URL,
                                isCancelled: () -> Bool, progress: (Double) -> Void) throws {
        try? FileManager.default.removeItem(at: destination)
        guard let reader = try? AVAssetReader(asset: source.asset),
              let writer = try? AVAssetWriter(outputURL: destination, fileType: .mp4)
        else { throw VideoCompressionError.unsupported }
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: source.videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoCompressionError.unsupported }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !source.audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: source.audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(plan.size.width),
            AVVideoHeightKey: Int(plan.size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: Int(VideoCompressionSupport.sanitizedFPS(source.frameRate)),
                AVVideoMaxKeyFrameIntervalDurationKey: 4,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw VideoCompressionError.unsupported
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        // Frames stay at their natural orientation; the rotation travels as
        // metadata, so a portrait source stays portrait.
        videoInput.transform = source.preferredTransform
        guard writer.canAdd(videoInput) else { throw VideoCompressionError.unsupported }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: plan.audioBitRate,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading(), writer.startWriting() else { throw VideoCompressionError.failed }
        writer.startSession(atSourceTime: .zero)

        let expectedFrames = max(1, Int((source.duration * max(1, source.frameRate)).rounded()))
        var appendedFrames = 0
        var pendingVideo = videoOutput.copyNextSampleBuffer()
        var pendingAudio = audioOutput?.copyNextSampleBuffer()

        // Whichever track holds the earlier sample is drained first, and a
        // sample goes to whichever input can take one, so neither input waits
        // on the other.
        while pendingVideo != nil || pendingAudio != nil {
            if isCancelled() {
                reader.cancelReading()
                writer.cancelWriting()
                throw VideoCompressionError.cancelled
            }
            let videoTime = pendingVideo.map { CMSampleBufferGetPresentationTimeStamp($0) }
            let audioTime = pendingAudio.map { CMSampleBufferGetPresentationTimeStamp($0) }
            let prefersVideo: Bool
            switch (videoTime, audioTime) {
            case let (video?, audio?): prefersVideo = video <= audio
            case (_?, nil): prefersVideo = true
            default: prefersVideo = false
            }
            let takesVideo = pendingVideo != nil && videoInput.isReadyForMoreMediaData
            let takesAudio = pendingAudio != nil && audioInput?.isReadyForMoreMediaData == true

            if takesVideo, prefersVideo || !takesAudio, let buffer = pendingVideo {
                guard videoInput.append(buffer) else { throw VideoCompressionError.failed }
                appendedFrames += 1
                progress(min(0.99, Double(appendedFrames) / Double(expectedFrames)))
                pendingVideo = videoOutput.copyNextSampleBuffer()
            } else if takesAudio, let input = audioInput, let buffer = pendingAudio {
                guard input.append(buffer) else { throw VideoCompressionError.failed }
                pendingAudio = audioOutput?.copyNextSampleBuffer()
            } else if pendingAudio != nil, audioInput == nil {
                pendingAudio = nil
            } else {
                guard writer.status == .writing else { throw VideoCompressionError.failed }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        guard reader.status != .failed else {
            writer.cancelWriting()
            throw VideoCompressionError.failed
        }
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        while semaphore.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if isCancelled() {
                writer.cancelWriting()
                throw VideoCompressionError.cancelled
            }
        }
        guard writer.status == .completed else { throw VideoCompressionError.failed }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}
