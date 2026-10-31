// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import os
import SwiftUI

/// Scrolling capture of one region: frames are taken while the person
/// scrolls, and each frame's new rows are added under the last. Frames that
/// no downward shift explains are skipped. Everything stays in memory; no
/// file is written until the finished image is delivered. Polling pixels,
/// as upstream does, needs no input-monitoring permission and sees
/// scrollbar drags and keyboard scrolling too. Rewritten for FixDock.
final class ScreenshotScrollingSession: ObservableObject {
    enum Result {
        case image(CGImage, limited: Bool)
        case cancelled
        case failed
    }

    @Published private(set) var height = 0
    @Published private(set) var skippedFrames = 0

    private let displayID: CGDirectDisplayID
    private let localRect: CGRect
    private let screenFrame: CGRect
    private var task: Task<Void, Never>?
    private var finishRequested = false
    private var controls: NSPanel?
    private var border: NSPanel?
    var onFinish: ((Result) -> Void)?

    /// Columns kept per row for matching.
    private static let signatureColumns = 96
    /// One line per frame and a summary, numbers only, so a report of
    /// skipped frames can name the reason: `log show --predicate
    /// 'category == "scrollCapture"' --info --last 10m`.
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.qaws81877.fixdock",
                                    category: "scrollCapture")

    init?(displayID: CGDirectDisplayID, localRect: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return nil }
        self.displayID = displayID
        self.localRect = localRect
        self.screenFrame = screen.frame
    }

    /// The region in Cocoa screen points.
    var screenRect: CGRect {
        CGRect(x: screenFrame.minX + localRect.minX, y: screenFrame.maxY - localRect.maxY,
               width: localRect.width, height: localRect.height)
    }

    func start() {
        showWindows()
        task = Task { [weak self] in await self?.run() }
    }

    func finish() { finishRequested = true }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Loop

    private func run() async {
        guard let source = await ScreenshotCaptureEngine.regionStream(displayID: displayID,
                                                                      localPoints: localRect),
              await source.start()
        else {
            await end(.failed)
            return
        }
        // The first frame of a new stream can take a moment to arrive.
        guard case .frame(let first) = await source.next(timeout: 2),
              let firstSignature = Self.signature(first)
        else {
            await source.stop()
            await end(.failed)
            return
        }
        var strips: [CGImage] = [first]
        var total = first.height
        var previous = firstSignature
        /// The signature of the last frame whose rows were added.
        var stitched = firstSignature
        /// Every row added so far, top to bottom, to tell a frame scrolled
        /// back up from one that jumped too far down.
        var stitchedRows = firstSignature
        /// Set while `previous` is a skipped frame rather than `stitched`.
        var detached = false
        /// Rows that stay at the bottom of every frame, found on the first move.
        var footer: Int?
        /// Edge columns that stayed put on every move: a sidebar.
        var sides: ScreenshotSupport.FixedSides?
        var lastFrame = first
        var frames = 1
        var limited = false
        var skips: [ScreenshotSupport.ScrollSkip: Int] = [:]
        let started = ProcessInfo.processInfo.systemUptime
        var lastFrameTime = started
        Self.log.info("start \(first.width, privacy: .public)x\(first.height, privacy: .public)")
        await publish(height: total)

        frameLoop: while !Task.isCancelled {
            let finishing = await MainActor.run { self.finishRequested }
            if ProcessInfo.processInfo.systemUptime - started > ScreenshotSupport.scrollMaximumDuration {
                limited = true
            }
            // Done takes the frame already waiting, if any; otherwise wait a
            // little, so Done and cancel are noticed while nothing moves.
            let waitStarted = ProcessInfo.processInfo.systemUptime
            let next = await source.next(timeout: finishing || limited ? 0.05 : 0.1)
            guard !Task.isCancelled else { break }
            let frame: CGImage
            switch next {
            case .frame(let image):
                frame = image
            case .idle:
                if finishing || limited { break frameLoop }
                continue frameLoop
            case .stopped:
                Self.log.error("frame \(frames + 1, privacy: .public) stream stopped")
                break frameLoop
            }
            guard let signature = Self.signature(frame) else { break }
            let received = ProcessInfo.processInfo.systemUptime
            let timing = String(format: "wait %.0fms gap %.0fms",
                                (received - waitStarted) * 1000, (received - lastFrameTime) * 1000)
            lastFrameTime = received
            frames += 1
            var step = ScreenshotSupport.scrollStep(previous: previous, current: signature,
                                                    knownFooter: footer)
            if detached {
                // After a skip, a frame that still meets the last stitched
                // one carries on from it, so going back to where stitching
                // stopped leaves no hole.
                let joined = ScreenshotSupport.scrollStep(previous: stitched, current: signature,
                                                          knownFooter: footer)
                if case .advanced = joined {
                    step = joined
                    Self.log.info("frame \(frames, privacy: .public) rejoined the last stitched frame")
                }
            }
            switch step {
            case .unchanged:
                Self.log.debug("frame \(frames, privacy: .public) \(timing, privacy: .public) unchanged")
            case .advanced(let rows, let fixedBottom, let stepSides):
                if footer == nil {
                    footer = fixedBottom
                    // The first frame keeps its header but not the footer,
                    // which is added once, from the last frame, at the end.
                    if fixedBottom > 0,
                       let top = first.cropping(to: CGRect(x: 0, y: 0, width: first.width,
                                                           height: first.height - fixedBottom)) {
                        strips[0] = top
                        total -= fixedBottom
                        stitchedRows.removeLast(rows: fixedBottom)
                    }
                }
                let bottom = frame.height - fixedBottom
                let newRows = min(rows, bottom)
                if total + newRows + fixedBottom > ScreenshotSupport.scrollMaximumHeight {
                    limited = true
                    break
                }
                if let strip = frame.cropping(to: CGRect(x: 0, y: bottom - newRows,
                                                         width: frame.width, height: newRows))
                    .flatMap(Self.ownedCopy) {
                    strips.append(strip)
                    stitchedRows.append(rows: (bottom - newRows)..<bottom, of: signature)
                    total += newRows
                    previous = signature
                    stitched = signature
                    detached = false
                    sides = sides?.common(with: stepSides) ?? stepSides
                    lastFrame = frame
                    Self.log.info("frame \(frames, privacy: .public) \(timing, privacy: .public) advanced \(newRows, privacy: .public) footer \(fixedBottom, privacy: .public) total \(total + fixedBottom, privacy: .public)")
                    await publish(height: total + fixedBottom)
                }
            case .unmatched(let skip):
                skips[skip, default: 0] += 1
                // Match the next frame against this one, unless it shows
                // rows already stitched. Against the last stitched frame, a
                // single jump too far to match would leave every later frame
                // too far as well, and stitching would never resume. The
                // skipped rows stay a gap in the image.
                if !ScreenshotSupport.isAlreadyStitched(current: signature, anchor: stitched,
                                                        stitched: stitchedRows, knownFooter: footer,
                                                        sides: sides ?? .none) {
                    previous = signature
                    detached = true
                    Self.log.info("frame \(frames, privacy: .public) \(timing, privacy: .public) skipped \(skip.rawValue, privacy: .public), new anchor")
                } else {
                    Self.log.info("frame \(frames, privacy: .public) \(timing, privacy: .public) skipped \(skip.rawValue, privacy: .public), already stitched")
                }
                await MainActor.run { self.skippedFrames += 1 }
            }
            if finishing || limited { break }
        }
        await source.stop()
        let reasons = ScreenshotSupport.ScrollSkip.allCases.map { "\($0.rawValue) \(skips[$0, default: 0])" }
        let fixed = sides ?? .none
        Self.log.notice("end frames \(frames, privacy: .public) height \(total, privacy: .public) sides \(fixed.left, privacy: .public)/\(fixed.right, privacy: .public) limited \(limited, privacy: .public) seconds \(Int(ProcessInfo.processInfo.systemUptime - started), privacy: .public) skipped \(reasons.joined(separator: ", "), privacy: .public)")
        if Task.isCancelled {
            await end(.cancelled)
            return
        }
        var tailHeight = 0
        if let footer, footer > 0,
           let tail = lastFrame.cropping(to: CGRect(x: 0, y: lastFrame.height - footer,
                                                    width: lastFrame.width, height: footer)) {
            strips.append(tail)
            total += footer
            tailHeight = footer
        }
        let blank = Self.blankSides(fixed.pixels(columns: Self.signatureColumns, width: first.width),
                                    of: strips[0], tailHeight: tailHeight)
        guard let image = Self.stitch(strips, height: total, blank: blank) else {
            await end(.failed)
            return
        }
        await end(.image(image, limited: limited))
    }

    @MainActor
    private func publish(height: Int) {
        self.height = height
    }

    @MainActor
    private func end(_ result: Result) {
        controls?.orderOut(nil)
        border?.orderOut(nil)
        controls = nil
        border = nil
        let handler = onFinish
        onFinish = nil
        handler?(result)
    }

    // MARK: - Pixels

    static func signature(_ image: CGImage) -> ScreenshotSupport.RowSignature? {
        let columns = signatureColumns
        let rows = image.height
        guard rows > 0 else { return nil }
        var values = [UInt8](repeating: 0, count: columns * rows)
        let drawn: Bool = values.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows,
                                          bitsPerComponent: 8, bytesPerRow: columns,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        // A bitmap context's memory starts at the top row, matching the image.
        return drawn ? ScreenshotSupport.RowSignature(columns: columns, values: values) : nil
    }

    /// A crop shares the whole frame's pixels. At stream rates a capture
    /// keeps hundreds of strips, so each gets pixels of its own size.
    static func ownedCopy(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Where a fixed side is painted over below the first frame, and with
    /// which colour: the side's most common colour in the first frame, so a
    /// sidebar keeps its background instead of repeating its contents.
    struct BlankSides {
        var areas: [(x: Int, width: Int, color: CGColor)]
        /// Rows at the top (the first frame) and bottom (the footer) left as they are.
        var keepTop: Int
        var keepBottom: Int
    }

    static func blankSides(_ pixels: (left: Int, right: Int), of first: CGImage, tailHeight: Int) -> BlankSides {
        var areas: [(x: Int, width: Int, color: CGColor)] = []
        for (x, width) in [(0, pixels.left), (first.width - pixels.right, pixels.right)] where width > 0 {
            if let band = first.cropping(to: CGRect(x: x, y: 0, width: width, height: first.height)),
               let color = commonColor(of: band) {
                areas.append((x, width, color))
            }
        }
        return BlankSides(areas: areas, keepTop: first.height, keepBottom: tailHeight)
    }

    /// The most frequent colour of an image, read from a small copy.
    static func commonColor(of image: CGImage) -> CGColor? {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var counts: [UInt32: Int] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let key = UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2])
            counts[key, default: 0] += 1
        }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return CGColor(srgbRed: CGFloat(key >> 16 & 0xFF) / 255, green: CGFloat(key >> 8 & 0xFF) / 255,
                       blue: CGFloat(key & 0xFF) / 255, alpha: 1)
    }

    static func stitch(_ strips: [CGImage], height: Int, blank: BlankSides? = nil) -> CGImage? {
        guard let width = strips.first?.width, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var top = height
        for strip in strips {
            top -= strip.height
            context.draw(strip, in: CGRect(x: 0, y: top, width: strip.width, height: strip.height))
        }
        if let blank {
            // Bitmap y runs up from the bottom: the footer is at 0, the first frame at the top.
            let rows = height - blank.keepTop - blank.keepBottom
            for area in blank.areas where rows > 0 {
                context.setFillColor(area.color)
                context.fill(CGRect(x: area.x, y: blank.keepBottom, width: area.width, height: rows))
            }
        }
        return context.makeImage()
    }

    // MARK: - Windows

    /// A frame just outside the region and a small bar under it. Neither
    /// takes clicks except the bar's buttons, and neither becomes key, so
    /// scrolling and keys reach the app underneath.
    private func showWindows() {
        let region = CGRect(x: screenFrame.minX + localRect.minX,
                            y: screenFrame.maxY - localRect.maxY,
                            width: localRect.width, height: localRect.height)
        let frame = OverlayPanel(contentRect: region.insetBy(dx: -3, dy: -3),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        frame.isOpaque = false
        frame.backgroundColor = .clear
        frame.hasShadow = false
        frame.ignoresMouseEvents = true
        frame.level = .statusBar
        frame.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        frame.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 2))
        frame.orderFrontRegardless()
        border = frame

        let bar = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        bar.isOpaque = false
        bar.backgroundColor = .clear
        bar.hasShadow = true
        bar.level = .statusBar
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let hosting = NSHostingView(rootView: ScrollingCaptureBar(session: self))
        bar.contentView = hosting
        let size = hosting.fittingSize
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 10)
        if origin.y < screenFrame.minY + 8 { origin.y = region.maxY + 10 }
        if origin.y + size.height > screenFrame.maxY - 8 { origin.y = region.minY + 10 }
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        bar.setFrame(CGRect(origin: origin, size: size), display: true)
        bar.orderFrontRegardless()
        controls = bar
    }
}

private struct ScrollingCaptureBar: View {
    @ObservedObject var session: ScreenshotScrollingSession
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let s = l10n.s
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.screenshotScrollingPrompt).font(.system(size: 12, weight: .medium))
                Text(String(format: s.screenshotScrollingHeight, session.height))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if session.skippedFrames > 0 {
                    Text(String(format: s.screenshotScrollingSkipped, session.skippedFrames))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            Button(s.screenshotScrollingDone) { session.finish() }
            Button(s.screenshotKeyCancel) { session.cancel() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .fixedSize()
    }
}
