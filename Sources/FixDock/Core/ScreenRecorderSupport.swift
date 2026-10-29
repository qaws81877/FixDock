// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics
import Foundation

/// Pure decisions for the screen recorder that are not part of the shared
/// recorder contract in `RecorderSupport`: the region the overlay hands over,
/// where the finished movie is saved, which takes a sweep keeps, and what
/// the capture shortcuts do while a recording is under way. No AppKit, so a
/// harness compiles it on its own. New in FixDock; the region math follows
/// upstream's selection controller.
enum ScreenRecorderSupport {

    // MARK: - Options

    /// Countdown before a recording starts, in seconds; 0 is off.
    static let countdownChoices = [0, 3, 5, 10]
    static let defaultCountdown = 3

    static func sanitizedCountdown(_ raw: Int) -> Int {
        countdownChoices.contains(raw) ? raw : defaultCountdown
    }

    /// How long the recorder waits after the overlay closes before the
    /// stream starts, so the overlay is not in the first frame. Upstream's
    /// value.
    static let overlayClearDelayNanoseconds: UInt64 = 120_000_000

    // MARK: - Region

    /// The area picked in the overlay as the recorder needs it: whole, even
    /// pixels of the display image, plus the same area in Cocoa points so the
    /// region guide can be drawn over it. The point rectangle is derived from
    /// the snapped pixels, so what is recorded and what is shown agree.
    ///
    /// `localRect` is in the display's own points with a top-left origin,
    /// `imageSize` the display's size in pixels, `screenFrame` the display in
    /// Cocoa global points (its origin may be negative on a secondary display).
    static func region(localRect: CGRect,
                       pixelScale: CGFloat,
                       imageSize: CGSize,
                       screenFrame: CGRect,
                       displayID: CGDirectDisplayID,
                       windowID: CGWindowID?) -> RecorderSupport.Region {
        let scale = pixelScale > 0 && pixelScale.isFinite ? pixelScale : 1
        let bounds = CGRect(origin: .zero, size: imageSize)
        let raw = ScreenshotSupport.pixelRect(localRect, scale: scale, imageSize: imageSize)
        let snapped = RecorderSupport.snappedPixelRect(raw, in: bounds)
        let local = CGRect(x: snapped.minX / scale, y: snapped.minY / scale,
                           width: snapped.width / scale, height: snapped.height / scale)
        let anchor = CGRect(x: screenFrame.minX + local.minX,
                            y: screenFrame.maxY - local.maxY,
                            width: local.width, height: local.height)
        return RecorderSupport.Region(displayID: displayID, windowID: windowID,
                                      pixelRect: snapped, anchorRect: anchor, scale: scale)
    }

    // MARK: - Saved file

    static let movieExtension = "mov"

    /// `Prefix yyyy-MM-dd at HH.mm.ss.mov` in `folder`, or ` (2)`, ` (3)`…
    /// when that name is taken. `nil` when every name is taken, so the
    /// caller refuses rather than overwriting. The editor passes its own
    /// extension (`mp4`, `gif`) for the files it exports.
    static func recordingDestination(in folder: URL, prefix: String, date: Date,
                                     fileExtension: String = movieExtension,
                                     exists: (String) -> Bool) -> URL? {
        let name = ScreenshotSupport.fileName(prefix: prefix, date: date, fileExtension: fileExtension)
        guard let unique = ScreenshotSupport.uniqueFileName(name, exists: exists) else { return nil }
        return folder.appendingPathComponent(unique)
    }

    // MARK: - Sweep

    /// The takes a sweep must leave alone: the one being recorded, the one
    /// the preview holds and every one an editor owns. Everything else is
    /// judged by age alone in `RecorderSupport.orphanTakeIDs`.
    static func takesToKeep(session: UUID?, preview: UUID?, editors: Set<UUID>) -> Set<UUID> {
        var kept = editors
        if let session { kept.insert(session) }
        if let preview { kept.insert(preview) }
        return kept
    }

    // MARK: - Shortcuts while recording

    /// Where the recorder is, as the capture shortcuts see it.
    enum CaptureState: Equatable {
        case idle
        /// A recording was asked for and has not started: the microphone
        /// question, the writer being prepared, or the countdown.
        case countdown
        /// The stream is starting or running, paused or not.
        case recording
        /// Stop was pressed and the file is being closed.
        case finishing
    }

    enum ShortcutResponse: Equatable {
        case openOverlay
        case cancelCountdown
        case stopRecording
        case beep
    }

    /// Control-Option-Command-4: the overlay at rest, otherwise the control
    /// that ends what is under way. A file being closed cannot be stopped
    /// twice, so that only beeps.
    static func overlayShortcut(in state: CaptureState) -> ShortcutResponse {
        switch state {
        case .idle: return .openOverlay
        case .countdown: return .cancelCountdown
        case .recording: return .stopRecording
        case .finishing: return .beep
        }
    }

    /// Control-Option-Command-3 and the panel's capture buttons: screenshots
    /// are blocked (a beep) from the countdown until the file is closed.
    static func allowsScreenshot(in state: CaptureState) -> Bool {
        state == .idle
    }
}
