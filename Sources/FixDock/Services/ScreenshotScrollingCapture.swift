// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
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
    private static let interval: UInt64 = 120_000_000

    init?(displayID: CGDirectDisplayID, localRect: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return nil }
        self.displayID = displayID
        self.localRect = localRect
        self.screenFrame = screen.frame
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
        guard let source = await ScreenshotCaptureEngine.prepareRegion(displayID: displayID,
                                                                       localPoints: localRect),
              let first = await source.image(),
              let firstSignature = Self.signature(first)
        else {
            await end(.failed)
            return
        }
        var strips: [CGImage] = [first]
        var total = first.height
        var previous = firstSignature
        /// Rows that stay at the bottom of every frame, found on the first move.
        var footer: Int?
        var lastFrame = first
        var frames = 1
        var limited = false
        let started = ProcessInfo.processInfo.systemUptime
        await publish(height: total)

        while !Task.isCancelled {
            let finishing = await MainActor.run { self.finishRequested }
            if ProcessInfo.processInfo.systemUptime - started > ScreenshotSupport.scrollMaximumDuration
                || frames >= ScreenshotSupport.scrollMaximumFrames {
                limited = true
            }
            if !finishing, !limited {
                try? await Task.sleep(nanoseconds: Self.interval)
            }
            guard !Task.isCancelled else { break }
            guard let frame = await source.image(), let signature = Self.signature(frame) else {
                break
            }
            frames += 1
            switch ScreenshotSupport.scrollStep(previous: previous, current: signature,
                                                knownFooter: footer) {
            case .unchanged:
                break
            case .advanced(let rows, let fixedBottom):
                if footer == nil {
                    footer = fixedBottom
                    // The first frame keeps its header but not the footer,
                    // which is added once, from the last frame, at the end.
                    if fixedBottom > 0,
                       let top = first.cropping(to: CGRect(x: 0, y: 0, width: first.width,
                                                           height: first.height - fixedBottom)) {
                        strips[0] = top
                        total -= fixedBottom
                    }
                }
                let bottom = frame.height - fixedBottom
                let newRows = min(rows, bottom)
                if total + newRows + fixedBottom > ScreenshotSupport.scrollMaximumHeight {
                    limited = true
                    break
                }
                if let strip = frame.cropping(to: CGRect(x: 0, y: bottom - newRows,
                                                         width: frame.width, height: newRows)) {
                    strips.append(strip)
                    total += newRows
                    previous = signature
                    lastFrame = frame
                    await publish(height: total + fixedBottom)
                }
            case .unmatched:
                await MainActor.run { self.skippedFrames += 1 }
            }
            if finishing || limited { break }
        }
        if Task.isCancelled {
            await end(.cancelled)
            return
        }
        if let footer, footer > 0,
           let tail = lastFrame.cropping(to: CGRect(x: 0, y: lastFrame.height - footer,
                                                    width: lastFrame.width, height: footer)) {
            strips.append(tail)
            total += footer
        }
        guard let image = Self.stitch(strips, height: total) else {
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

    static func stitch(_ strips: [CGImage], height: Int) -> CGImage? {
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
