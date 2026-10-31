// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Frames of one display region from a running `SCStream`, for scrolling
/// capture. Only frames where the screen changed arrive, and only the newest
/// is kept: frames that come while the stitcher is busy replace each other,
/// so it always works on the latest picture and never falls behind.
final class RegionStream: NSObject, @unchecked Sendable {
    enum Next {
        case frame(CGImage)
        /// Nothing changed within the timeout.
        case idle
        /// The stream ended (stopped, or failed).
        case stopped
    }

    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let queue = DispatchQueue(label: "io.github.qaws81877.fixdock.scrolling.stream", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var latest: CVPixelBuffer?
    private var waiter: CheckedContinuation<Next, Never>?
    private var waiterID = 0
    private var ended = false

    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        self.filter = filter
        self.configuration = configuration
    }

    func start() async -> Bool {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            lock.withLock { self.stream = stream }
            try await stream.startCapture()
            return true
        } catch {
            finish()
            return false
        }
    }

    func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            let stream = self.stream
            self.stream = nil
            return stream
        }
        if let stream { try? await stream.stopCapture() }
        finish()
    }

    /// The newest changed frame, waiting up to `timeout` seconds for one.
    func next(timeout: TimeInterval) async -> Next {
        let (taken, isEnded) = lock.withLock { () -> (CVPixelBuffer?, Bool) in
            let buffer = latest
            latest = nil
            return (buffer, ended)
        }
        if let taken { return Self.image(from: taken).map(Next.frame) ?? .idle }
        if isEnded { return .stopped }
        guard timeout > 0 else { return .idle }
        let next = await withCheckedContinuation { (continuation: CheckedContinuation<Next, Never>) in
            let id = lock.withLock { () -> Int in
                waiterID += 1
                waiter = continuation
                return waiterID
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resumeWaiter(id: id, with: .idle)
            }
        }
        if case .stopped = next { return .stopped }
        if case .idle = next {
            // A frame may have arrived and been kept as latest after the
            // waiter was installed; take it instead of reporting idle.
            let buffer = lock.withLock { () -> CVPixelBuffer? in
                let buffer = latest
                latest = nil
                return buffer
            }
            if let buffer { return Self.image(from: buffer).map(Next.frame) ?? .idle }
        }
        return next
    }

    private func resumeWaiter(id: Int?, with next: Next) {
        let continuation = lock.withLock { () -> CheckedContinuation<Next, Never>? in
            guard let waiter, id == nil || id == waiterID else { return nil }
            self.waiter = nil
            return waiter
        }
        continuation?.resume(returning: next)
    }

    private func finish() {
        lock.withLock {
            ended = true
            latest = nil
        }
        resumeWaiter(id: nil, with: .stopped)
    }

    /// An image that owns its pixels: the stream reuses its buffers, so a
    /// strip kept for stitching must not point into one.
    private static func image(from buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let provider = CGDataProvider(data: Data(bytes: base, count: bytesPerRow * height) as CFData)
        else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A screen buffer counts only when the screen changed and it carries an image.
    private static func carriesPixels(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete || status == .started
    }
}

extension RegionStream: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, Self.carriesPixels(sampleBuffer),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let continuation = lock.withLock { () -> CheckedContinuation<Next, Never>? in
            guard !ended else { return nil }
            if let waiter {
                self.waiter = nil
                return waiter
            }
            latest = buffer
            return nil
        }
        if let continuation {
            continuation.resume(returning: Self.image(from: buffer).map(Next.frame) ?? .idle)
        }
    }
}

extension RegionStream: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish()
    }
}
